#!/usr/bin/env bash
# Lightweight health baseline for a single-user instance. Intentionally not a
# monitoring stack.
#
#   sudo ./scripts/healthcheck.sh
#
# Checks:
#   1. Forgejo + Postgres containers running and healthy
#   2. Forgejo HTTP responding on the LAN bind
#   3. last backup succeeded, and was recent
#   4. disk usage on the data volume below DISK_WARN_PCT
#   5. restic repository size below RESTIC_WARN_BYTES
#   6. Funnel still disabled (i.e. nothing has become public)
#
# Exits non-zero if anything is wrong, so `systemctl status` and the timer's
# OnFailure hook reflect real state.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$REPO_ROOT/.env"; set +a
DISK_WARN_PCT="${DISK_WARN_PCT:-80}"
RESTIC_WARN_BYTES="${RESTIC_WARN_BYTES:-8589934592}"
DATA_DIR=/var/lib/forgejo/data

PROBLEMS=0
ok()  { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
bad() { printf '  \033[31mALERT\033[0m %s\n' "$*"; PROBLEMS=$((PROBLEMS+1)); }

echo "Forgejo health $(date -Is)"

# --- 1. containers ----------------------------------------------------------
for c in forgejo forgejo-db; do
  state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo none)"
  if [ "$state" = "running" ] && { [ "$health" = "healthy" ] || [ "$health" = "none" ]; }; then
    ok "container $c: $state${health:+ ($health)}"
  else
    bad "container $c: state=$state health=$health"
  fi
done

# --- 2. HTTP ----------------------------------------------------------------
if curl -fsS -m 10 -o /dev/null "http://${LAN_IP}:3000/api/healthz" 2>/dev/null; then
  ok "HTTP responding on ${LAN_IP}:3000"
else
  bad "HTTP not responding on ${LAN_IP}:3000"
fi

# --- 3. backup freshness ----------------------------------------------------
if systemctl is-failed --quiet forgejo-backup.service; then
  bad "last backup run FAILED (journalctl -u forgejo-backup)"
else
  ok "backup service not in failed state"
fi

LAST="$(restic snapshots --tag forgejo --json 2>/dev/null | jq -r '.[-1].time // empty' 2>/dev/null || true)"
if [ -n "$LAST" ]; then
  AGE_H=$(( ( $(date +%s) - $(date -d "$LAST" +%s) ) / 3600 ))
  if [ "$AGE_H" -le 48 ]; then
    ok "most recent snapshot ${AGE_H}h old"
  else
    bad "most recent snapshot is ${AGE_H}h old (>48h) - backups may have stopped"
  fi
else
  bad "no snapshots found in restic repository"
fi

# --- 4. disk ----------------------------------------------------------------
PCT="$(df --output=pcent "$DATA_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "$PCT" ] && [ "$PCT" -lt "$DISK_WARN_PCT" ]; then
  ok "disk at ${PCT}% (threshold ${DISK_WARN_PCT}%)"
else
  bad "disk at ${PCT}% - at or above ${DISK_WARN_PCT}% threshold"
fi

# --- 5. restic repo size ----------------------------------------------------
case "$RESTIC_REPOSITORY" in
  /*)
    SIZE="$(du -sb "$RESTIC_REPOSITORY" 2>/dev/null | cut -f1)"
    if [ -n "$SIZE" ]; then
      HUMAN="$(numfmt --to=iec "$SIZE" 2>/dev/null || echo "$SIZE")"
      if [ "$SIZE" -lt "$RESTIC_WARN_BYTES" ]; then
        ok "restic repository $HUMAN"
      else
        bad "restic repository $HUMAN - above warning threshold"
      fi
    fi
    ;;
  *) ok "remote restic repository (size check skipped)" ;;
esac

# --- 6. still private -------------------------------------------------------
if tailscale funnel status 2>&1 | grep -qi 'no serve config\|Funnel is not'; then
  ok "Tailscale Funnel not configured (instance is not public)"
elif tailscale funnel status 2>&1 | grep -qiE '^https://.*\.ts\.net'; then
  bad "Tailscale FUNNEL APPEARS ACTIVE - this host may be publicly reachable"
else
  ok "Tailscale Funnel not active"
fi

echo
if [ "$PROBLEMS" -gt 0 ]; then
  echo "$PROBLEMS problem(s) found."
  exit 1
fi
echo "All checks passed."
