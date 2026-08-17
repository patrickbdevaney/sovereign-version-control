#!/usr/bin/env bash
# Nightly encrypted backup of everything that has no other copy.
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
# Dumped inside the container, streamed to a root-only file on the host.
log "dumping postgres"
docker compose --project-directory "$REPO_ROOT" exec -T db \
  pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner \
  > "$DUMP_FILE.tmp"
# Validate before promoting: a truncated dump that still exits 0 is the classic
# way to discover your backups were worthless only during a restore.
if ! pg_restore --list "$DUMP_FILE.tmp" >/dev/null 2>&1; then
  if ! docker compose --project-directory "$REPO_ROOT" exec -T db \
        pg_restore --list /dev/stdin < "$DUMP_FILE.tmp" >/dev/null 2>&1; then
    log "ERROR: pg_dump output failed validation; refusing to back up a bad dump"
    rm -f "$DUMP_FILE.tmp"
    exit 1
  fi
fi
mv "$DUMP_FILE.tmp" "$DUMP_FILE"
chmod 600 "$DUMP_FILE"
log "dump ok ($(du -h "$DUMP_FILE" | cut -f1))"

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
log "applying retention (daily=$RETENTION_DAILY weekly=$RETENTION_WEEKLY monthly=$RETENTION_MONTHLY)"
restic forget \
  --tag forgejo \
  --keep-daily "$RETENTION_DAILY" \
  --keep-weekly "$RETENTION_WEEKLY" \
  --keep-monthly "$RETENTION_MONTHLY" \
  --prune

# --- integrity --------------------------------------------------------------
# Structural check every run; it is cheap. A full --read-data pass is far more
# expensive and is left to the weekly verify timer.
log "checking repository structure"
restic check

log "snapshots now in repository:"
restic snapshots --tag forgejo --compact | tail -n 15

log "OK"
