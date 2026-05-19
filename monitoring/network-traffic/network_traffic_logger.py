#!/usr/bin/env python3
"""Write one JSONL network traffic sample per run.

This is intended for lightweight host-level monitoring on Raspberry Pis so the
resulting JSON log can be tailed by Filebeat/Logstash and graphed in ELK.

Each run reads kernel counters from /proc/net/dev, persists the previous sample
to a state file, and emits a single JSON record containing cumulative counters
plus per-window deltas and average bytes/sec.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_LOG_DIR = Path("/var/log/host-network-traffic")
DEFAULT_STATE_DIR = Path("/var/lib/host-network-traffic")


@dataclass
class InterfaceCounters:
    rx_bytes: int
    rx_packets: int
    rx_errs: int
    rx_drop: int
    tx_bytes: int
    tx_packets: int
    tx_errs: int
    tx_drop: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Log one network traffic sample as a JSON line.",
    )
    parser.add_argument(
        "--interface",
        help="Network interface to monitor. Defaults to the default route interface.",
    )
    parser.add_argument(
        "--role",
        default="",
        help="Optional host role tag, e.g. media-server or backup-node.",
    )
    parser.add_argument(
        "--site",
        default="home",
        help="Optional site/location tag for dashboards.",
    )
    parser.add_argument(
        "--log-dir",
        default=str(DEFAULT_LOG_DIR),
        help=f"Directory for the JSONL log file. Default: {DEFAULT_LOG_DIR}",
    )
    parser.add_argument(
        "--state-dir",
        default=str(DEFAULT_STATE_DIR),
        help=f"Directory for state files. Default: {DEFAULT_STATE_DIR}",
    )
    parser.add_argument(
        "--log-file",
        default="",
        help="Optional explicit JSONL log path. Overrides --log-dir.",
    )
    return parser.parse_args()


def detect_default_interface() -> str:
    route_path = Path("/proc/net/route")
    if route_path.exists():
        with route_path.open("r", encoding="utf-8") as handle:
            next(handle, None)
            for line in handle:
                fields = line.split()
                if len(fields) >= 2 and fields[1] == "00000000":
                    return fields[0]

    counters = read_all_interface_counters()
    for iface in counters:
        if iface != "lo":
            return iface

    raise RuntimeError("Unable to determine a usable network interface")


def read_all_interface_counters() -> dict[str, InterfaceCounters]:
    counters: dict[str, InterfaceCounters] = {}
    with Path("/proc/net/dev").open("r", encoding="utf-8") as handle:
        lines = handle.readlines()[2:]

    for line in lines:
        iface_part, data_part = line.split(":", 1)
        iface = iface_part.strip()
        fields = data_part.split()
        counters[iface] = InterfaceCounters(
            rx_bytes=int(fields[0]),
            rx_packets=int(fields[1]),
            rx_errs=int(fields[2]),
            rx_drop=int(fields[3]),
            tx_bytes=int(fields[8]),
            tx_packets=int(fields[9]),
            tx_errs=int(fields[10]),
            tx_drop=int(fields[11]),
        )
    return counters


def read_interface_counters(interface: str) -> InterfaceCounters:
    counters = read_all_interface_counters()
    if interface not in counters:
        known = ", ".join(sorted(counters))
        raise RuntimeError(f"Interface '{interface}' not found. Known interfaces: {known}")
    return counters[interface]


def read_operstate(interface: str) -> str:
    path = Path(f"/sys/class/net/{interface}/operstate")
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return "unknown"


def read_speed_mbps(interface: str) -> int | None:
    path = Path(f"/sys/class/net/{interface}/speed")
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None

    if not value or value == "-1":
        return None

    try:
        return int(value)
    except ValueError:
        return None


def utc_timestamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def load_state(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None

    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None


def save_state(path: Path, payload: dict[str, Any]) -> None:
    ensure_parent(path)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    with tmp_path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, separators=(",", ":"))
    os.replace(tmp_path, path)


def append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    ensure_parent(path)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, separators=(",", ":"), sort_keys=True))
        handle.write("\n")


def build_record(
    *,
    hostname: str,
    interface: str,
    counters: InterfaceCounters,
    previous_state: dict[str, Any] | None,
    role: str,
    site: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    now_epoch = time.time()
    current_state = {
        "epoch": now_epoch,
        "rx_bytes": counters.rx_bytes,
        "tx_bytes": counters.tx_bytes,
        "rx_packets": counters.rx_packets,
        "tx_packets": counters.tx_packets,
        "rx_errs": counters.rx_errs,
        "tx_errs": counters.tx_errs,
        "rx_drop": counters.rx_drop,
        "tx_drop": counters.tx_drop,
    }

    window_seconds: float | None = None
    rx_bytes_delta: int | None = None
    tx_bytes_delta: int | None = None
    rx_packets_delta: int | None = None
    tx_packets_delta: int | None = None

    if previous_state is not None:
        prev_epoch = float(previous_state.get("epoch", 0))
        window_seconds = now_epoch - prev_epoch
        if window_seconds > 0:
            rx_bytes_delta = max(0, counters.rx_bytes - int(previous_state.get("rx_bytes", 0)))
            tx_bytes_delta = max(0, counters.tx_bytes - int(previous_state.get("tx_bytes", 0)))
            rx_packets_delta = max(0, counters.rx_packets - int(previous_state.get("rx_packets", 0)))
            tx_packets_delta = max(0, counters.tx_packets - int(previous_state.get("tx_packets", 0)))
        else:
            window_seconds = None

    record = {
        "timestamp": utc_timestamp(),
        "host_name": hostname,
        "site": site,
        "role": role,
        "interface": interface,
        "window_seconds": window_seconds,
        "rx_bytes_delta": rx_bytes_delta,
        "tx_bytes_delta": tx_bytes_delta,
    }
    return record, current_state


def main() -> int:
    args = parse_args()
    hostname = socket.gethostname()
    interface = args.interface or detect_default_interface()
    counters = read_interface_counters(interface)

    log_file = Path(args.log_file) if args.log_file else Path(args.log_dir) / f"network_traffic_{hostname}.jsonl"
    state_file = Path(args.state_dir) / f"{hostname}_{interface}.json"

    previous_state = load_state(state_file)
    record, current_state = build_record(
        hostname=hostname,
        interface=interface,
        counters=counters,
        previous_state=previous_state,
        role=args.role,
        site=args.site,
    )

    append_jsonl(log_file, record)
    save_state(state_file, current_state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())