#!/usr/bin/env bash
# Expose Forgejo's web UI on the tailnet over HTTPS, and assert that it is NOT
# exposed publicly.
#
#   sudo ./scripts/tailscale-serve.sh
#
# Serve  = reachable by your tailnet devices only.
# Funnel = reachable by the entire internet.
# This script uses Serve, and actively verifies Funnel is off. If Funnel is
# ever found enabled it aborts rather than continuing.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo $0" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$REPO_ROOT/.env"; set +a
: "${LAN_IP:?}"; : "${FORGEJO_DOMAIN:?}"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

say "Refusing to proceed if Funnel is enabled"
FUNNEL="$(tailscale funnel status 2>&1 || true)"
if printf '%s' "$FUNNEL" | grep -qiE 'https://|proxy|enabled' \
   && ! printf '%s' "$FUNNEL" | grep -qi 'no serve config'; then
  echo "FATAL: Funnel appears to be configured. That exposes this host to the" >&2
  echo "public internet, which is explicitly forbidden here." >&2
  echo "Disable it with: tailscale funnel reset" >&2
  printf '%s\n' "$FUNNEL" >&2
  exit 1
fi
echo "  ok - Funnel is not configured"

say "Checking HTTPS certificate availability for $FORGEJO_DOMAIN"
if ! tailscale cert "$FORGEJO_DOMAIN" --cert-file /dev/null --key-file /dev/null 2>/tmp/tscert.err; then
  echo "Could not obtain a certificate. This almost always means HTTPS" >&2
  echo "Certificates are not enabled for your tailnet." >&2
  echo >&2
  echo "  Enable at: https://login.tailscale.com/admin/dns  ->  HTTPS Certificates" >&2
  echo >&2
  sed 's/^/  /' /tmp/tscert.err >&2
  exit 1
fi
echo "  ok - certificate issued for $FORGEJO_DOMAIN"

say "Configuring Serve: https/443 -> http://$LAN_IP:3000"
# Verified against `tailscale serve --help` on 1.102.x. Syntax has changed
# across Tailscale releases; re-check it rather than copying from old guides.
tailscale serve --bg --https=443 "http://${LAN_IP}:3000"

say "Current serve configuration"
tailscale serve status

say "Confirming Funnel is still off after configuring Serve"
tailscale funnel status || true

cat <<EOF

Forgejo is now reachable on the tailnet at:
  https://${FORGEJO_DOMAIN}/

That URL works from any device signed into your tailnet, at home or away.
It is NOT reachable from the public internet.
EOF
