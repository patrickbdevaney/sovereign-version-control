#!/usr/bin/env bash
# Produce a printable recovery sheet: everything needed to rebuild this forge
# from backups on a machine that no longer exists.
#
#   sudo ./scripts/recovery-sheet.sh            # write ./recovery-sheet.txt
#   sudo ./scripts/recovery-sheet.sh --stdout   # print instead (careful)
#
# WHY THIS EXISTS
# ---------------
# The restic password lives in .env, on the machine being backed up. That is
# not a second copy: the failure that destroys the forge destroys the only key
# to its backups at the same time. A password manager fixes that, and so does
# paper -- paper does not depend on a vendor, a subscription, a master password
# you might also lose, or a device that boots.
#
# Print this. Put it somewhere physical. Then delete the file.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo $0" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "$REPO_ROOT/.env"; set +a

OUT="$REPO_ROOT/recovery-sheet.txt"
TO_STDOUT=0
[ "${1:-}" = "--stdout" ] && TO_STDOUT=1

ADMIN_PW="(not found)"
[ -f /root/forgejo-admin-initial-password.txt ] \
  && ADMIN_PW="$(cat /root/forgejo-admin-initial-password.txt)"

render() {
cat <<EOF
================================================================================
  FORGEJO RECOVERY SHEET                       generated $(date -Is)
  machine: $(hostname)
================================================================================

  THIS PAGE IS A CREDENTIAL. Treat it like a passport, not a printout.
  Anyone holding it can read every backup you have ever taken.

--------------------------------------------------------------------------------
 1. THE ONE THAT CANNOT BE REGENERATED
--------------------------------------------------------------------------------

  restic repository password:

      ${RESTIC_PASSWORD}

  Backup repository:

      ${RESTIC_REPOSITORY}

  Without this password the backups are mathematically unrecoverable. There is
  no reset, no support channel, no vendor who can help. Every other secret on
  this sheet can be regenerated; this one cannot.

--------------------------------------------------------------------------------
 2. STORAGE ACCESS (regenerable — reissue in the provider's dashboard)
--------------------------------------------------------------------------------

  Access key id:      ${AWS_ACCESS_KEY_ID:-${B2_ACCOUNT_ID:-n/a}}
  Secret access key:  ${AWS_SECRET_ACCESS_KEY:-${B2_ACCOUNT_KEY:-n/a}}
  Region:             ${AWS_DEFAULT_REGION:-n/a}

  If these leak, revoke and reissue them. The backups stay safe: the storage
  provider only ever holds ciphertext, and these keys do not decrypt it.

--------------------------------------------------------------------------------
 3. FORGE ACCESS (regenerable via shell on the machine)
--------------------------------------------------------------------------------

  Web (tailnet):  ${FORGEJO_ROOT_URL}
  Web (LAN):      http://${LAN_IP}:3000/
  Git over SSH:   ssh://git@${FORGEJO_SSH_DOMAIN}:${FORGEJO_SSH_PORT}/<owner>/<repo>.git

  Admin user:     patrickd
  Admin password: ${ADMIN_PW}

  No mail server is configured, so there is no email password reset. Recovery is:
      docker compose exec -u git -T server forgejo admin user change-password \\
        --username patrickd --password 'NEW'

--------------------------------------------------------------------------------
 4. REBUILDING FROM NOTHING
--------------------------------------------------------------------------------

  1. New machine: install docker + restic, then
       git clone https://github.com/patrickbdevaney/sovereign-version-control.git
       cd sovereign-version-control
       cp .env.example .env && chmod 600 .env

  2. Put section 1 and 2 of this sheet into .env:
       RESTIC_REPOSITORY, RESTIC_PASSWORD, and the storage keys.

  3. Confirm you can see the backups:
       set -a; source .env; set +a
       restic snapshots

  4. Restore everything:
       sudo restic restore latest --target /

  5. Bring it up and reload the database:
       sudo ./scripts/bootstrap.sh
       docker compose up -d db
       docker compose exec -T db pg_restore -U forgejo -d forgejo --clean \\
         --no-owner < /var/lib/forgejo/dump/forgejo-db.dump
       docker compose up -d

  6. Re-establish the network paths (values will differ on new hardware):
       sudo ./scripts/firewall.sh --apply
       sudo ./scripts/tailscale-serve.sh

  Full detail: README.md in the repository above.

--------------------------------------------------------------------------------
 WHERE TO PUT THIS PAGE
--------------------------------------------------------------------------------

  Anywhere that is NOT this machine. Two copies in two places beats one:

    [ ] printed, in a drawer / safe / with important documents
    [ ] a password manager entry (Bitwarden, 1Password, KeePassXC)
    [ ] a second physical location, if the code matters that much

  A copy on the laptop is better than nothing, but if both devices live in the
  same house, fire and theft take both. Paper elsewhere survives that.

  After printing:  shred -u recovery-sheet.txt

================================================================================
EOF
}

if [ "$TO_STDOUT" -eq 1 ]; then
  render
else
  umask 077
  render > "$OUT"
  chmod 600 "$OUT"
  [ -n "${SUDO_USER:-}" ] && chown "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$OUT"
  echo "Wrote $OUT (mode 600)."
  echo
  echo "  Print it:   lp $OUT       (or open it and print)"
  echo "  Read it:    less $OUT"
  echo "  Then:       shred -u $OUT"
  echo
  echo "It contains the restic password in the clear, which is the point --"
  echo "it is useless as a recovery document otherwise. Do not leave it on disk."
fi
