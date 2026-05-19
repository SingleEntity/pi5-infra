# pi5-infra

Tracked host-level infrastructure for the Pi5, with room for shared homelab host tooling.

This repository exists to prevent production security and operational scripts from becoming untracked server state. It started with Pi5-specific live-host protection, but it is also a sensible place for shared host-level utilities used across `pi5`, `pi4`, and `pi3` when those utilities are not tied to a single application repository.

## Contents

- `cloudflare-docker-allowlist/cloudflare-docker-allowlist.sh`
- `monitoring/network-traffic/network_traffic_logger.py`
- `monitoring/network-traffic/kibana-dashboard-notes.md`
- `systemd/cloudflare-docker-allowlist.service`
- `systemd/cloudflare-docker-allowlist.timer`
- `systemd/host-network-traffic-logger.service`
- `systemd/host-network-traffic-logger.timer`
- `config/host-network-traffic-logger.env.example`
- `config/hosts/pi5-host-network-traffic-logger.env`
- `config/hosts/pi4-host-network-traffic-logger.env`
- `config/hosts/pi3-host-network-traffic-logger.env`
- `logrotate/host-network-traffic-logger`
- `elk/filebeat/host-network-traffic-input.yml`
- `elk/logstash/host-network-traffic.conf`
- `install-cloudflare-docker-allowlist.sh`
- `install-host-network-traffic-logger.sh`

## What it does

The Cloudflare allowlist workflow manages the Linux firewall rule chain that Docker uses for forwarded traffic.

In practical terms, this setup is trying to answer one question:

"When traffic is heading to a container on ports `80` or `443`, should it be allowed through or dropped?"

The answer is controlled by the `DOCKER-USER` chain.

The script does the following:

- creates and refreshes the `cloudflare4` and `cloudflare6` `ipset` sets from Cloudflare's published IP ranges
- inserts `DOCKER-USER` firewall rules for traffic involving Docker-published ports `80` and `443`
- allows traffic from Cloudflare IPs to reach those published ports
- allows traffic from the local LAN (`10.0.0.0/24` by default, overridable with `LAN_CIDR`)
- allows traffic that is already part of an existing connection (`RELATED,ESTABLISHED`)
- allows traffic coming from Docker bridge interfaces such as `docker0` and `br-*`
- drops the remaining traffic to Docker-published `80/443`

This is intended to protect reverse proxies and web apps that are expected to sit behind Cloudflare.

## What it does not do

This script is not a general firewall for the whole host.

It does not:

- block or manage all ports on the machine
- control non-Docker services directly
- restrict all container networking

It is narrowly focused on forwarded Docker traffic for ports `80` and `443`.

## Why containers can still reach the internet

This is the part that is easy to forget later.

The rules intentionally allow traffic arriving from Docker bridge interfaces like `docker0` and `br-*` before the final drop rule.

That means a container can still make outbound HTTP/HTTPS connections, including things like:

- `apt-get update`
- package downloads
- calling external APIs over `80` or `443`

Without those Docker bridge exceptions, container traffic to remote web servers can be caught by the final drop rule, because that traffic also passes through `DOCKER-USER`.

So if `apt-get update` inside a container was previously broken and later started working, these Docker bridge `RETURN` rules are the most likely reason.

## Rule logic in plain English

For Docker-related traffic on ports `80` and `443`, the rules are effectively:

1. If the traffic belongs to an existing connection, allow it.
2. If it came from the local LAN, allow it.
3. If it came from a Docker bridge interface, allow it.
4. If it came from a Cloudflare IP, allow it.
5. Otherwise, drop it.

The exact order in `iptables -S DOCKER-USER` may look reversed, because the script inserts rules at the top of the chain one at a time. The end result on the Pi5 is still the intended allowlist behavior.

## Install or refresh on the Pi5

Run as root or via `sudo`:

```bash
./install-cloudflare-docker-allowlist.sh
sudo systemctl start cloudflare-docker-allowlist.service
sudo systemctl start cloudflare-docker-allowlist.timer
```

What each command does:

- `./install-cloudflare-docker-allowlist.sh` copies the script into `/usr/local/sbin/` and installs the systemd service and timer into `/etc/systemd/system/`
- `sudo systemctl start cloudflare-docker-allowlist.service` runs the allowlist script immediately once
- `sudo systemctl start cloudflare-docker-allowlist.timer` starts the daily refresh schedule immediately

The install script enables both the service and the timer so they start on future boots, but it does not start the timer right away. Starting the timer manually makes the current machine state obvious and avoids confusion later.

## Verification

```bash
sudo systemctl status cloudflare-docker-allowlist.service
sudo systemctl status cloudflare-docker-allowlist.timer
sudo systemctl list-timers --all | grep cloudflare
sudo ipset list cloudflare4
sudo ipset list cloudflare6
sudo iptables -S DOCKER-USER
sudo ip6tables -S DOCKER-USER
```

What to look for:

- the service should show a successful last run
- the timer should show `active (waiting)`
- the timer list should show the next scheduled run time
- the `cloudflare4` and `cloudflare6` sets should contain Cloudflare CIDR ranges
- the `DOCKER-USER` chain should include `RETURN` rules for Cloudflare, Docker bridges, and established traffic, followed by a final `DROP` for `80,443`

## Notes

- This repo is infrastructure-level, not app-level.
- App repositories such as PhotoSite should document their dependency on this protection, but should not treat live files under `/usr/local` or `/etc/systemd/system` as the source of truth.

