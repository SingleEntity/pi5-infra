# pi5-infra

Tracked host-level infrastructure for the Pi5, with room for shared homelab host tooling.

This repository exists so production security and operational scripts do not become untracked server state.

It currently contains two main jobs:

1. A Cloudflare Docker allowlist that protects published `80/443` traffic.
2. A host network traffic logger that writes JSONL samples for later analysis in ELK.

## Quick mental model for the network traffic logger and cloudflare allowlist

If you come back to this repo after months away, this is the main pattern to remember:

- the real work is done by a script or Python program for both
- both work via systemd processes setup by deployment scripts in this repo
- a `.service` file tells `systemd` how to run that job
- a `.timer` file tells `systemd` when to run that job
- an installer script copies the required files into the correct paths on the live host and enables the relevant service or timer

Think of it like this:

- `.service` = what to run
- `.timer` = when to run it
- installer = how it gets onto the host

This is standard Linux `systemd` behavior, not a custom convention invented in this repo.

## Repo map

### Cloudflare allowlist

Job parts:

- `cloudflare-docker-allowlist/cloudflare-docker-allowlist.sh`: the actual firewall script
- `systemd/cloudflare-docker-allowlist.service`: how to run that script as a systemd job
- `systemd/cloudflare-docker-allowlist.timer`: when to run it again automatically

Installer:

- `install-cloudflare-docker-allowlist.sh`: copies those files into the live system and enables them

### Traffic logger

Job parts:

- `monitoring/network-traffic/network_traffic_logger.py`: the actual logger program
- `systemd/host-network-traffic-logger.service`: how to run one logger sample
- `systemd/host-network-traffic-logger.timer`: when to run that sample again
- `config/host-network-traffic-logger.env.example`: example host config
- `config/hosts/pi5-host-network-traffic-logger.env`: Pi5 host config
- `config/hosts/pi4-host-network-traffic-logger.env`: Pi4 host config
- `config/hosts/pi3-host-network-traffic-logger.env`: Pi3 host config
- `logrotate/host-network-traffic-logger`: log rotation policy

Installer:

- `install-host-network-traffic-logger.sh`: installs the logger, config, timer, and logrotate policy

### ELK ingest examples

- `elk/filebeat/host-network-traffic-input.yml`
- `elk/logstash/host-network-traffic.conf`
- `monitoring/network-traffic/kibana-dashboard-notes.md`

## How `systemd` service and timer pairs work

This repo uses a common `systemd` pattern which launches the processes on the timer after boot.

A `.service` file describes a job It usually contains:

- a description
- the command to run
- optional environment variables or config file references

A `.timer` file is the schedule for that service. It usually contains:

- when to run after boot
- how often to repeat
- which `.service` it triggers

For example, the traffic logger pair is:

- `host-network-traffic-logger.service`
- `host-network-traffic-logger.timer`

Those matching names are intentional. It makes the pair easy to reason about.

### What "active" and "inactive" usually mean here

This matters because it is easy to misread `systemctl status`.

For these jobs:

- the timer is the thing that normally stays running and waiting
- the service often runs once and exits

So this is usually the healthy state:

- timer: `active (waiting)`
- service: `inactive (dead)` after a successful run

That is normal for `Type=oneshot` services.

## Cloudflare Docker allowlist

### What problem it solves

This workflow controls Docker-forwarded traffic for ports `80` and `443`.

In plain English, it is answering this question:

"If traffic is heading to a Docker-published web port, should it be allowed or dropped?"

The answer is implemented in the `DOCKER-USER` firewall chain.

### What the script actually does

The script:

- creates and refreshes the `cloudflare4` and `cloudflare6` `ipset` sets from Cloudflare's published IP ranges
- inserts `DOCKER-USER` rules for Docker-published `80/443` traffic
- allows Cloudflare source IPs to reach those published ports
- allows local LAN traffic from `10.0.0.0/24` by default, unless `LAN_CIDR` is changed
- allows already-established traffic
- allows traffic coming from Docker bridge interfaces such as `docker0` and `br-*`
- drops the remaining traffic to Docker-published `80/443`

This is meant to protect reverse proxies and web apps that are expected to sit behind Cloudflare.

### What it does not do

This script is not a full-machine firewall policy.

It does not:

- manage every port on the host
- directly control non-Docker services
- block all container networking

It only targets forwarded Docker traffic for `80` and `443`.

### Why containers can still do `apt-get update`

This is the easy-to-forget part.

The rules intentionally allow traffic arriving from Docker bridge interfaces before the final drop rule.

That means containers can still make outbound HTTP and HTTPS requests, including:

- `apt-get update`
- package downloads
- API calls over `80/443`

Without those Docker bridge `RETURN` rules, container traffic to remote web servers can be caught by the final drop rule because it also passes through `DOCKER-USER`.

So if container `apt-get update` was once broken and later started working, these Docker bridge exceptions are the likely reason.

