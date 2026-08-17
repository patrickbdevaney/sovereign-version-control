#!/usr/bin/env bash
# Install prerequisites and create the on-disk layout for Forgejo.
#
# Idempotent: safe to re-run. Creates NOTHING inside this repo — all real data
# lives under /var/lib/forgejo so that no `git add` here can ever capture
# repository contents or the database.
#
#   sudo ./scripts/bootstrap.sh
#
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "must run as root: sudo $0" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The unprivileged account that owns the repo and will join the docker group.
TARGET_USER="${SUDO_USER:-$(stat -c %U "$REPO_ROOT")}"

DATA_DIR=/var/lib/forgejo/data
DB_DIR=/var/lib/forgejo/db
DUMP_DIR=/var/lib/forgejo/dump
BACKUP_DIR=/var/backups/forgejo

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

say "Installing packages"
export DEBIAN_FRONTEND=noninteractive

PKGS=(docker.io docker-compose-v2 docker-buildx restic curl ca-certificates)

# A broken THIRD-PARTY repo (a PPA with no release for this Ubuntu version, say)
# makes `apt-get update` exit non-zero even though the Ubuntu archive itself is
# fine. Rather than ignore update failures wholesale -- which would hide a real
# problem -- fail only if the packages we actually need are unavailable.
if ! apt-get update -qq 2>/tmp/aptupd.err; then
  echo "  apt-get update reported errors:"
  sed 's/^/    /' /tmp/aptupd.err
  MISSING=()
  for p in "${PKGS[@]}"; do
    cand="$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')"
    [ -z "$cand" ] || [ "$cand" = "(none)" ] && MISSING+=("$p")
  done
  if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "FATAL: these packages have no install candidate: ${MISSING[*]}" >&2
    echo "Fix the apt sources above and re-run." >&2
    exit 1
  fi
  echo "  -> the failing repo is unrelated to this build; every required"
  echo "     package resolves from the Ubuntu archive. Continuing."
fi

# Ubuntu archive packages are current (docker 29.x, compose v2 2.40.x,
# restic 0.18.x), so no third-party apt repo or GPG key is needed here.
apt-get install -y -qq "${PKGS[@]}"

say "Enabling docker"
systemctl enable --now docker

if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
  say "Adding $TARGET_USER to the docker group"
  usermod -aG docker "$TARGET_USER"
  echo "NOTE: $TARGET_USER must log out and back in for group membership to apply."
fi

say "Creating data directories outside the repo"
# Forgejo container runs as uid/gid 1000.
install -d -o 1000 -g 1000 -m 0750 "$DATA_DIR"
install -d -o 1000 -g 1000 -m 0700 "$DUMP_DIR"
# Postgres' entrypoint chowns PGDATA itself on first start; root-owned 0700 is
# the correct starting state.
install -d -o root -g root -m 0700 "$DB_DIR"
# restic repo + restore scratch. Root-only: the repo is encrypted, but the
# fewer processes that can read it the better.
install -d -o root -g root -m 0700 "$BACKUP_DIR"
install -d -o root -g root -m 0700 "$BACKUP_DIR/restic"

say "Verifying nothing points back into the repo"
for d in "$DATA_DIR" "$DB_DIR" "$DUMP_DIR" "$BACKUP_DIR"; do
  case "$(readlink -f "$d")" in
    "$REPO_ROOT"/*|"$REPO_ROOT")
      echo "FATAL: $d resolves inside the repo ($REPO_ROOT). Refusing." >&2
      exit 1 ;;
  esac
  printf '  ok  %-28s -> %s\n' "$d" "$(readlink -f "$d")"
done

say "Versions"
docker --version
docker compose version --short 2>/dev/null | sed 's/^/compose /'
restic version | head -1

say "Bootstrap complete"
cat <<EOF

Next:
  1. sudo ./scripts/gen-secrets.sh     # fill SECRET_KEY / INTERNAL_TOKEN
  2. sudo ./scripts/firewall.sh        # LAN + tailscale0 only, deny by default
  3. docker compose up -d
  4. sudo ./scripts/tailscale-serve.sh
EOF
