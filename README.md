# Sovereign Version Control

A self-hosted [Forgejo](https://forgejo.org) git forge that is reachable from
your home LAN and your [Tailscale](https://tailscale.com) tailnet — and from
nowhere else. No port forwarding, no Funnel, no public exposure of any kind.

Infrastructure-as-code only. This repository contains no data, no secrets, and
no machine-specific values.

## The whole system

Three parts. This repository is the middle one.

```
  ┌─────────────────────────────────────────────────────────────┐
  │  CLIENT — your laptop                                       │
  │  working copy, plaintext                                    │
  │  forge-setup / forge-new / forge-clone / forge-doctor       │
  └────────────────────────┬────────────────────────────────────┘
                           │  git push over SSH :2222
                           │  (tailnet anywhere, or LAN at home)
                           ▼
  ┌─────────────────────────────────────────────────────────────┐
  │  FORGE — this repository                                    │
  │  Forgejo + Postgres, /var/lib/forgejo, plaintext at rest    │
  │  LAN 192.168.x.x:3000 (HTTP) + tailnet HTTPS (real cert)    │
  │  private by default; no port forward, no Funnel             │
  └────────────────────────┬────────────────────────────────────┘
                           │  hourly; restic ENCRYPTS HERE
                           ▼
  ┌─────────────────────────────────────────────────────────────┐
  │  BACKUP — Cloudflare R2 / Backblaze B2 / local disk         │
  │  ciphertext only; provider cannot read it                   │
  │  restore proven by scripts/restore-test.sh, not assumed     │
  └─────────────────────────────────────────────────────────────┘
```

The client tooling lives in a separate repository:
**[sovereign-version-control-client](https://github.com/patrickbdevaney/sovereign-version-control-client)**
— `forge-setup` (key + SSH alias + register), `forge-new` (the `gh repo create`
equivalent), `forge-clone`, and `forge-doctor` (checks every link in the chain).
Its defaults match this server: SSH port 2222, user `git`, API over the tailnet
HTTPS name, and a LAN fallback probe against `:3000/api/healthz`.

Both halves accept `owner/name`, so repository layout is your choice rather
than a consequence of tooling limits:

```bash
forge-new myproject          # -> <you>/myproject      (user namespace)
forge-new ip/myproject       # -> ip/myproject         (organisation)
forge-clone ip/monorepo      # organisations clone the same way
```

**A commit is only protected once it is pushed.** An unpushed local commit
exists on exactly one disk and no backup covers it.

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
| Accidental deletion, bad upgrade, DB corruption | Yes | Hourly restic snapshots, 48h of hourly granularity then 14/8/12. |
| Disk failure, theft, fire | **Only with an offsite target** | A restic repository on the same machine dies with the machine. See "Backups". |
| Secrets leaking into this public repo | Yes | Three-layer pre-commit guard, see "Secret hygiene". |
| **Physical theft of the forge machine** | **No** | The disk is not encrypted. Whoever holds the drive reads every repository, and `.env` — which contains the backup password. See "Where your code lives". |

## Where your code lives, and what is actually encrypted

Three copies exist. Only one of them is encrypted, and knowing which matters.

| Copy | State at rest | How you read it |
|---|---|---|
| Laptop working copy | **Plaintext** | Open the files |
| Forge, `/var/lib/forgejo` | **Plaintext** | Web UI, `git clone`, or straight off the disk |
| Backup repository (R2/B2/local) | **Ciphertext** | `restic restore`, with `RESTIC_PASSWORD` |

**Compression is not encryption.** Git objects are zlib-compressed, which makes
them unreadable in a text editor and perfectly readable to `git`. Nothing on
the forge is encrypted at rest.

Only the backup is genuinely encrypted, because restic encrypts *before* upload.
That is the whole reason an untrusted storage provider is acceptable: Cloudflare
or Backblaze holds ciphertext and cannot read a byte of it.

### The consequence: physical access

The forge machine's disk is **not** encrypted in this setup. File permissions
(`root:root`, mode 0750) stop other users on a running system. They stop nobody
holding the drive.

If the machine is stolen, the thief gets every repository, its full history,
and `.env` — which contains the restic password, so the backups come with it.

This is a normal trade-off for an always-on home server, and it is stated here
rather than hidden. If the hosted code is valuable enough to matter, the fix is
full-disk encryption (LUKS), with the caveat that an encrypted root needs a
passphrase at every boot — which fights with "always-on and headless". A middle
path is encrypting only `/var/lib/forgejo` and unlocking it manually after a
reboot.

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
  create-admin.sh      create the admin account (web installer is disabled)
  firewall.sh          ufw + DOCKER-USER rules (LAN + tailscale0 only)
  tailscale-serve.sh   HTTPS on the tailnet; refuses to run if Funnel is on
  docker-user-rules.sh reapplies DOCKER-USER rules (docker flushes them)
  backup.sh            pg_dump + restic, encrypted client-side
  restore-test.sh      proves a backup actually restores
  setup-r2.sh          guided migration of backups to Cloudflare R2
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
sudo ./scripts/install-systemd.sh   # hourly backup + health, weekly verify
```

Then create the admin account. The web installer is disabled on purpose
(`INSTALL_LOCK=true`) — an unlocked installer reachable on your LAN lets anyone
who can reach it configure the instance:

```bash
sudo ./scripts/create-admin.sh <you> <you@example.com>
```

The generated password goes to `/root/forgejo-admin-initial-password.txt`
(mode 600) rather than to your terminal, so it stays out of scrollback and
shell history.

Sign in and immediately enable 2FA under *Settings → Security*. No mailer is
configured, so there is **no email password reset** — recovery is
`forgejo admin user change-password`, which needs shell access to the machine.
Save your 2FA recovery codes somewhere off this machine.

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
host IP, and the `DOCKER-USER` chain rules that `firewall.sh` installs.

Those raw rules do not survive on their own — and Docker **flushes DOCKER-USER
every time the daemon starts**, so they must be *reapplied*, not merely saved.
That is what `forgejo-docker-firewall.service` (ordered `After=docker.service`)
does.

> **Do not reach for `iptables-persistent` here.** On Ubuntu 25.10 that package
> conflicts with ufw, and apt resolves the conflict by **removing ufw** — which
> silently leaves the host with `INPUT ACCEPT` and no inbound filtering at all,
> while appearing to have just improved your firewall. This was hit during the
> original build.

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

### Schedule and retention

Backups run **hourly**, not nightly. A nightly-only schedule leaves up to ~24
hours of pushed work with no offsite copy. restic deduplicates, so a run with
nothing new uploads almost nothing — an idle hourly run is a handful of API
calls, far inside R2's free tier of 1M class-A operations per month.

Retention: `--keep-hourly 48 --keep-daily 14 --keep-weekly 8 --keep-monthly 12`.

**`--keep-hourly` is not optional here, and leaving it out is a silent trap.**
`restic forget` keeps only the *last* snapshot of each day to satisfy
`--keep-daily`. Pair an hourly schedule with a daily-only policy and every run
discards the previous hour: you get freshness but lose the ability to roll back
to earlier the same day — exactly what you need after an accidental deletion or
a bad force-push. Check any policy with `restic forget --dry-run`, which prints
what it would keep and why.

For the same reason `backup.sh` runs `forget` **without** `--prune`. Prune
repacks the repository and is the expensive half; under an hourly schedule it
would run every hour. It happens on the weekly `forgejo-verify` timer instead.
Forgotten snapshots stop being visible immediately; prune is only what reclaims
their space.

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

### API token scopes

Anything that creates repositories goes through the API and therefore needs a
token, created at **Settings → Applications → Generate New Token**. Which
scopes you need depends on where repositories live:

| Scope | Needed for |
|---|---|
| `write:user` | reading your account, registering SSH keys |
| `write:repository` | creating repositories in your own namespace |
| `write:organization` | **creating repositories inside an organisation** |

The third one is the trap. A token carrying only the first two authenticates
perfectly well and then fails *only* on organisation creation:

```
POST /orgs/<org>/repos  ->  403
{"message":"token does not have at least one of required scope(s): [write:organization]"}
```

That reads like an authentication problem and is not one — the token is valid,
it simply lacks that scope. Tokens cannot be edited after creation, so add the
scope up front or regenerate.

**Git-over-SSH needs no scope at all.** Cloning, pulling and pushing to an
organisation repository work with nothing but a registered SSH key; only the
API create path is scope-gated. If pushes work but creating a repo fails, this
is why.

Store the token mode 600 — the client tooling checks and warns otherwise:

```bash
install -d -m 700 ~/.config/forge
printf '%s' 'YOUR_TOKEN' > ~/.config/forge/token
chmod 600 ~/.config/forge/token
```

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

### Push-to-create

`git push` to a repository that does not exist yet creates it, for both user
and organisation namespaces. New repositories are private by default.

```bash
git remote add origin forge:<you>/brand-new-thing.git
git push -u origin main          # the repo is created by the push
```

This needs no API token and no scopes — git-over-SSH is not scope-gated.

Note that all three settings are required together:
`ENABLE_PUSH_CREATE_USER`, `ENABLE_PUSH_CREATE_ORG`, and
`DEFAULT_PUSH_CREATE_PRIVATE`. The privacy setting on its own is **inert**,
because the two enable flags default to false — a configuration that looks
deliberate and silently does nothing.

The trade-off is that a typo in a remote URL creates a repository instead of
failing. If you prefer the strictness, set both `ENABLE_PUSH_CREATE_*` to
`"false"` and create repositories explicitly with `forge-new`.

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
                        hourly, restic encrypts BEFORE upload
                                        v
                                 backup repository
```

An unpushed local commit is not backed up by anything. Push before you care
about losing it.

## Moving backups to Cloudflare R2 (or any S3 target)

The backup location is a single `.env` variable, so switching costs three
lines and no script changes.

The guided way (recommended) — asks for the bucket name, then lets you paste
Cloudflare's credentials block verbatim and extracts the rest:

```bash
sudo ./scripts/setup-r2.sh
```

It validates the credentials before changing anything, keeps a timestamped
`.env` backup, and refuses to report success until a real restore test passes.

> **Your Account ID is not your email address.** It is a 32-character hex
> string (e.g. `8f4b…4c7d`), visible in the dashboard URL and on the R2
> overview page. It is also embedded in the endpoint URL Cloudflare shows you,
> which is why pasting the whole block is enough. Using an email here produces
> a DNS failure that does not obviously point at the cause.

### Doing it by hand instead

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
notice before a scheduled run starts failing. What blows past 10 GB is binary
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
