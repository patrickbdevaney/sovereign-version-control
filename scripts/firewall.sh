#!/usr/bin/env bash
# Restrict inbound reachability to: home LAN subnet + Tailscale interface.
# Everything else is denied, for IPv4 AND IPv6.
#
#   sudo ./scripts/firewall.sh            # dry run, prints what it would do
#   sudo ./scripts/firewall.sh --apply    # actually apply
#
# WHY THE DOCKER-USER CHAIN IS HERE
# ---------------------------------
# Docker publishes ports by writing its own DNAT/FORWARD rules, which are
# evaluated BEFORE ufw's INPUT chain. A `ufw deny 3000` therefore does NOT
# block a Docker-published port -- a very common and dangerous misconception.
# Two things actually constrain us:
#   1. compose binds each port to an explicit host IP (LAN_IP / TS_IP), so
#      Docker never listens on 0.0.0.0 or on any public IPv6 address; and
#   2. the DOCKER-USER rules below, which Docker guarantees are consulted
#      before its own ACCEPT rules.
#
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo $0" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$REPO_ROOT/.env"; set +a

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

: "${LAN_SUBNET:?}"; : "${FORGEJO_SSH_PORT:?}"
TS_IF=tailscale0

# Ports on this host that must remain reachable from the LAN/tailnet. Losing
# these mid-run would lock you out of your own machine.
declare -A KEEP_PORTS=(
  [22]="host sshd (currently inactive, allowed pre-emptively)"
  [3000]="Forgejo web UI"
  [$FORGEJO_SSH_PORT]="Forgejo git-over-SSH"
  [4000]="NoMachine remote desktop"
  [21115]="RustDesk"
  [21116]="RustDesk"
  [21117]="RustDesk"
  [21118]="RustDesk"
  [21119]="RustDesk"
)

run() {
  if [ "$APPLY" -eq 1 ]; then "$@"; else printf '  [dry-run] %s\n' "$*"; fi
}
say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

if [ "$APPLY" -eq 0 ]; then
  printf '\033[1;33mDRY RUN\033[0m - nothing will change. Re-run with --apply.\n'
fi

say "Baseline policy (applies to IPv4 and IPv6)"
run ufw --force reset >/dev/null 2>&1 || true
run ufw default deny incoming
run ufw default allow outgoing
# Explicitly deny routed traffic: this host must never act as a transit path.
run ufw default deny routed

say "Allow everything arriving on the Tailscale interface"
# The tailnet is an authenticated overlay; peers are already device-authorised.
run ufw allow in on "$TS_IF"

say "Allow specific ports from the home LAN subnet ($LAN_SUBNET) only"
for port in "${!KEEP_PORTS[@]}"; do
  printf '  %-6s %s\n' "$port" "${KEEP_PORTS[$port]}"
  run ufw allow from "$LAN_SUBNET" to any port "$port" proto tcp
done

say "Enabling ufw"
run ufw --force enable

# ---------------------------------------------------------------------------
# DOCKER-USER: the chain that actually governs Docker-published ports.
# ---------------------------------------------------------------------------
say "Constraining Docker-published ports via DOCKER-USER"
docker_user_rules() {
  local ipt="$1" subnet="$2"
  # Flush our previous rules so this script stays idempotent.
  run "$ipt" -F DOCKER-USER 2>/dev/null || true
  # Return traffic for connections we initiated must pass.
  run "$ipt" -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
  # Tailnet and LAN are permitted.
  run "$ipt" -A DOCKER-USER -i "$TS_IF" -j RETURN
  [ -n "$subnet" ] && run "$ipt" -A DOCKER-USER -s "$subnet" -j RETURN
  # Traffic originating on this host (compose healthchecks, tailscale serve).
  run "$ipt" -A DOCKER-USER -i lo -j RETURN
  # Anything else aimed at a container port is dropped.
  run "$ipt" -A DOCKER-USER -p tcp --dport 3000 -j DROP
  run "$ipt" -A DOCKER-USER -p tcp --dport "$FORGEJO_SSH_PORT" -j DROP
  run "$ipt" -A DOCKER-USER -j RETURN
}

if command -v iptables >/dev/null; then
  docker_user_rules iptables "$LAN_SUBNET"
fi
if command -v ip6tables >/dev/null; then
  # No container port is published on IPv6 (compose binds IPv4 host IPs only),
  # so IPv6 container traffic is dropped outright.
  docker_user_rules ip6tables ""
fi

say "Persisting rules across reboot"
# ufw persists itself; raw iptables rules do not. netfilter-persistent saves
# the DOCKER-USER chain. Without this, protection silently disappears on reboot.
if [ "$APPLY" -eq 1 ]; then
  if ! command -v netfilter-persistent >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iptables-persistent
  fi
  netfilter-persistent save
else
  echo "  [dry-run] apt-get install iptables-persistent && netfilter-persistent save"
fi

say "Resulting state"
if [ "$APPLY" -eq 1 ]; then
  ufw status verbose
  echo; echo "DOCKER-USER (v4):"; iptables -L DOCKER-USER -n --line-numbers
else
  echo "  (dry run - re-run with --apply to see real state)"
fi
