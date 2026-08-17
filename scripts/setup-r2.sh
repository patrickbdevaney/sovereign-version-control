#!/usr/bin/env bash
# Guided migration of the restic backup target to Cloudflare R2.
#
#   sudo ./scripts/setup-r2.sh
#
# Prompts for your R2 details, validates them BEFORE changing anything, backs
# up your current .env, switches the target, then runs a real backup AND a real
# restore test. It refuses to report success until a restore has actually
# worked -- a backup you have never restored is a hypothesis, not a backup.
#
# Safe to abort at any prompt: nothing is written until validation passes, and
# the previous .env is always kept as .env.bak-<timestamp>.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo $0" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
[ -f "$ENV_FILE" ] || { echo "no .env found" >&2; exit 1; }

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
die()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*" >&2; exit 1; }

cat <<'INTRO'
============================================================
  Switch restic backups to Cloudflare R2
============================================================

In the Cloudflare dashboard:

  1. R2 -> Create bucket. Keep it PRIVATE. Remember the bucket name.
  2. R2 -> Manage R2 API Tokens -> Create API Token
       Permission: Object Read & Write
       Scope:      ONLY the bucket you just made (not "all buckets")

Cloudflare then shows a block containing the Access Key ID, the Secret
Access Key, and an endpoint URL. Copy that WHOLE block -- you do not need
to pick the values out of it yourself.

NOTE: your Account ID is NOT your email address. It is a 32-character hex
string, and it is embedded in the endpoint URL, so pasting the block below
supplies it automatically.
INTRO

# Non-secret values may be preset in the environment so that only the actual
# credentials need to be typed:
#   sudo R2_BUCKET=my-bucket R2_ACCOUNT=<32-hex> ./scripts/setup-r2.sh
R2_BUCKET="${R2_BUCKET:-}"
R2_ACCOUNT_PRESET="${R2_ACCOUNT:-}"

if [ -n "$R2_BUCKET" ]; then
  echo; echo "Bucket name (preset): $R2_BUCKET"
else
  read -rp $'\nBucket name: ' R2_BUCKET
fi
[ -n "$R2_BUCKET" ] || die "bucket name is required"
[ -n "$R2_ACCOUNT_PRESET" ] && echo "Account ID  (preset): $R2_ACCOUNT_PRESET"

echo
echo "Now paste the Cloudflare credentials block, then press Ctrl-D:"
echo "(it does not matter how it is formatted, or what order it is in)"
BLOB="$(cat)"

# Pull each value out by shape rather than by label, since Cloudflare's
# formatting varies between the dashboard and the copy button:
#   account id  -> the 32-hex label inside the endpoint hostname
#   secret key  -> 64 hex chars
#   access key  -> a 32-hex string that is NOT the account id
R2_ACCOUNT="${R2_ACCOUNT_PRESET:-$(printf '%s' "$BLOB" | grep -oiE '[0-9a-f]{32}\.r2\.cloudflarestorage\.com' | head -1 | cut -d. -f1)}"
R2_SECRET="$(printf '%s' "$BLOB" | grep -oiE '\b[0-9a-f]{64}\b' | head -1)"
R2_KEY_ID="$(printf '%s' "$BLOB" | grep -oiE '\b[0-9a-f]{32}\b' \
             | grep -viF "${R2_ACCOUNT:-__none__}" | head -1)"

# Fall back to asking for anything the paste did not yield.
[ -n "$R2_ACCOUNT" ] || { echo; read -rp 'Account ID (32-char hex, NOT your email): ' R2_ACCOUNT; }
[ -n "$R2_KEY_ID" ]  || { read -rp 'Access Key ID: ' R2_KEY_ID; }
[ -n "$R2_SECRET" ]  || { read -rsp 'Secret Access Key: ' R2_SECRET; echo; }

echo
echo "Parsed:"
printf '  bucket        %s\n' "$R2_BUCKET"
printf '  account id    %s\n' "$R2_ACCOUNT"
printf '  access key    %s…%s\n' "${R2_KEY_ID:0:6}" "${R2_KEY_ID: -4}"
printf '  secret key    %s (%d chars, not shown)\n' "********" "${#R2_SECRET}"

