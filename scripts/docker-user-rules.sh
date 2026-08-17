#!/usr/bin/env bash
# Apply the DOCKER-USER rules that constrain Docker-published ports.
#
# Split out from firewall.sh because these rules need reapplying every time
# Docker starts -- Docker recreates and flushes DOCKER-USER on daemon start, so
# rules added once do not survive a restart or a reboot.
#
# Installed as forgejo-docker-firewall.service (After=docker.service).
#
# NOTE: this deliberately does NOT use iptables-persistent. On Ubuntu 25.10 the
# iptables-persistent package CONFLICTS with ufw, and apt resolves that by
# removing ufw -- silently leaving the host with no inbound filtering at all.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$REPO_ROOT/.env"; set +a
: "${LAN_SUBNET:?}"; : "${FORGEJO_SSH_PORT:?}"
TS_IF=tailscale0

apply() {
  local ipt="$1" subnet="$2"
  # DOCKER-USER may not exist yet if docker has never started.
  "$ipt" -N DOCKER-USER 2>/dev/null || true
  "$ipt" -F DOCKER-USER
  "$ipt" -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
  "$ipt" -A DOCKER-USER -i "$TS_IF" -j RETURN
  [ -n "$subnet" ] && "$ipt" -A DOCKER-USER -s "$subnet" -j RETURN
  "$ipt" -A DOCKER-USER -i lo -j RETURN
  "$ipt" -A DOCKER-USER -p tcp --dport 3000 -j DROP
  "$ipt" -A DOCKER-USER -p tcp --dport "$FORGEJO_SSH_PORT" -j DROP
  "$ipt" -A DOCKER-USER -j RETURN
}

apply iptables "$LAN_SUBNET"
# No container port is published on IPv6, so anything arriving there aimed at a
# container port is dropped outright.
apply ip6tables ""

echo "DOCKER-USER rules applied (LAN=$LAN_SUBNET, iface=$TS_IF)"
