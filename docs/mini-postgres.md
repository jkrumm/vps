# Mac mini Postgres — a maintained instance

## Which server

The mini ends up with **one** Postgres: the Homebrew `postgresql@18` server on `127.0.0.1:5432`
(unix socket `/tmp/.s.PGSQL.5432`), run as the OS user, who is its superuser under local `trust` — no
credential. Its roles, databases, grants and settings are declared in
`~/SourceRoot/dotfiles/config/postgres/cluster.yaml` and applied with
`make -C ~/SourceRoot/dotfiles pg-apply` (`docs/postgres.md` there); **nothing in this repo provisions
it**. Until the cutover is done the `postgres` container of `compose.dev.yml` is still the dev
instance described below, and the bare server (weatherorb's databases) runs beside it.

The backup, restore drill and health probe do not care which of the two is live. Each run decides
(`scripts/lib-pg-dev.sh`): the container `postgres` while it runs, else the bare server through
Homebrew's client binaries (`/opt/homebrew/opt/postgresql@18/bin`) over the socket `/tmp:5432`.
`PG_DEV_TARGET=container|bare` forces one (`PG_DEV_BIN`, `PG_DEV_SOCKDIR`, `PG_DEV_PORT` override the
bare defaults). Output layout, snapshot-consistent counts and verify-by-restore are identical for both.
The sections below that talk about the container (provisioning, lock-table sizing, shared memory)
describe the instance as it was until the cutover.

The `postgres` service in `compose.dev.yml` (`postgres:18`, bound to `127.0.0.1:5432`, volume
`postgres-dev-data`) used to be a throwaway mirror of prod. Since P0b of agent-workflows it is a
**maintained instance**: it holds `agent_workflows`' system of record (run records, journal), so it
has roles and schemas, a nightly off-box backup, a restore drill, an upgrade path and a heartbeat.
Dev only: none of this runs on the VPS, which has its own cron backups (`scripts/backup-pg.sh`).

| Concern | Target / file |
|-|-|
| Roles, schemas, `agent_workflows` DB | container: `make postgres-setup ENV=dev`; bare server: dotfiles `cluster.yaml` |
| `shared` database, writer roles, `argo_agw_ro` | container: `make db-shared`; bare server: dotfiles `cluster.yaml` |
| Nightly backup | `launchd/com.jkrumm.vps-pg-backup.plist.template` → `scripts/backup-pg-dev.sh` (`make dev-pg-backup`) |
| Restore drill | `make dev-pg-restore-drill` → `scripts/restore-drill-pg-dev.sh` |
| Upgrade | the container is gone after the cutover; the bare server is Homebrew's (below, "Upgrades") |
| Heartbeat probe | `make dev-pg-health` → `scripts/health-pg-dev.sh` |

## `agent_workflows`

A separate **database** (not a schema in `${POSTGRES_DB}`), owned by a login role of the same name:
`LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE`, `CONNECT` revoked from `PUBLIC` on its own database
(it keeps PUBLIC's default `CONNECT` on the others but holds no schema privileges there). The app connects to
`127.0.0.1:5432` as that role and never uses the superuser. Being its own database means
`restore-local` (which replaces `${POSTGRES_DB}`) and schema syncs can never touch it.

Its password is `AGENT_WORKFLOWS_DB_PASSWORD` = `op://mini/vps-dev/AGENT_WORKFLOWS_DB_PASSWORD`, a
dev-only credential in the mini vault. Until the role is activated (below) `setup-postgres.sh`
skips its block, and the database and role that already exist keep whatever password they have.

### Activating the agent_workflows role

Order matters: `secrets-seed` aborts the whole reseal on a ref it cannot resolve, and
`secrets-run` fails closed on a `.env.dev.tpl` ref missing from the cache (every dev target reads
that file). So each step must be done before the next:

1. The 1Password field `op://mini/vps-dev/AGENT_WORKFLOWS_DB_PASSWORD` exists (MacBook; generate a
   random value).
2. The ref is added to `dotfiles-private/headless.refs` and pushed.
3. `make secrets-seed` (MacBook; seals the cache and delivers it to the mini). Check on the mini:
   `secrets-run read op://mini/vps-dev/AGENT_WORKFLOWS_DB_PASSWORD`.
4. The line `AGENT_WORKFLOWS_DB_PASSWORD=op://mini/vps-dev/AGENT_WORKFLOWS_DB_PASSWORD` is added to
   `.env.dev.tpl` (in the `agent_workflows` section) and merged.
5. `make postgres-setup ENV=dev` on the mini: sets the role's password to the real value.

Done on 2026-10-27: field created, ref sealed, line added, role converged to the real password
(verified by a TCP login with the cached value).

## `shared`

A second **database** next to `agent_workflows` (which stays its own database): one login role per
writer, each **owning its own schema** (role name = schema name) and every object it creates there,
each with its **own connection limit**. Provisioned by `make db-shared` (`scripts/setup-shared-db.sh`,
idempotent, ends with assertions that fail the run on any miss).

| Role / schema | Limit | Password env | Source |
|-|-|-|-|
| `usage` | 10 | `SHARED_USAGE_DB_PASSWORD` | `op://mini/vps-dev/SHARED_USAGE_DB_PASSWORD` |
| `argo` | 20 | `ARGO_DB_PASSWORD` | `op://vps/argo/DB_PASSWORD` (the existing argo role, reused; `setup-postgres.sh` created it for the main database) |

- The database is owned by the superuser; `CONNECT` is revoked from `PUBLIC` and granted to the
  writers only, and `PUBLIC` has no privileges on schema `public`. Roles are `LOGIN NOSUPERUSER
  NOCREATEDB NOCREATEROLE`, each with `search_path` set to its own schema, and cannot see each other's
  schemas.
- A connection limit is **per role, cluster-wide**: `argo` also connects to the main database, so its
  20 are shared between that and `shared`.
- **Read grants (the only cross-schema access):** `argo` reads `usage` (`USAGE` on the schema, `SELECT`
  on all tables, plus default privileges for tables `usage` creates later). Argo is the reader of usage
  data, not a write API.
- **CREATE on the database:** the roles in `DB_CREATE_WRITERS` (`argo`) hold `CREATE` on `shared`. Their migrator
  (drizzle) runs `CREATE SCHEMA IF NOT EXISTS <own schema>`, which Postgres checks against the database
  privilege before it looks at `IF NOT EXISTS`. The script asserts the statement passes.
- **Adding a writer** (e.g. `factory`): one row in `WRITERS` at the top of `setup-shared-db.sh`
  (`role|limit|password env`), a `SHARED_READS` row if it needs to read another schema, the password
  line in `.env.dev.tpl` (after the activation order below), then `make db-shared`. A row whose
  password env is unset is skipped with a message, so a machine without it never fails.
- **Activation order** for each new secret is exactly the one under "Activating the agent_workflows
  role" (1Password field, `headless.refs`, `make secrets-seed`, check with `secrets-run read`, only
  then the `.env.dev.tpl` line, then `make db-shared`). Adding the template line first makes every dev
  target fail closed.
- The nightly backup already covers `shared` (it dumps every non-template database, with counts and the
  in-run restore drill). While `shared` has no relations at all, `counts.tsv` has no `shared` rows
  (`pg-counts.sql` emits per-kind counts only for kinds that exist) and the drill compares 0 = 0; the
  rows appear with the first table.

### `argo_agw_ro`

Read-only role for Argo on the `agent_workflows` database (`ARGO_AGW_RO_DB_PASSWORD` =
`op://mini/vps-dev/ARGO_AGW_RO_DB_PASSWORD`, connection limit 5): `CONNECT` on that database,
`USAGE` on every non-system schema, `SELECT` on all tables and sequences, plus `ALTER DEFAULT
PRIVILEGES FOR ROLE <database owner>` (looked up, currently `agent_workflows`) for schemas, tables and
sequences, so what the app creates later (it creates and drops schemas at runtime) stays readable
without re-running the target. Deliberately **not** `pg_read_all_data` (cluster-wide). It cannot write,
create tables or schemas, or connect to `shared`.

### How the assertions log in

Over TCP `127.0.0.1:5432` from the **host** `psql` with `PGPASSWORD` in the process environment, never
argv. A login from inside the container would match the image's loopback `trust` rule in `pg_hba.conf`
and never check the password; the host connection arrives from the Docker gateway and takes the
`scram-sha-256` rule.

## Backup

Daily 03:15 by `com.jkrumm.vps-pg-backup` (a LaunchAgent, like every other mini job; install with
`make dev-pg-launchd` **from the main checkout** — the plist hard-codes the checkout path, the target
refuses a linked worktree, detected with `git rev-parse --git-dir` vs `--git-common-dir`). It runs through `jobrun`, so a failed run or a missed night grades `failing` /
`stale` in `jobs-grade` and reaches Slack #alerts via the devhost heartbeat; there is no log to watch.

One backup is a directory `<UTC timestamp>/` under `homelab:/mnt/hdd/backups/vps-mini-postgres/`
(`PG_DEV_BACKUP_DEST`): `globals.sql` (roles, password verifiers — directory is mode 700),
`<database>.dump` for every non-template database, `counts.tsv`, `SHA256SUMS`. It is uploaded as
`<name>.incomplete` and renamed only after `sha256sum -c` passes on the HomeLab, so the newest
directory is always complete. **Retention: newest 14** (`PG_DEV_BACKUP_KEEP`, minimum 3), pruned at
the end of every successful run together with `.incomplete` leftovers older than a day.

Every run ends with the restore drill on the backup it just wrote (`PG_DEV_BACKUP_VERIFY=0` turns it
off), before retention prunes anything. This is not paranoia: during development a backup of a
database mid-migration produced an archive with a valid checksum and a broken `CREATE FUNCTION`
(`pg_dump`'s `pg_get_*def` calls ignore the dump snapshot, so concurrent DDL can corrupt a
definition); only the restore showed it. A failed verify fails the job, which `jobs-grade` reports.

No credential is involved: `pg_dump` runs over the server's unix socket (inside the container, or
Homebrew's `pg_dump` as the OS user on the bare server) and the upload is keyless Tailscale SSH.
Scratch databases of a drill running at the same moment (`restore_drill_<ts>_<n>`) are never dumped.

On a fully green run (upload, drill and retention) the script ends with an Uptime Kuma push (`up`, backup
name + database count) via `dotfiles/scripts/lib/kuma-push.sh`. The push URL is read from the chmod-600
file `~/.config/uptime-kuma/pg-backup-push-url`, deliberately not from the secrets cache (same rule as
the devhost and drift heartbeats). Without the file the script logs one line and skips the push; a
failing push never fails the backup. The `jobrun` record stays the primary failure signal.

`counts.tsv` is the drill's reference: exact `COUNT(*)` per table plus counts of
tables/indexes/sequences/views (so an empty database is verifiable too), taken **inside the snapshot
the dump reads**. A background `psql` holds a `REPEATABLE READ` transaction open, exports its
snapshot, runs `scripts/pg-counts.sql`, and stays open until `pg_dump --snapshot=<id>` finishes; the
manifest therefore describes the dump exactly, whatever writes concurrently.

### Size, time and retention on the bare server

Measured 2026-11-14 against the bare server (weatherorb 10 GB, weatherorb_dbos 0.8 GB, the test
database, `postgres`): the backup holds **1.2 GB** (`weatherorb` dumps to ~1.2 GB at `--compress=6`);
the exact counts of all four databases take seconds, the dumps 2 min 40 s, the upload to the HomeLab
7.5 min. The container's four databases (`agent_workflows`, `postgres`, `shared`, `spike_s1`) were
322 MB and uploaded in 8.7 min — the upload is bound by the HomeLab link (~1 MB/s for either size),
not by the size. The verify drill restores from the **staged copy** (the upload already passed
`sha256sum -c` on the HomeLab; a second pull took 10–16 min), which costs ~5 min for `weatherorb`
and ~3 min for `agent_workflows` (14 000 tables).

Expected nightly with everything in the bare server (weatherorb + `agent_workflows` + `shared` +
`athena` + `spike_s1`): dump ~7 min, upload ~10 min, drill ~10 min, ~30 min against `jobrun
--timeout 3600`. A run that approaches 45 min is the signal to look at the link, not to raise the
timeout. Retention is 14 backups: ~17 GB at 1.2 GB each, on a 14 TB HomeLab disk that is 34 % used;
restic covers the path from there. The snapshot holder keeps one `REPEATABLE READ` transaction open
per database for the duration of its dump (~3 min for `weatherorb`), which holds back vacuum cleanup
of that database for that long.

### Restore from the HomeLab copy — proof record

The drill restores into scratch databases `restore_drill_<ts>_<n>` and never over a live database.
To prove a restore without touching the live server at all, point it at a scratch cluster:
`initdb` into a temp dir, start it on its own socket, then
`PG_DEV_TARGET=bare PG_DEV_SOCKDIR=<dir> PG_DEV_PORT=<port> make dev-pg-restore-drill`.

| Date | Backup | Where restored | Result |
|-|-|-|-|
| 2026-11-14 | `20261114T103340Z` of the bare server, pulled from `homelab:/mnt/hdd/backups/vps-mini-postgres` layout (probe directory, deleted afterwards) | scratch cluster, PostgreSQL 18.7 | pass: `postgres` 0 tables / 0 rows, `weatherorb_accounts_test` 15 / 4, `weatherorb_dbos` 13 / 383 989, `weatherorb` 43 / 38 631 246 — every row count and relation-kind count equal to `counts.tsv`; fetch 16 min, restore+count 5 min |

This record predates the cutover (the backup was taken while the bare server held weatherorb only).
Every nightly run repeats the drill on its own backup; the first nightly after the cutover is the
proof for the full database set — check `~/Library/Logs/vps-pg-backup.log` for
`DRILL PASS: ... 7 database(s)` (`shared`, `agent_workflows`, `weatherorb`, `weatherorb_dbos`, `athena`,
`postgres`, `spike_s1`).

### Lock-table sizing

On the bare server the setting belongs to `cluster.yaml` (dotfiles) — the backup's error names it. The
numbers below were measured on the container; the rule is the same.

`max_locks_per_transaction` is `1024` (compose `command:`; the Postgres default of 64 gave 64 × 100 =
6 400 slots). It is a postmaster setting, so it applies only after the postgres container is recreated.

Why: the backup's snapshot holder runs the exact-`COUNT(*)` SQL for every table in one `REPEATABLE READ`
transaction, and `count(*)` also locks each table's indexes while planning, so it holds a lock on
(nearly) every table and index of the database until the dump finishes. `pg_dump` then locks every
table too. `agent_workflows` has one `agw_t_*` schema per tenant (8 tables, ~35 indexes each) and grows
daily; the plain default failed the nightly backup with `out of shared memory` / `HINT: You might need to
increase "max_locks_per_transaction"` from 2026-10-31.

Sizing (2026-11-01, `agent_workflows`: 422 tenant schemas, 3 346 tables, 14 528 indexes ≈ 17.9k
slots for the holder + 3.4k for `pg_dump` ≈ 21.3k): 1024 × 100 = 102 400 slots, ~4.8× headroom for a
few MB of shared memory. Re-measure (run `make sql-postgres` and paste):

```sql
\c agent_workflows
SELECT relkind, count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE relkind IN ('r', 'i') AND nspname NOT IN ('pg_catalog', 'information_schema') GROUP BY 1;
```

Keep `tables + indexes + tables` under half of `max_locks_per_transaction × max_connections`.

If it recurs, the script fails with the database's relation count and the current settings and names this
setting, instead of the bare psql error.

## Restore drill

`make dev-pg-restore-drill` (`BACKUP=<name>` for an older one): fetch the newest complete backup,
verify checksums, restore every dump into a scratch database `restore_drill_<ts>_<n>` with
`pg_restore --exit-on-error`, require the restored table set, relation counts and every row count to
match `counts.tsv` exactly, drop the scratch databases, exit non-zero on any mismatch. At the start
it removes leftovers of crashed runs and nothing else: databases named exactly
`restore_drill_<14 digits>_<n>` older than two hours (a drill that is running right now, e.g. the
verify step of a backup, is younger), and `pg-dev-drill.*` / `pg-dev-backup.*` directories older than
two hours in `TMPDIR`. Run it after any change to the backup script and at least monthly.

## Upgrades

The container image upgrade path (`make dev-pg-upgrade`) is retired with the container. The bare
server is Homebrew's `postgresql@18`: a minor/patch bump is `brew upgrade` through dotfiles; a major
bump is a dump/restore or `pg_upgrade` and is documented in dotfiles `docs/postgres.md`. Before either:
`make dev-pg-backup` and `make dev-pg-restore-drill` — a drilled backup in hand. Do not
`brew services stop postgresql@18`: weatherorb and Athena run on it.

## Heartbeat

`scripts/health-pg-dev.sh` prints one line and exits 0/1: container running+healthy (only while the
container is the live server), `SELECT 1` over the socket, `127.0.0.1:5432` accepting connections,
`agent_workflows` present and owned by its own role. It pushes nothing itself. The mini's readiness heartbeat is
`dotfiles/scripts/devhost-health-check.sh` (`DEVHOST_SERVICES`, a push to the `MacMini Dev Host`
monitor); the Postgres component is one entry there:

```
postgres|$HOME/Library/LaunchAgents/com.jkrumm.vps-pg-backup.plist|probe_postgres
```

```bash
probe_postgres() {
  local out
  out=$("$HOME/SourceRoot/vps/scripts/health-pg-dev.sh" 2>&1) || { echo "${out:-postgres probe failed}"; return 1; }
}
```

The gate path means a machine without the backup LaunchAgent skips the probe.

## Not on this instance

- Prod data arrives per schema only (`make pg-sync-schema SCHEMA=<app>`). The whole-DB
  `sync-from-prod` was retired: it dropped the entire local database.
- `make restore-local` (the S3 DR drill) stays MacBook-only and replaces `${POSTGRES_DB}` only.
- The `postgres-dev-data` volume is never removed or recreated by any target here.
- **weatherorb's Postgres is this server now.** The Homebrew `postgresql@18` (weatherorb databases,
  PostGIS 3.6) is the one Postgres of the mini after the cutover. Do not
  `brew services stop postgresql@18`: weatherorb and the Athena cluster depend on it.

## Shared memory

Parallel query workers allocate their segments in the container's `/dev/shm`. Docker's default of 64 MB is too small for a
dashboard's burst of aggregates: queries fail with `could not resize shared memory segment ... No space left on device`.
`shm_size: 1g` in `compose.dev.yml` sets it when the container is created, so it needs a recreate of the container; a
plain restart keeps the old size, and a live `mount -o remount` is refused. tmpfs only uses what is allocated. Check it with
`docker inspect postgres --format '{{.HostConfig.ShmSize}}'`.
