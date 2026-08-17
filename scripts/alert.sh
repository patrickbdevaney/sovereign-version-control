#!/usr/bin/env bash
# Failure notifier for the Forgejo timers. Deliberately dependency-free: no
# SMTP, no webhook, no third party. A single-user instance does not need a
# monitoring stack, but a failure must not be silent either.
#
#   alert.sh <failed-unit-name>
#
# Delivery: persistent log file + journal + desktop notification (if someone is
# logged into a graphical session) + wall to any logged-in terminal.
set -uo pipefail

UNIT="${1:-unknown}"
LOG=/var/log/forgejo-alerts.log
STAMP="$(date -Is)"
MSG="Forgejo: unit '$UNIT' FAILED at $STAMP"

mkdir -p "$(dirname "$LOG")"
{
  echo "=============================================================="
  echo "$MSG"
  echo "--- last 30 journal lines ---"
  journalctl -u "$UNIT" -n 30 --no-pager 2>/dev/null
  echo
} >> "$LOG"
chmod 640 "$LOG" 2>/dev/null || true

logger -t forgejo-alert -p daemon.err "$MSG"

# Desktop notification, if a graphical session exists.
for u in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $2}'); do
  uid="$(id -u "$u" 2>/dev/null)" || continue
  [ -S "/run/user/$uid/bus" ] || continue
  sudo -u "$u" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    notify-send -u critical "Forgejo backup/health failure" \
      "$UNIT failed. See $LOG" 2>/dev/null || true
done

wall "$MSG (details: $LOG)" 2>/dev/null || true
exit 0
