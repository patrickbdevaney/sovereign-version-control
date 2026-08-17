#!/usr/bin/env bash
# Install the timers, substituting this repo's real path into the unit files.
#
#   sudo ./scripts/install-systemd.sh
#
# The units are stored in the repo with a __REPO_ROOT__ placeholder so that no
# machine-specific path is ever committed.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo $0" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT_DIR=/etc/systemd/system

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

say "Installing units (REPO_ROOT=$REPO_ROOT)"
for f in "$REPO_ROOT"/systemd/*.service "$REPO_ROOT"/systemd/*.timer; do
  name="$(basename "$f")"
  sed "s|__REPO_ROOT__|$REPO_ROOT|g" "$f" > "$UNIT_DIR/$name"
  chmod 0644 "$UNIT_DIR/$name"
  echo "  $name"
done

say "Reloading systemd"
systemctl daemon-reload

say "Enabling timers"
systemctl enable --now forgejo-backup.timer
systemctl enable --now forgejo-health.timer
systemctl enable --now forgejo-verify.timer

say "Timer schedule"
systemctl list-timers 'forgejo-*' --no-pager

cat <<'EOF'

Useful commands:
  systemctl start forgejo-backup.service     # run a backup right now
  journalctl -u forgejo-backup -f            # follow backup output
  systemctl list-timers 'forgejo-*'          # next scheduled runs
  cat /var/log/forgejo-alerts.log            # failure history
EOF