## Shared host monitoring

This repo now also includes a lightweight network traffic logger intended for any Raspberry Pi host in the homelab.

It writes one JSON line per run from kernel interface counters so Filebeat or Logstash can ship the data into ELK. That makes it easy to graph per-host network usage over time and answer a practical question during slowdowns:

"Was `pi5`, `pi4`, or `pi3` actually moving unusual traffic at that moment?"

The logger is generic and host-configurable through an environment file. The same service can be installed on all three Pis with different values for:

- `NETWORK_TRAFFIC_INTERFACE`
- `NETWORK_TRAFFIC_ROLE`
- `NETWORK_TRAFFIC_SITE`

That keeps the code shared while making the host identity explicit in Kibana.

## Install the host network traffic logger

The host network logger now has a deterministic installer. One command installs the script, writes the host config, writes a timer override for the sample cadence, reloads systemd, enables the timer, and starts the service and timer unless you opt out.

Run as root or via `sudo`:

```bash
sudo ./install-host-network-traffic-logger.sh --interface wlan0 --site home
```

Useful options:

- `--config-file PATH`: load host defaults from a repo-managed env file.
- `--interface NAME`: interface to monitor. If omitted, the installer auto-detects the default route interface.
- `--role NAME`: optional host role tag.
- `--site NAME`: site tag for ELK dashboards. Default: `home`.
- `--interval-seconds N`: sample cadence. Default: `60`.
- `--no-start`: install and enable, but do not start immediately.

The installer writes:

- `/usr/local/sbin/host-network-traffic-logger.py`
- `/etc/default/host-network-traffic-logger`
- `/etc/systemd/system/host-network-traffic-logger.service`
- `/etc/systemd/system/host-network-traffic-logger.timer`
- `/etc/systemd/system/host-network-traffic-logger.timer.d/override.conf`

For `pi5`, the repo-managed host config now points the JSONL output at the mounted project log disk:

- `/mnt/website_and_cold_storage/website/logs/host-network-traffic/`

That sits alongside the other project log directories already living under `/mnt/website_and_cold_storage/website/logs/`.

### Example commands per host

Pi5:

```bash
sudo ./install-host-network-traffic-logger.sh --config-file config/hosts/pi5-host-network-traffic-logger.env
```

That config writes logs to:

- `/mnt/website_and_cold_storage/website/logs/host-network-traffic/`

Pi4:

```bash
sudo ./install-host-network-traffic-logger.sh --config-file config/hosts/pi4-host-network-traffic-logger.env
```

Pi3:

```bash
sudo ./install-host-network-traffic-logger.sh --config-file config/hosts/pi3-host-network-traffic-logger.env
```

If you want higher-frequency sampling temporarily during investigation:

```bash
sudo ./install-host-network-traffic-logger.sh --interface wlan0 --site home --interval-seconds 10
```

Use the 10-second cadence for short diagnostic windows, not as the default forever setting, unless you also rotate logs deliberately.

### Log rotation

The installer also installs a logrotate policy at `/etc/logrotate.d/host-network-traffic-logger`.

That policy:

- rotates daily
- keeps 30 rotated files
- compresses old logs
- uses `copytruncate` so the active JSONL file can keep being written without service interruption

### Verify

```bash
sudo systemctl status host-network-traffic-logger.service
sudo systemctl status host-network-traffic-logger.timer
sudo systemctl list-timers --all | grep host-network-traffic
sudo cat /etc/default/host-network-traffic-logger
sudo cat /etc/systemd/system/host-network-traffic-logger.timer.d/override.conf
sudo cat /etc/logrotate.d/host-network-traffic-logger
sudo tail -n 5 /var/log/host-network-traffic/network_traffic_$(hostname).jsonl
```

## ELK ingest

Example ingest snippets live here:

- `elk/filebeat/host-network-traffic-input.yml`
- `elk/logstash/host-network-traffic.conf`

Recommended approach:

1. Use Filebeat `filestream` with NDJSON parsing against `/var/log/host-network-traffic/*.jsonl`.
2. Preserve fields like `host_name`, `role`, `site`, `tx_bytes_delta`, `rx_bytes_delta`, and `window_seconds` at the top level.
3. In Logstash, coerce `rx_bytes_delta`, `tx_bytes_delta`, and `window_seconds` to numeric types if your pipeline would otherwise treat them as strings.

Dashboard guidance lives in `monitoring/network-traffic/kibana-dashboard-notes.md`.

The logger now emits a deliberately slim event shape:

- `timestamp`
- `host_name`
- `site`
- `role`
- `interface`
- `window_seconds`
- `rx_bytes_delta`
- `tx_bytes_delta`

If you want bytes-per-second in Kibana, derive it from `*_bytes_delta / window_seconds` rather than storing the precomputed rate in every event.

## Structure and naming

The current repo name is slightly narrower than the scope you now want, but I would not rush into renaming it yet.

Practical recommendation:

1. Keep the repo name as `pi5-infra` for now so existing references and machine context stay stable.
2. Broaden the internal structure so shared assets live under clearly generic paths such as `monitoring/`, `systemd/`, and `config/`.
3. Treat Pi5-specific items as one category inside the repo rather than the repo's only purpose.

If the repo later becomes the canonical source for multiple hosts and starts carrying substantial `pi3` and `pi4` automation, then a rename to something like `homelab-infra` or `pi-infra` becomes justified. Right now the lower-risk move is to broaden the structure first and rename only after the contents prove the broader remit.