### Rule logic in plain English

For Docker-related traffic on `80` and `443`, the effective logic is:

1. If it is part of an existing connection, allow it.
2. If it came from the local LAN, allow it.
3. If it came from a Docker bridge interface, allow it.
4. If it came from a Cloudflare IP, allow it.
5. Otherwise, drop it.

If `iptables -S DOCKER-USER` looks visually reversed, that is because the script inserts rules at the top of the chain one by one.

### Boot behavior

The allowlist installer enables both:

- `cloudflare-docker-allowlist.service`
- `cloudflare-docker-allowlist.timer`

That means on boot:

- the service can run as part of normal startup because it is enabled under `multi-user.target`
- the timer also starts and triggers the service on its schedule

In other words, this setup is slightly more aggressive than the traffic logger setup. It is designed so the allowlist comes back after reboot and also keeps refreshing later.

### Install or refresh on the Pi5

Run as root or via `sudo`:

```bash
./install-cloudflare-docker-allowlist.sh
sudo systemctl start cloudflare-docker-allowlist.service
sudo systemctl start cloudflare-docker-allowlist.timer
```

What each command does:

- `./install-cloudflare-docker-allowlist.sh`: copies the script to `/usr/local/sbin/`, installs the systemd files into `/etc/systemd/system/`, reloads `systemd`, and enables the service and timer
- `sudo systemctl start cloudflare-docker-allowlist.service`: runs the allowlist immediately once
- `sudo systemctl start cloudflare-docker-allowlist.timer`: starts the daily refresh schedule immediately

The installer enables the timer for future boots, but it does not start the timer right away. That is why starting it manually is still useful after install.

### Verify

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
- the `DOCKER-USER` chain should include the expected `RETURN` rules followed by a final `DROP` for `80,443`

### When you forget later

If you only have a minute to re-understand the allowlist, run:

```bash
sudo systemctl status cloudflare-docker-allowlist.timer
sudo systemctl status cloudflare-docker-allowlist.service
sudo iptables -S DOCKER-USER
sudo ip6tables -S DOCKER-USER
```

Ask yourself:

1. Is the timer active?
2. Did the last service run succeed?
3. Is there still a final drop for Docker-published `80/443`?
4. Are there `RETURN` rules above it for Cloudflare, LAN, Docker bridges, and established traffic?

## Host network traffic logger

### What problem it solves

This logger records simple network traffic samples from Linux kernel counters.

Each run writes one JSON line so the data can later be shipped into ELK and graphed. The aim is to answer questions like:

"Which Pi was moving unusual traffic when the network became slow?"

### How it works

The traffic logger is not a forever-running daemon.

Instead:

- the `.service` runs the Python logger once
- the `.timer` decides when that one-shot run happens

The service runs this program:

- `/usr/bin/python3 /usr/local/sbin/host-network-traffic-logger.py ...`

That Python program reads interface counters from `/proc/net/dev`, compares them with the previous saved state, and appends one JSON record to the log.

### Traffic logger lifecycle

This is the easiest mental model to keep in your head:

1. The machine boots.
2. `systemd` starts the enabled timer.
3. The timer waits for `OnBootSec`.
4. The timer starts the logger service.
5. The service writes one sample and exits.
6. The timer waits for `OnUnitActiveSec`.
7. Repeat.

So after a reboot, the logger comes back automatically because the timer is enabled.

### Why the service often looks inactive

This is normal and important.

The logger service is a one-shot service. It runs briefly and exits.

So the healthy state is usually:

- `host-network-traffic-logger.timer`: active and waiting
- `host-network-traffic-logger.service`: inactive except for the brief moment when it runs

If the service shows a successful last run and the timer is active, that is usually fine.

### Live config files the installer writes

The installer writes these live files:

- `/usr/local/sbin/host-network-traffic-logger.py`: the installed logger program
- `/etc/default/host-network-traffic-logger`: host-specific settings such as interface and log directory
- `/etc/systemd/system/host-network-traffic-logger.service`: the installed service unit
- `/etc/systemd/system/host-network-traffic-logger.timer`: the installed timer unit
- `/etc/systemd/system/host-network-traffic-logger.timer.d/override.conf`: the live schedule override written by the installer
- `/etc/logrotate.d/host-network-traffic-logger`: the log rotation policy

The important distinction is:

- repo files are the source of truth you edit here
- `/etc/...` files are the installed live copies on the host

### Install the host network traffic logger

Run as root or via `sudo`:

```bash
sudo ./install-host-network-traffic-logger.sh --interface wlan0 --site home
```

Useful options:

- `--config-file PATH`: load host defaults from a repo-managed env file
- `--interface NAME`: interface to monitor; if omitted, the installer auto-detects the default route interface
- `--role NAME`: optional host role tag
- `--site NAME`: site tag for dashboards; default is `home`
- `--log-dir PATH`: where to write JSONL logs
- `--state-dir PATH`: where to keep the previous sample state
- `--interval-seconds N`: sample cadence; default is `60`
- `--no-start`: install and enable, but do not start immediately