case "$R2_ACCOUNT" in
  *@*) die "that account ID looks like an email address. It must be the 32-character hex ID from the R2 dashboard." ;;
esac
[ -n "$R2_ACCOUNT" ] && [ -n "$R2_KEY_ID" ] && [ -n "$R2_SECRET" ] \
  || die "could not determine all values; re-run and enter them manually"

read -rp $'\nProceed with these? [y/N] ' CONFIRM
case "$CONFIRM" in [yY]*) ;; *) echo "aborted; nothing changed"; exit 0 ;; esac

NEW_REPO="s3:https://${R2_ACCOUNT}.r2.cloudflarestorage.com/${R2_BUCKET}"

# Reuse the existing restic password so you keep ONE password to remember.
set -a; . "$ENV_FILE"; set +a
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD missing from .env}"
OLD_REPO="${RESTIC_REPOSITORY:-none}"

say "Validating credentials against R2 (nothing written yet)"
export AWS_ACCESS_KEY_ID="$R2_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET"
# R2 has no real region, but restic's S3 backend still signs requests with one.
# Without this you get opaque SigV4 signature errors, not a helpful message.
export AWS_DEFAULT_REGION=auto
export RESTIC_REPOSITORY="$NEW_REPO"

if restic cat config >/dev/null 2>&1; then
  ok "connected; a restic repository already exists in this bucket"
  EXISTING=1
else
  say "No repository there yet - initialising one"
  restic init >/dev/null 2>&1 || die "could not initialise. Check the account ID, bucket name, and that the token has Object Read & Write on THIS bucket."
  ok "repository initialised"
  EXISTING=0
fi

say "Backing up current .env"
STAMP="$(date +%Y%m%d-%H%M%S)"
cp -a "$ENV_FILE" "$ENV_FILE.bak-$STAMP"
chmod 600 "$ENV_FILE.bak-$STAMP"
ok "saved $ENV_FILE.bak-$STAMP  (old target: $OLD_REPO)"

say "Updating .env"
TMP="$(mktemp)"; chmod 600 "$TMP"
# Drop any previous S3/B2 lines so re-running cannot leave stale credentials.
grep -vE '^(RESTIC_REPOSITORY|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_DEFAULT_REGION|B2_ACCOUNT_ID|B2_ACCOUNT_KEY)=' \
  "$ENV_FILE" > "$TMP"
{
  echo ""
  echo "# --- Cloudflare R2 (configured $(date -Is)) ---"
  echo "RESTIC_REPOSITORY=$NEW_REPO"
  echo "AWS_ACCESS_KEY_ID=$R2_KEY_ID"
  echo "AWS_SECRET_ACCESS_KEY=$R2_SECRET"
  echo "AWS_DEFAULT_REGION=auto"
} >> "$TMP"
mv "$TMP" "$ENV_FILE"
chmod 600 "$ENV_FILE"
[ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$ENV_FILE"
ok ".env now points at R2"

say "Running a real backup"
"$REPO_ROOT/scripts/backup.sh" || die "backup failed; your old .env is at $ENV_FILE.bak-$STAMP"

say "Proving it restores"
"$REPO_ROOT/scripts/restore-test.sh" || die "RESTORE TEST FAILED - do not trust this target yet"

say "Usage"
restic stats --mode raw-data 2>/dev/null | sed 's/^/  /' || true

cat <<EOF

============================================================
  DONE - backups now go to Cloudflare R2, and a restore has
  been proven to work.
============================================================

Old local repository: $OLD_REPO
  Still on disk, still valid, still encrypted under the same password.
  Keep it as a fast local restore path, or delete it once you trust R2.

Free tier is 10 GB. Check usage any time with:
  cd $REPO_ROOT && set -a && source .env && set +a && restic stats --mode raw-data

REMINDER: your restic password is unchanged, and it is still the one thing
that must exist in a password manager OFF this machine. R2 stores only
ciphertext -- Cloudflare cannot recover your data, and neither can anyone else,
including you, without that password.
EOF
