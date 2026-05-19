#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_TARGET="/etc/default/host-network-traffic-logger"
TIMER_OVERRIDE_DIR="/etc/systemd/system/host-network-traffic-logger.timer.d"
TIMER_OVERRIDE_TARGET="$TIMER_OVERRIDE_DIR/override.conf"

usage() {
  cat <<'EOF'
Install and configure the host network traffic logger.

Usage:
  sudo ./install-host-network-traffic-logger.sh [options]

Options:
  --config-file PATH        Read host defaults from an env-style file.
  --interface NAME          Interface to monitor. Default: auto-detect default route interface.
  --role NAME               Optional host role tag. Default: empty.
  --site NAME               Site tag for dashboards. Default: home.
  --log-dir PATH            Log directory. Default: /var/log/host-network-traffic.
  --state-dir PATH          State directory. Default: /var/lib/host-network-traffic.
  --interval-seconds N      Sample interval for the systemd timer. Default: 60.
  --no-start                Install and enable, but do not start service/timer now.
  -h, --help                Show this help.

Examples:
  sudo ./install-host-network-traffic-logger.sh --interface wlan0 --site home
  sudo ./install-host-network-traffic-logger.sh --config-file config/hosts/pi5-host-network-traffic-logger.env
  sudo ./install-host-network-traffic-logger.sh --interface eth0 --role backup-node --site home --interval-seconds 10
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root or via sudo." >&2
    exit 1
  fi
}

detect_default_interface() {
  local iface
  iface="$(awk '$2 == "00000000" { print $1; exit }' /proc/net/route)"
  if [[ -n "$iface" ]]; then
    printf '%s\n' "$iface"
    return 0
  fi

  iface="$(awk -F: 'NR > 2 {gsub(/^[ \t]+|[ \t]+$/, "", $1); if ($1 != "lo") { print $1; exit }}' /proc/net/dev)"
  if [[ -n "$iface" ]]; then
    printf '%s\n' "$iface"
    return 0
  fi

  echo "Unable to determine a default network interface." >&2
  exit 1
}

write_env_file() {
  local interface="$1"
  local role="$2"
  local site="$3"
  local log_dir="$4"
  local state_dir="$5"

  install -d -m 0755 "$(dirname "$ENV_TARGET")"
  cat >"$ENV_TARGET" <<EOF
NETWORK_TRAFFIC_INTERFACE=$interface
NETWORK_TRAFFIC_ROLE=$role
NETWORK_TRAFFIC_SITE=$site
NETWORK_TRAFFIC_LOG_DIR=$log_dir
NETWORK_TRAFFIC_STATE_DIR=$state_dir
EOF
}

write_timer_override() {
  local interval_seconds="$1"

  install -d -m 0755 "$TIMER_OVERRIDE_DIR"
  cat >"$TIMER_OVERRIDE_TARGET" <<EOF
[Timer]
OnBootSec=30s
OnUnitActiveSec=${interval_seconds}s
AccuracySec=1s
EOF
}

load_config_file() {
  local config_file="$1"

  if [[ ! -f "$config_file" ]]; then
    echo "Config file not found: $config_file" >&2
    exit 2
  fi

  # shellcheck disable=SC1090
  source "$config_file"

  INTERFACE="${NETWORK_TRAFFIC_INTERFACE:-$INTERFACE}"
  ROLE="${NETWORK_TRAFFIC_ROLE:-$ROLE}"
  SITE="${NETWORK_TRAFFIC_SITE:-$SITE}"
  LOG_DIR="${NETWORK_TRAFFIC_LOG_DIR:-$LOG_DIR}"
  STATE_DIR="${NETWORK_TRAFFIC_STATE_DIR:-$STATE_DIR}"
  INTERVAL_SECONDS="${NETWORK_TRAFFIC_INTERVAL_SECONDS:-$INTERVAL_SECONDS}"
}

CONFIG_FILE=""
INTERFACE=""
ROLE=""
SITE="home"
LOG_DIR="/var/log/host-network-traffic"
STATE_DIR="/var/lib/host-network-traffic"
INTERVAL_SECONDS=60
START_NOW=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-file)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --interface)
      INTERFACE="$2"
      shift 2
      ;;
    --role)
      ROLE="$2"
      shift 2
      ;;
    --site)
      SITE="$2"
      shift 2
      ;;
    --log-dir)
      LOG_DIR="$2"
      shift 2
      ;;
    --state-dir)
      STATE_DIR="$2"
      shift 2
      ;;
    --interval-seconds)
      INTERVAL_SECONDS="$2"
      shift 2
      ;;
    --no-start)
      START_NOW=false
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

require_root

if [[ -n "$CONFIG_FILE" ]]; then
  load_config_file "$CONFIG_FILE"
fi

if [[ -z "$INTERFACE" ]]; then
  INTERFACE="$(detect_default_interface)"
fi

if ! [[ "$INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [[ "$INTERVAL_SECONDS" -lt 1 ]]; then
  echo "--interval-seconds must be a positive integer." >&2
  exit 2
fi

install -D -m 0755 \
  "$SCRIPT_DIR/monitoring/network-traffic/network_traffic_logger.py" \
  /usr/local/sbin/host-network-traffic-logger.py

install -D -m 0644 \
  "$SCRIPT_DIR/systemd/host-network-traffic-logger.service" \
  /etc/systemd/system/host-network-traffic-logger.service

install -D -m 0644 \
  "$SCRIPT_DIR/systemd/host-network-traffic-logger.timer" \
  /etc/systemd/system/host-network-traffic-logger.timer

install -D -m 0644 \
  "$SCRIPT_DIR/logrotate/host-network-traffic-logger" \
  /etc/logrotate.d/host-network-traffic-logger

write_env_file "$INTERFACE" "$ROLE" "$SITE" "$LOG_DIR" "$STATE_DIR"
write_timer_override "$INTERVAL_SECONDS"

install -d -m 0755 "$LOG_DIR"
install -d -m 0755 "$STATE_DIR"

systemctl daemon-reload
systemctl enable host-network-traffic-logger.timer

if [[ "$START_NOW" == true ]]; then
  systemctl restart host-network-traffic-logger.service
  systemctl restart host-network-traffic-logger.timer
fi

echo "Installed host network traffic logger units."
echo "Config written to: $ENV_TARGET"
echo "Timer override written to: $TIMER_OVERRIDE_TARGET"
echo "Logrotate config written to: /etc/logrotate.d/host-network-traffic-logger"
echo "interface=$INTERFACE role=${ROLE:-<empty>} site=$SITE interval_seconds=$INTERVAL_SECONDS"
if [[ "$START_NOW" == true ]]; then
  echo "Service and timer restarted."
else
  echo "Service and timer were enabled but not started."
fi