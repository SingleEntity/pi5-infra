#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -D -m 0755 \
  "$SCRIPT_DIR/cloudflare-docker-allowlist/cloudflare-docker-allowlist.sh" \
  /usr/local/sbin/cloudflare-docker-allowlist.sh

install -D -m 0644 \
  "$SCRIPT_DIR/systemd/cloudflare-docker-allowlist.service" \
  /etc/systemd/system/cloudflare-docker-allowlist.service

install -D -m 0644 \
  "$SCRIPT_DIR/systemd/cloudflare-docker-allowlist.timer" \
  /etc/systemd/system/cloudflare-docker-allowlist.timer

systemctl daemon-reload
systemctl enable cloudflare-docker-allowlist.service
systemctl enable cloudflare-docker-allowlist.timer

echo "Installed Cloudflare Docker allowlist units."
echo "Run: sudo systemctl start cloudflare-docker-allowlist.service"