The installer does all of this in one go:

- copies the Python logger into `/usr/local/sbin/`
- installs the service and timer into `/etc/systemd/system/`
- installs the logrotate file
- writes `/etc/default/host-network-traffic-logger`
- writes the timer override file
- creates the log and state directories
- reloads `systemd`
- enables the timer
- by default, restarts both the service and timer immediately

### What happens if you run the installer again

Re-running the installer is usually an update, not a destructive rebuild.

It will:

- refresh the installed program and unit files
- rewrite the host config file
- rewrite the timer override with the selected interval
- reload `systemd`
- ensure the timer is enabled
- restart the service and timer immediately unless `--no-start` is used

In practical terms, a reinstall usually means:

- one fresh sample may be taken immediately
- the timer schedule starts counting again from that restart point

If you want to update the installed files without immediately restarting the active schedule, use:

```bash
sudo ./install-host-network-traffic-logger.sh --no-start ...
```

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

Use the 10-second cadence for short diagnostic windows, not as the permanent default, unless you are intentionally rotating logs for that higher volume.

### Log rotation

The installer also installs a logrotate policy at `/etc/logrotate.d/host-network-traffic-logger`.

That policy:

- rotates daily
- keeps 30 rotated files
- compresses old logs
- uses `copytruncate` so the active JSONL file can keep being written without stopping the service pattern

### Verify

```bash
sudo systemctl status host-network-traffic-logger.service
sudo systemctl status host-network-traffic-logger.timer
sudo systemctl list-timers --all | grep host-network-traffic
sudo cat /etc/default/host-network-traffic-logger
sudo cat /etc/systemd/system/host-network-traffic-logger.timer.d/override.conf
sudo cat /etc/logrotate.d/host-network-traffic-logger
LOG_DIR=$(grep '^NETWORK_TRAFFIC_LOG_DIR=' /etc/default/host-network-traffic-logger | cut -d= -f2-)
sudo tail -n 5 "$LOG_DIR"/network_traffic_$(hostname).jsonl
```

What to look for:

- the timer should be `active (waiting)`
- the service should show a successful recent run, even if it is currently inactive
- `/etc/default/host-network-traffic-logger` should show the interface and log directory you expect
- the override file should show the interval you expect
- the JSONL log should contain recent entries with the current hostname and byte deltas

### When you forget later

If you only have 60 seconds to re-understand the logger, run:

```bash
sudo systemctl status host-network-traffic-logger.timer
sudo systemctl status host-network-traffic-logger.service
sudo cat /etc/default/host-network-traffic-logger
sudo cat /etc/systemd/system/host-network-traffic-logger.timer.d/override.conf
```

Ask yourself:

1. Is the timer active?
2. Did the last service run succeed?
3. Is the correct interface configured?
4. Is the log directory what I expected?
5. Is the interval still what I intended?

## ELK ingest

Example ingest snippets live here:

- `elk/filebeat/host-network-traffic-input.yml`
- `elk/logstash/host-network-traffic.conf`

Recommended approach:

1. Use Filebeat `filestream` with NDJSON parsing against the actual configured log directory.
2. Preserve fields like `host_name`, `role`, `site`, `tx_bytes_delta`, `rx_bytes_delta`, and `window_seconds` at the top level.
3. In Logstash, coerce `rx_bytes_delta`, `tx_bytes_delta`, and `window_seconds` to numeric types if your pipeline would otherwise treat them as strings.

Dashboard guidance lives in `monitoring/network-traffic/kibana-dashboard-notes.md`.

The logger emits a deliberately slim event shape:

- `timestamp`
- `host_name`
- `site`
- `role`
- `interface`
- `window_seconds`
- `rx_bytes_delta`
- `tx_bytes_delta`

If you want bytes-per-second in Kibana, derive it from `*_bytes_delta / window_seconds` rather than storing the calculated rate in every event.

## Notes

- This repo is infrastructure-level, not app-level.
- App repositories such as PhotoSite should document their dependency on this protection, but should not treat live files under `/usr/local` or `/etc/systemd/system` as the source of truth.

## Structure and naming

The current repo name is slightly narrower than the scope the contents are growing into, but it is still reasonable to keep it for now.

Practical recommendation:

1. Keep the repo name as `pi5-infra` for now so existing references stay stable.
2. Keep broadening the internal structure under generic paths such as `monitoring/`, `systemd/`, and `config/`.
3. Treat Pi5-specific items as one category inside the repo, not the repo's only purpose.

If this becomes the canonical infra repo for multiple hosts and accumulates substantially more shared automation, a later rename to something like `pi-infra` or `homelab-infra` would make more sense.