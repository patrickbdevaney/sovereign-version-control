#!/usr/bin/env bash
# Encrypted backup of everything that has no other copy. Runs hourly; the
# schedule lives in systemd/forgejo-backup.timer.
#
#   sudo ./scripts/backup.sh
#
# Scope, and the reasoning for each item:
#   /var/lib/forgejo/data  repos, LFS, avatars, attachments  -- the actual IP
#   postgres dump          users, issues, PRs, permissions   -- pg_dump, not
#                          raw data files: copying a live PGDATA directory
#                          yields a torn, possibly unrestorable database
#   .env                   SECRET_KEY encrypts 2FA secrets and stored
#                          credentials. Without it a restore leaves those
#                          undecryptable, so it must travel with the backup.
#
# NOT in scope: this repo's compose files and scripts. They live in git and
# have another copy by definition.
#
# restic encrypts client-side, so the storage location never sees plaintext.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$REPO_ROOT/.env"; set +a

: "${RESTIC_REPOSITORY:?}"; : "${RESTIC_PASSWORD:?}"
: "${POSTGRES_USER:?}";     : "${POSTGRES_DB:?}"
RETENTION_HOURLY="${RETENTION_HOURLY:-48}"
RETENTION_DAILY="${RETENTION_DAILY:-14}"
RETENTION_WEEKLY="${RETENTION_WEEKLY:-8}"
RETENTION_MONTHLY="${RETENTION_MONTHLY:-12}"

DATA_DIR=/var/lib/forgejo/data
DUMP_DIR=/var/lib/forgejo/dump
DUMP_FILE="$DUMP_DIR/forgejo-db.dump"

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }
# Never let a failure pass silently: systemd must see a non-zero exit.
trap 'log "FAILED at line $LINENO"; exit 1' ERR

umask 077
mkdir -p "$DUMP_DIR"

log "restic $(restic version | awk '{print $2}') -> repository ${RESTIC_REPOSITORY}"

# --- initialise repository on first run ------------------------------------
if ! restic cat config >/dev/null 2>&1; then
  log "repository not initialised; creating it"
  restic init
fi

# --- database dump ----------------------------------------------------------
# -Fc (custom format) so pg_restore can do selective/parallel restores.
#
# The dump is written to a file INSIDE the container and validated there,
# then copied out. Two reasons this is not piped through stdout:
#   - the host has no postgresql-client, so no host-side pg_restore; and
#   - `pg_restore --list` on a custom-format dump needs SEEKABLE input, so
#     validating via /dev/stdin fails with "did not find magic string in file
#     header" even when the dump is perfectly good.
DC=(docker compose --project-directory "$REPO_ROOT")
CTMP=/tmp/forgejo-db.dump

log "dumping postgres"
"${DC[@]}" exec -T db pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -Fc --no-owner -f "$CTMP"

# Validate before promoting: a truncated dump that still exits 0 is the classic
# way to discover your backups were worthless only during a restore.
if ! "${DC[@]}" exec -T db pg_restore --list "$CTMP" >/dev/null 2>&1; then
  log "ERROR: pg_dump output failed validation; refusing to back up a bad dump"
  "${DC[@]}" exec -T db rm -f "$CTMP" || true
  exit 1
fi
ENTRIES="$("${DC[@]}" exec -T db pg_restore --list "$CTMP" 2>/dev/null | grep -c ';' || true)"

"${DC[@]}" cp "db:$CTMP" "$DUMP_FILE"
"${DC[@]}" exec -T db rm -f "$CTMP" || true
chmod 600 "$DUMP_FILE"

# The copy itself can truncate; confirm the file that landed on disk is sane.
[ -s "$DUMP_FILE" ] || { log "ERROR: copied dump is empty"; exit 1; }
[ "$(head -c 5 "$DUMP_FILE")" = "PGDMP" ] \
  || { log "ERROR: copied dump lacks the PGDMP header"; exit 1; }
log "dump ok ($(du -h "$DUMP_FILE" | cut -f1), $ENTRIES archive entries)"

# --- backup -----------------------------------------------------------------
log "backing up"
restic backup \
  --tag forgejo \
  --host "$(hostname)" \
  --exclude-caches \
  --exclude "$DATA_DIR/gitea/log" \
  --exclude "$DATA_DIR/gitea/tmp" \
  --exclude "$DATA_DIR/gitea/sessions" \
  "$DATA_DIR" "$DUMP_FILE" "$REPO_ROOT/.env"

# --- retention --------------------------------------------------------------
#
# --keep-hourly is REQUIRED given the hourly schedule. `restic forget` keeps
# only the LAST snapshot of each day for --keep-daily, so an hourly job with
# no --keep-hourly deletes the previous hour's snapshot every single run: you
# get freshness but lose the ability to roll back to earlier the same day,
# which is exactly what you want after an accidental delete or a bad
# force-push.
#
# NOTE: no --prune here. Prune repacks the repository and is the expensive
# half; under an hourly schedule it would run every hour. It is done on the
# weekly forgejo-verify timer instead. Snapshots forgotten here stop being
# visible immediately; prune is only what reclaims their space.
if [ "${RESTIC_APPEND_ONLY:-false}" = "true" ]; then
  # Immutable target (e.g. an R2 bucket lock). `forget` deletes snapshot
  # objects, so it CANNOT succeed against a locked bucket -- attempting it
  # would fail the run and fire an alert every hour.
  #
  # This is the deliberate trade: the backup becomes append-only, so a
  # compromised forge cannot destroy history, and in exchange nothing is ever
  # reclaimed automatically. For mostly-text repositories that is tens of MB
  # per year. Prune manually from a trusted machine if it ever matters.
  log "append-only mode: skipping retention (target is immutable)"
else
  log "applying retention (hourly=$RETENTION_HOURLY daily=$RETENTION_DAILY weekly=$RETENTION_WEEKLY monthly=$RETENTION_MONTHLY)"
  restic forget \
    --tag forgejo \
    --keep-hourly "$RETENTION_HOURLY" \
    --keep-daily "$RETENTION_DAILY" \
    --keep-weekly "$RETENTION_WEEKLY" \
    --keep-monthly "$RETENTION_MONTHLY"
fi

# --- integrity --------------------------------------------------------------
# Structural check every run; it is cheap. A full --read-data pass is far more
# expensive and is left to the weekly verify timer.
log "checking repository structure"
restic check

log "snapshots now in repository:"
restic snapshots --tag forgejo --compact | tail -n 15

log "OK"
