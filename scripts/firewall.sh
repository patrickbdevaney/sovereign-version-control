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
run "$REPO_ROOT/scripts/docker-user-rules.sh"

say "Persisting DOCKER-USER rules across reboot and docker restarts"
# ufw persists its own rules. The DOCKER-USER rules do not persist, and Docker
# FLUSHES that chain every time the daemon starts -- so they need reapplying,
# not merely saving.
#
# We deliberately do NOT use iptables-persistent here. On Ubuntu 25.10 that
# package conflicts with ufw, and apt resolves the conflict by REMOVING ufw,
# which silently leaves the host with INPUT policy ACCEPT and no filtering.
# A systemd unit ordered after docker.service is both safer and more correct.
if [ "$APPLY" -eq 1 ]; then
  sed "s|__REPO_ROOT__|$REPO_ROOT|g" \
    "$REPO_ROOT/systemd/forgejo-docker-firewall.service" \
    > /etc/systemd/system/forgejo-docker-firewall.service
  chmod 0644 /etc/systemd/system/forgejo-docker-firewall.service
  systemctl daemon-reload
  systemctl enable --now forgejo-docker-firewall.service
  systemctl --no-pager --lines=0 status forgejo-docker-firewall.service | head -4
else
  echo "  [dry-run] install + enable forgejo-docker-firewall.service"
fi

say "Resulting state"
if [ "$APPLY" -eq 1 ]; then
  ufw status verbose
  echo; echo "DOCKER-USER (v4):"; iptables -L DOCKER-USER -n --line-numbers
else
  echo "  (dry run - re-run with --apply to see real state)"
fi
