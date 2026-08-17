#!/usr/bin/env bash
# Create the initial admin account.
#
#   sudo ./scripts/create-admin.sh <username> <email>
#
# The web installer is disabled on purpose (INSTALL_LOCK=true in the compose
# file): an unlocked Forgejo installer reachable on your LAN lets anyone who
# can reach it configure the instance, which is a real exposure window between
# first start and first login. The admin account is therefore created here.
#
# The generated password is written to a root-only file rather than printed, so
# it does not end up in terminal scrollback, shell history, or CI logs.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo $0" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USERNAME="${1:-}"
EMAIL="${2:-}"
PW_FILE=/root/forgejo-admin-initial-password.txt

if [ -z "$USERNAME" ] || [ -z "$EMAIL" ]; then
  echo "usage: sudo $0 <username> <email>" >&2
  exit 2
fi

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
DC=(docker compose --project-directory "$REPO_ROOT")

say "Checking the instance is up"
"${DC[@]}" exec -T server true 2>/dev/null \
  || { echo "forgejo container is not running; start it with 'docker compose up -d'" >&2; exit 1; }

if "${DC[@]}" exec -u git -T server forgejo admin user list 2>/dev/null \
     | awk 'NR>1 {print $2}' | grep -qx "$USERNAME"; then
  echo "user '$USERNAME' already exists; nothing to do."
  echo "To reset the password instead:"
  echo "  docker compose exec -u git -T server forgejo admin user change-password \\"
  echo "    --username $USERNAME --password 'NEW_PASSWORD'"
  exit 0
fi

say "Creating admin '$USERNAME'"
umask 077
PASSWORD="$(openssl rand -base64 24 | tr -d '\n/+=')"
printf '%s\n' "$PASSWORD" > "$PW_FILE"
chmod 600 "$PW_FILE"

"${DC[@]}" exec -u git -T server forgejo admin user create \
  --admin --username "$USERNAME" --email "$EMAIL" \
  --password "$PASSWORD" --must-change-password >/dev/null
unset PASSWORD

cat <<EOF

Admin '$USERNAME' created.

  password:  $PW_FILE  (mode 600, not printed here)
  read it:   sudo cat $PW_FILE

You must change it at first login (--must-change-password is set).

Next, and do not skip this:
  1. Sign in and enable 2FA under Settings -> Security.
     TOTP works without a mail server; no mailer is configured, so there is
     no email-based password reset. Recovery is the CLI command above, which
     requires shell access to this machine.
  2. Save the 2FA recovery codes somewhere OFF this machine, or 2FA becomes
     its own lockout risk.
EOF
