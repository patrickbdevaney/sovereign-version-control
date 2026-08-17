# Sovereign Version Control

A self-hosted [Forgejo](https://forgejo.org) git forge that is reachable from
your home LAN and your [Tailscale](https://tailscale.com) tailnet — and from
nowhere else. No port forwarding, no Funnel, no public exposure of any kind.

Infrastructure-as-code only. This repository contains no data, no secrets, and
no machine-specific values.

---

## Threat model

What this setup does and does not defend against, stated plainly so you can
decide whether it matches your needs.

| Threat | Covered? | How |
|---|---|---|
| Internet-based attackers | Yes | Nothing is listening on a public address. No port forward, no Funnel. |
| Untrusted devices on your LAN | Partly | Ports are restricted to the LAN subnet, but any device on that subnet can reach the web UI over plain HTTP. |
| Passive network snooping on LAN | **No** | The LAN path is HTTP. See "HTTPS trade-off" below. |
| Compromised router or switch | **No** | A hostile gateway can read the LAN HTTP path. Use the tailnet URL if this concerns you. |
| Accidental deletion, bad upgrade, DB corruption | Yes | Nightly restic snapshots with 14/8/12 retention. |
| Disk failure, theft, fire | **Only with an offsite target** | A restic repository on the same machine dies with the machine. See "Backups". |
| Secrets leaking into this public repo | Yes | Three-layer pre-commit guard, see "Secret hygiene". |

## HTTPS trade-off — read this

Tailscale issues real certificates only for your `*.ts.net` tailnet hostname.
It cannot issue one for a private LAN IP, because no public CA will sign a
name nobody can verify ownership of.

So the two paths differ:

- **Tailnet path** — `https://<your-machine>.<your-tailnet>.ts.net` — real TLS,
  encrypted end to end. Works at home *and* away.
- **LAN path** — `http://192.168.x.x:3000` — **plain HTTP, unencrypted.**

Plain HTTP on the LAN is a deliberate choice, not an oversight. The traffic
never leaves your local network, and a compromised router is a different threat
model. But it does mean anyone with a foothold on your LAN can read your
session cookie in transit.

If that is not acceptable, you have two options, neither of which is set up
here: a self-signed certificate (browser warnings, must be trusted on every
device), or a local reverse proxy with an internal CA. **Or simply use the
tailnet URL exclusively** — it works at home too, and is the simplest way to
get encryption on every path.

---

## Layout

```
docker-compose.yml     Forgejo + Postgres, ports bound to explicit host IPs
.env.example           template; copy to .env (chmod 600, gitignored)
.gitleaks.toml         secret-scanning rules, incl. ones gitleaks lacks
.githooks/pre-commit   three-layer secret guard
scripts/
  bootstrap.sh         install packages, create data dirs outside this repo
  gen-secrets.sh       generate SECRET_KEY / INTERNAL_TOKEN
  firewall.sh          ufw + DOCKER-USER rules (LAN + tailscale0 only)
  tailscale-serve.sh   HTTPS on the tailnet; refuses to run if Funnel is on
  backup.sh            pg_dump + restic, encrypted client-side
  restore-test.sh      proves a backup actually restores
  healthcheck.sh       containers, HTTP, backup freshness, disk, still-private
  alert.sh             failure notifier (log + desktop + wall)
  install-systemd.sh   install timers, substituting the real repo path
systemd/               timer units, with __REPO_ROOT__ placeholders
```

**Forgejo's data never lives here.** It is at `/var/lib/forgejo/{data,db}`,
outside this repository, so that no `git add` can capture repository contents
or the database. This is enforced by `bootstrap.sh`, which refuses to run if any
data path resolves inside the repo.

## Install

```bash
cp .env.example .env && chmod 600 .env
$EDITOR .env                        # set LAN_IP, TS_IP, LAN_SUBNET, domains

sudo ./scripts/bootstrap.sh         # docker, restic, data dirs
sudo ./scripts/gen-secrets.sh       # SECRET_KEY + INTERNAL_TOKEN
sudo ./scripts/firewall.sh          # dry run first — review the output
sudo ./scripts/firewall.sh --apply
docker compose up -d
sudo ./scripts/tailscale-serve.sh   # HTTPS on the tailnet
sudo ./scripts/install-systemd.sh   # nightly backup + hourly health
```

Then create the admin account (the web installer is disabled on purpose — an
open installer reachable on your LAN is a real exposure window):

```bash
docker compose exec -u git server forgejo admin user create \
  --admin --username <you> --email <you@example.com> --random-password
```

Sign in and immediately enable 2FA under *Settings → Security*.

## Networking

Every published port binds to an explicit host IP from `.env`, never `0.0.0.0`:

| Service | Bind | Reachable from |
|---|---|---|
| Web UI | `${LAN_IP}:3000` | LAN subnet; tailnet via `tailscale serve` |
| Git SSH | `${LAN_IP}:2222` and `${TS_IP}:2222` | LAN subnet and tailnet |
| Postgres | *not published* | Forgejo container only |

Postgres sits on an `internal: true` Docker network: no host exposure, no
route to the internet.

### Docker bypasses ufw — why `firewall.sh` touches DOCKER-USER

Docker writes its own DNAT and FORWARD rules, evaluated *before* ufw's INPUT
chain. A `ufw deny 3000` does **not** block a Docker-published port. Guides that
stop at `ufw allow from <subnet>` leave you exposed while looking secure.

Two things actually constrain reachability here: binding each port to a specific
host IP, and the `DOCKER-USER` chain rules that `firewall.sh` installs. Those
raw rules do not survive a reboot on their own, so the script also persists them
via `iptables-persistent`.

## Backups

`backup.sh` captures the three things that have no other copy:

1. `/var/lib/forgejo/data` — repositories, LFS, attachments
2. A `pg_dump` of the database — **not** the raw PGDATA directory, which would
   be a torn and possibly unrestorable copy of a running database
3. `.env` — `SECRET_KEY` decrypts stored 2FA secrets; without it a restore
   leaves those permanently unreadable

The dump is validated with `pg_restore --list` before it is backed up. A
truncated dump that still exits 0 is the classic way to discover your backups
were worthless only when you needed them.

This repository is deliberately **not** backed up: it lives in git and already
has another copy.

Retention: `--keep-daily 14 --keep-weekly 8 --keep-monthly 12`.

### The repository password

restic encrypts client-side, so the storage target never sees plaintext. The
cost of that guarantee is absolute:

> **If `RESTIC_PASSWORD` exists only on this machine, and this machine dies,
> every backup is permanently unrecoverable.** There is no reset and no
> recovery. Store it in a password manager, today.

### Verifying

A backup that has never been restored is a hypothesis, not a backup.

```bash
sudo ./scripts/restore-test.sh
```

This restores the latest snapshot to a scratch directory, runs `git fsck` on
every restored repository, loads the dump into a throwaway Postgres container,
and queries it. It cleans up after itself and never touches the live instance.

`forgejo-verify.timer` additionally runs `restic check --read-data-subset=10%`
weekly, which re-reads and re-hashes actual pack data to catch silent
corruption. Plain `restic check` only validates structure.

## Secret hygiene

`.gitignore` alone is not protection: it stops an accidental `git add`, but not
`git add -f`, and it does nothing about a secret already written into a tracked
file. The `.githooks/pre-commit` hook adds three layers:

1. **Filename blocklist** — refuses `.env`, `*.key`, `*.pem`, `app.ini`, dumps
2. **gitleaks** — the default ruleset plus local rules for shapes it misses
   (a Postgres URL with an inline password is *not* flagged by stock gitleaks)
3. **Local-value scan** — refuses to commit your real LAN IP, Tailscale IP, LAN
   subnet, or tailnet hostname, read from the gitignored `.env` so the real
   values appear in no tracked file, including the hook and the gitleaks config

The hook fails closed: if gitleaks is missing, the commit is rejected rather
than silently allowed.

Note that gitleaks uses RE2, which has **no lookahead support**. Exclusions
belong in an allowlist; a `(?!...)` in a rule regex makes gitleaks panic at
config load, and a crash can read as a pass.

## Daily use from a laptop

The tailnet hostname resolves both at home and away, so there is one URL to
remember and one remote to configure. You do not need a VPN toggle or a
different address depending on where you are.

### One-time laptop setup

Add your SSH public key at **Settings → SSH / GPG Keys** in the web UI, then
tell SSH which port to use so you never have to type it again:

```sshconfig
# ~/.ssh/config
Host forge
    HostName <your-machine>.<your-tailnet>.ts.net
    User git
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
```

Verify:

```bash
ssh -T forge          # expect a Forgejo greeting, not a shell
```

### Starting a new project locally, then pushing to your forge

```bash
mkdir myproject && cd myproject
git init -b main
# ... write code ...
git add -A && git commit -m "Initial commit"

# Create the repo on the forge first (web UI: + -> New Repository),
# then point this working copy at it:
git remote add origin forge:<org-or-user>/myproject.git
git push -u origin main
```

`-u` sets the upstream, so afterwards plain `git push` and `git pull` work.

### Cloning something that already exists there

```bash
git clone forge:<org>/<repo>.git
```

### Using both this forge and GitHub from one working copy

Useful when the forge is the private source of truth and GitHub holds a public
subset. Keep them as separate named remotes and push deliberately:

```bash
git remote add origin forge:<org>/<repo>.git      # private, authoritative
git remote add github git@github.com:<you>/<repo>.git

git push origin main      # to your own forge
git push github main      # to GitHub, only when you mean to
```

Never make GitHub the default upstream for a private repo. `git push` with no
argument should always go somewhere you control.

### Does a laptop commit end up in the backup?

Only once it reaches the forge. The chain is:

```
laptop working copy  --git push-->  Forgejo (/var/lib/forgejo/data)
                                        |
                              nightly 02:30, restic, encrypted here
                                        v
                                 backup repository
```

An unpushed local commit is not backed up by anything. Push before you care
about losing it.

## Moving backups to Cloudflare R2 (or any S3 target)

The backup location is a single `.env` variable, so switching costs three
lines and no script changes.

1. Cloudflare dashboard → **R2** → create a bucket (keep it **private**).
2. **Manage R2 API Tokens** → create a token scoped to *that bucket only*,
   with **Object Read & Write**. Note the Access Key ID, Secret Access Key,
   and your Account ID.
3. Edit `.env`:

```bash
RESTIC_REPOSITORY=s3:https://<account_id>.r2.cloudflarestorage.com/<bucket>
AWS_ACCESS_KEY_ID=<access_key_id>
AWS_SECRET_ACCESS_KEY=<secret_access_key>
AWS_DEFAULT_REGION=auto
```

`AWS_DEFAULT_REGION=auto` is **required**. R2 has no meaningful region, but
omitting it produces confusing SigV4 signing errors rather than a clear
message.

4. Initialise and verify:

```bash
set -a; source .env; set +a
restic init                       # new repository at the new location
sudo ./scripts/backup.sh          # first upload
sudo ./scripts/restore-test.sh    # prove it restores BEFORE trusting it
```

Keep the **same** `RESTIC_PASSWORD` if you want one password for both, or
generate a new one — but then store *both*, since the old local repository
stays encrypted under the old password.

The free tier is 10 GB. `restic stats --mode raw-data` reports actual usage,
and `healthcheck.sh` warns at the `RESTIC_WARN_BYTES` threshold so you get
notice before a nightly run starts failing. What blows past 10 GB is binary
content — Git LFS assets, committed `node_modules`, large PDFs — not source.

Note that a remote target replaces the local one. To keep both, run
`backup.sh` twice with different `RESTIC_REPOSITORY` values, or keep the local
repository as the fast restore path and the remote as disaster recovery.

## Restoring onto a new machine

1. Install Docker and restic; clone this repository.
2. Recreate `.env`. You need `RESTIC_REPOSITORY` and `RESTIC_PASSWORD` — from
   your password manager. Nothing else gets you in.
3. `restic snapshots` to list, then `restic restore <id> --target /`.
4. Restore the database:
   ```bash
   docker compose up -d db
   docker compose exec -T db pg_restore -U forgejo -d forgejo --clean --no-owner \
     < /var/lib/forgejo/dump/forgejo-db.dump
   ```
5. `docker compose up -d`, re-run `firewall.sh --apply` and
   `tailscale-serve.sh`. The new host will have a different tailnet name unless
   you reuse the machine name — update `.env` accordingly.

## License

MIT
