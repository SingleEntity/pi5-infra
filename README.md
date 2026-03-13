# pi5-infra

Tracked host-level infrastructure for the Pi5.

This repository exists to prevent production security and operational scripts from becoming untracked server state. The initial contents capture the Cloudflare allowlist workflow that protects Docker-published ports `80` and `443` on the live server.

## Contents

- `cloudflare-docker-allowlist/cloudflare-docker-allowlist.sh`
- `systemd/cloudflare-docker-allowlist.service`
- `systemd/cloudflare-docker-allowlist.timer`
- `install-cloudflare-docker-allowlist.sh`

## What it does

The Cloudflare allowlist workflow:

- creates and refreshes the `cloudflare4` and `cloudflare6` `ipset` sets from Cloudflare's published IP ranges
- inserts `DOCKER-USER` firewall rules so Docker-published `80/443` traffic is accepted only from Cloudflare IPs
- allows established traffic, local LAN access, and Docker bridge traffic to continue working
- drops all other inbound Docker traffic to `80/443`

This is intended to protect reverse proxies and web apps that are expected to sit behind Cloudflare.

## Install or refresh on the Pi5

Run as root or via `sudo`:

```bash
./install-cloudflare-docker-allowlist.sh
sudo systemctl start cloudflare-docker-allowlist.service
```

## Verification

```bash
sudo systemctl status cloudflare-docker-allowlist.service
sudo systemctl list-timers --all | grep cloudflare
sudo ipset list cloudflare4
sudo ipset list cloudflare6
sudo iptables -S DOCKER-USER
sudo ip6tables -S DOCKER-USER
```

## Notes

- This repo is infrastructure-level, not app-level.
- App repositories such as PhotoSite should document their dependency on this protection, but should not treat live files under `/usr/local` or `/etc/systemd/system` as the source of truth.