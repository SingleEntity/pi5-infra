#!/usr/bin/env bash
set -euo pipefail

LAN_CIDR="${LAN_CIDR:-10.0.0.0/24}"

CFV4_URL="https://www.cloudflare.com/ips-v4"
CFV6_URL="https://www.cloudflare.com/ips-v6"

IPSET4="cloudflare4"
IPSET6="cloudflare6"

log() {
  echo "[cloudflare-allowlist] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

ensure_ipset_family() {
  local set_name="$1"
  local want_family="$2"

  if ipset list "$set_name" >/dev/null 2>&1; then
    if ! ipset list "$set_name" 2>/dev/null | grep -q "Header: family ${want_family} "; then
      log "Recreating ipset '${set_name}' with family ${want_family} (was different)"
      ipset destroy "$set_name" || true
    fi
  fi

  ipset create "$set_name" hash:net family "$want_family" -exist
}

refresh_ipset() {
  local set_name="$1"
  local url="$2"

  ipset flush "$set_name"

  curl -fsSL "$url" | while IFS= read -r cidr; do
    cidr="${cidr//$'\r'/}"
    [[ -z "$cidr" ]] && continue
    [[ "$cidr" != */* ]] && continue
    ipset add "$set_name" "$cidr" -exist
  done
}

ensure_rule() {
  local cmd="$1"
  shift

  local sep_idx=-1
  local i=0
  for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then
      sep_idx=$i
      break
    fi
    i=$((i+1))
  done

  if [[ $sep_idx -lt 0 ]]; then
    echo "ensure_rule: missing -- separator" >&2
    exit 1
  fi

  local -a check_args=("${@:1:$sep_idx}")
  local -a insert_args=("${@:$((sep_idx+2))}")

  if ! "$cmd" -C DOCKER-USER "${check_args[@]}" 2>/dev/null; then
    "$cmd" -I DOCKER-USER 1 "${insert_args[@]}"
  fi
}

main() {
  require_cmd ipset
  require_cmd curl
  require_cmd iptables
  require_cmd ip6tables

  if ! iptables -nL DOCKER-USER >/dev/null 2>&1; then
    log "DOCKER-USER chain not found (Docker not running yet). Skipping rule apply."
    exit 0
  fi

  log "Ensuring ipset sets exist with correct address families..."
  ensure_ipset_family "$IPSET4" inet
  ensure_ipset_family "$IPSET6" inet6

  log "Refreshing Cloudflare IP ranges into ipset sets..."
  refresh_ipset "$IPSET4" "$CFV4_URL"
  refresh_ipset "$IPSET6" "$CFV6_URL" || true

  log "Applying IPv4 allowlist rules for Docker-published 80/443..."
  ensure_rule iptables \
    -p tcp -m multiport --dports 80,443 -j DROP -- \
    -p tcp -m multiport --dports 80,443 -j DROP

  ensure_rule iptables \
    -p tcp -m multiport --dports 80,443 -m set --match-set "$IPSET4" src -j RETURN -- \
    -p tcp -m multiport --dports 80,443 -m set --match-set "$IPSET4" src -j RETURN

  ensure_rule iptables \
    -p tcp -m multiport --dports 80,443 -i br+ -j RETURN -- \
    -p tcp -m multiport --dports 80,443 -i br+ -j RETURN

  ensure_rule iptables \
    -s "$LAN_CIDR" -j RETURN -- \
    -s "$LAN_CIDR" -j RETURN

  ensure_rule iptables \
    -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN -- \
    -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN

  log "Applying IPv6 allowlist rules for Docker-published 80/443 (if in use)..."
  if ip6tables -nL DOCKER-USER >/dev/null 2>&1; then
    ensure_rule ip6tables \
      -p tcp -m multiport --dports 80,443 -j DROP -- \
      -p tcp -m multiport --dports 80,443 -j DROP

    ensure_rule ip6tables \
      -p tcp -m multiport --dports 80,443 -m set --match-set "$IPSET6" src -j RETURN -- \
      -p tcp -m multiport --dports 80,443 -m set --match-set "$IPSET6" src -j RETURN

    ensure_rule ip6tables \
      -p tcp -m multiport --dports 80,443 -i br+ -j RETURN -- \
      -p tcp -m multiport --dports 80,443 -i br+ -j RETURN

    ensure_rule ip6tables \
      -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN -- \
      -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
  fi

  log "Done."
}

main "$@"