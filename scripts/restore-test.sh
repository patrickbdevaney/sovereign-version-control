#!/usr/bin/env bash
# Prove the backup is actually restorable. A backup job that exits 0 is not
# evidence of anything; only a restore is.
#
#   sudo ./scripts/restore-test.sh
#
# What it proves:
#   1. the snapshot can be decrypted and extracted;
#   2. restored git repositories are valid (git fsck on a real repo);
#   3. the database dump loads into a throwaway Postgres and contains the
#      expected Forgejo tables with plausible row counts.
#
# Everything happens in a scratch directory that is removed on exit. Nothing
# touches the live instance.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$REPO_ROOT/.env"; set +a
: "${RESTIC_REPOSITORY:?}"; : "${RESTIC_PASSWORD:?}"
: "${POSTGRES_VERSION:=17-alpine}"

SCRATCH="$(mktemp -d /var/tmp/forgejo-restore-test.XXXXXX)"
PGTMP="forgejo-restore-test-db"
PASS=0; FAIL=0

cleanup() {
  docker rm -f "$PGTMP" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL+1)); }
say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

say "Latest snapshot"
restic snapshots --tag forgejo --compact | tail -5
SNAP="$(restic snapshots --tag forgejo --json | jq -r '.[-1].short_id')"
[ -n "$SNAP" ] && [ "$SNAP" != "null" ] || { echo "no snapshot to restore"; exit 1; }
echo "restoring snapshot $SNAP"

say "Restoring into $SCRATCH"
restic restore "$SNAP" --target "$SCRATCH"

# --- 1. repository data -----------------------------------------------------
say "Verifying restored git repositories"
# The Forgejo container image sets [repository] ROOT = /data/git/repositories,
# which is /var/lib/forgejo/data/git/repositories on the host. It is NOT
# "gitea-repositories" -- that is the bare-metal Gitea default.
REPO_BASE="$SCRATCH/var/lib/forgejo/data/git/repositories"
LIVE_REPO_COUNT="$(find /var/lib/forgejo/data/git/repositories -maxdepth 2 \
                     -name '*.git' -type d 2>/dev/null | wc -l)"
if [ ! -d "$REPO_BASE" ] && [ "$LIVE_REPO_COUNT" -eq 0 ]; then
  # A brand-new instance genuinely has no repositories. That is not a backup
  # failure -- but it does mean this run proves nothing about repository data,
  # so say so rather than reporting a misleading pass.
  printf '  \033[33mSKIP\033[0m  no repositories exist yet; repository restore is UNPROVEN\n'
elif [ -d "$REPO_BASE" ]; then
  COUNT="$(find "$REPO_BASE" -maxdepth 2 -name '*.git' -type d | wc -l)"
  if [ "$COUNT" -ne "$LIVE_REPO_COUNT" ]; then
    bad "restored $COUNT repositories but the live instance has $LIVE_REPO_COUNT"
  else
    ok "found $COUNT bare repositories (matches live instance)"
  fi
  BROKEN=0
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    if git --git-dir="$r" fsck --no-progress --no-dangling >/dev/null 2>&1; then
      printf '        ok  %s\n' "$(basename "$r")"
    else
      printf '        BROKEN %s\n' "$r"; BROKEN=$((BROKEN+1))
    fi
  done < <(find "$REPO_BASE" -maxdepth 2 -name '*.git' -type d)
  [ "$BROKEN" -eq 0 ] && ok "git fsck clean on all repositories" \
                      || bad "$BROKEN repositories failed git fsck"
else
  # Directory absent from the snapshot while the live instance HAS repos is a
  # genuine backup failure.
  bad "live instance has $LIVE_REPO_COUNT repositories but none are in the snapshot"
fi

# --- 2. database dump -------------------------------------------------------
say "Verifying database dump restores"
DUMP="$SCRATCH/var/lib/forgejo/dump/forgejo-db.dump"
if [ ! -f "$DUMP" ]; then
  bad "no database dump in snapshot"
else
  ok "dump present ($(du -h "$DUMP" | cut -f1))"
  docker run -d --rm --name "$PGTMP" \
    -e POSTGRES_PASSWORD=restoretest \
    -e POSTGRES_USER=forgejo -e POSTGRES_DB=forgejo \
    "postgres:${POSTGRES_VERSION}" >/dev/null
  for _ in $(seq 1 45); do
    docker exec "$PGTMP" pg_isready -U forgejo -d forgejo >/dev/null 2>&1 && break
    sleep 1
  done
  if ! docker exec "$PGTMP" pg_isready -U forgejo -d forgejo >/dev/null 2>&1; then
    bad "throwaway postgres did not become ready"
  else
    ok "throwaway postgres ready"
    if docker exec -i "$PGTMP" pg_restore -U forgejo -d forgejo --no-owner \
         < "$DUMP" >/dev/null 2>"$SCRATCH/pgerr.txt"; then
      ok "pg_restore completed"
    else
      # pg_restore warns about roles/extensions routinely; only hard errors matter.
      if grep -qiE '^pg_restore: error' "$SCRATCH/pgerr.txt"; then
        bad "pg_restore reported errors:"; sed -n '1,10p' "$SCRATCH/pgerr.txt"
      else
        ok "pg_restore completed (warnings only)"
      fi
    fi
    q() { docker exec "$PGTMP" psql -U forgejo -d forgejo -tAc "$1" 2>/dev/null || echo ERR; }
    TABLES="$(q "select count(*) from information_schema.tables where table_schema='public'")"
    USERS="$(q "select count(*) from \"user\"")"
    REPOS="$(q "select count(*) from repository")"
    [ "$TABLES" != "ERR" ] && [ "${TABLES:-0}" -gt 50 ] \
      && ok "schema restored: $TABLES tables" || bad "schema looks wrong: $TABLES tables"
    [ "$USERS" != "ERR" ] && ok "user table queryable: $USERS users" \
                          || bad "user table missing/unqueryable"
    [ "$REPOS" != "ERR" ] && ok "repository table queryable: $REPOS repositories" \
                          || bad "repository table missing/unqueryable"
  fi
fi

# --- 3. secrets -------------------------------------------------------------
say "Verifying .env travelled with the backup"
if find "$SCRATCH" -name '.env' -type f | grep -q .; then
  ENVF="$(find "$SCRATCH" -name '.env' -type f | head -1)"
  grep -q '^FORGEJO_SECRET_KEY=' "$ENVF" \
    && ok "SECRET_KEY present (2FA secrets will be decryptable after restore)" \
    || bad "SECRET_KEY missing from restored .env"
else
  bad ".env not found in snapshot"
fi

say "Result"
printf '  passed: %d   failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '\n\033[31mRESTORE TEST FAILED - do not consider this backup trustworthy.\033[0m\n'
  exit 1
fi
printf '\n\033[32mRESTORE TEST PASSED - backup proven restorable.\033[0m\n'
