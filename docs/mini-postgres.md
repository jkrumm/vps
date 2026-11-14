# Mac mini Postgres — a maintained instance

## Which server

The mini has **one** Postgres: the Homebrew `postgresql@18` server on `127.0.0.1:5432` (unix socket
`/tmp/.s.PGSQL.5432`), run as the OS user, who is its superuser under local `trust` — no credential.
Its roles, databases, grants and settings are declared in
`~/SourceRoot/dotfiles/config/postgres/cluster.yaml` and applied with
`make -C ~/SourceRoot/dotfiles pg-apply` (`docs/postgres.md` there); **nothing in this repo provisions
it**. The backup, restore drill, health probe, `make db-counts`, `restore-local`, `pg-sync-schema` and
`shell-postgres` / `sql-postgres` talk to it through Homebrew's client binaries
(`/opt/homebrew/opt/postgresql@18/bin`) over the socket `/tmp:5432` (`scripts/lib-pg-dev.sh`;
`PG_DEV_BIN`, `PG_DEV_SOCKDIR`, `PG_DEV_PORT` override the defaults).

Until 2026-11-14 the mini ran a second instance, the `postgres` container of `compose.dev.yml`
(`postgres:18`). The cutover (dotfiles) moved its databases to the bare server and stopped it; the
service is gone from `compose.dev.yml`. Its volume `vps_postgres-dev-data` is kept as the rollback
copy until dotfiles removes it (7 days after the cutover, after a proven HomeLab restore). Never
`docker compose down -v` the dev stack, and never `docker volume rm` it from here.

Dev only: none of this runs on the VPS, which has its own cron backups (`scripts/backup-pg.sh`) and
its own `postgres` container.

| Concern | Target / file |
|-|-|
| Roles, databases (`agent_workflows`, `shared`, …), schemas, grants, settings | dotfiles `config/postgres/cluster.yaml`, `make -C ~/SourceRoot/dotfiles pg-apply` |
| Nightly backup | `launchd/com.jkrumm.vps-pg-backup.plist.template` → `scripts/backup-pg-dev.sh` (`make dev-pg-backup`) |
| Restore drill | `make dev-pg-restore-drill` → `scripts/restore-drill-pg-dev.sh` |
| Prod data per schema | `make pg-sync-schema SCHEMA=<app>` → `scripts/sync-pg-schema-from-vps.sh` |
| Prod DR drill (S3 → local) | `make restore-local` → `scripts/restore-pg-local.sh` |
| Counts, shell | `make db-counts`, `make shell-postgres`, `make sql-postgres` (`DB=<name>`, default `postgres`) |
| Upgrade | Homebrew's, below ("Upgrades") |
| Heartbeat probe | `make dev-pg-health` → `scripts/health-pg-dev.sh` |

## Databases

All declared in `cluster.yaml`; this repo only reads or backs them up.

- **`agent_workflows`** — agent-workflows' system of record (run records, journal), owned by the login
  role of the same name (`LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE`). A database of its own, so
  `restore-local` (which replaces schemas of `${POSTGRES_DB}`) and schema syncs can never touch it.
  `argo_agw_ro` is Argo's read-only role on it (`CONNECT`, `USAGE` on schemas, `SELECT` on tables and
  sequences, default privileges for what the app creates later; connection limit 5).
- **`shared`** — one login role per writer (`usage`, `factory`, `argo`), each owning its own schema
  (role name = schema name) with its own connection limit, `search_path` set to it; `argo` reads
  `usage`. `CONNECT` is closed to `PUBLIC`. A connection limit is per role, cluster-wide.
- **`postgres`** — the maintenance database and the prod mirror: the schemas `argo`, `umami`,
  `basalt_ui_playground`, `drizzle` (and the mini-only `modelpick`), written by `restore-local` and
  `pg-sync-schema`.
- `weatherorb`, `weatherorb_dbos`, `athena`, `spike_s1` — other tenants of the same server.

A new role, database or writer is a change to `cluster.yaml` plus `pg-apply`; a password ref reaches the
mini through `dotfiles-private/headless.refs` and `make secrets-seed` before any template line uses it
(`secrets-run` fails closed on an unsealed ref). A mirrored schema that `pg-sync-schema` should
refresh also needs its `<SCHEMA>_DB_PASSWORD` line in `.env.dev.tpl`.

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

No credential is involved: Homebrew's `pg_dump` runs over the server's unix socket as the OS user and
the upload is keyless Tailscale SSH.
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

### Size, time and retention

Measured 2026-11-14 against the server before the other databases moved in (weatherorb 10 GB, weatherorb_dbos 0.8 GB, the test
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
`PG_DEV_SOCKDIR=<dir> PG_DEV_PORT=<port> make dev-pg-restore-drill`.

| Date | Backup | Where restored | Result |
|-|-|-|-|
| 2026-11-14 | `20261114T103340Z` of the bare server, pulled from `homelab:/mnt/hdd/backups/vps-mini-postgres` layout (probe directory, deleted afterwards) | scratch cluster, PostgreSQL 18.7 | pass: `postgres` 0 tables / 0 rows, `weatherorb_accounts_test` 15 / 4, `weatherorb_dbos` 13 / 383 989, `weatherorb` 43 / 38 631 246 — every row count and relation-kind count equal to `counts.tsv`; fetch 16 min, restore+count 5 min |

This record predates the cutover (the backup was taken while the bare server held weatherorb only).
Every nightly run repeats the drill on its own backup; the first nightly after the cutover is the
proof for the full database set — check `~/Library/Logs/vps-pg-backup.log` for
`DRILL PASS: ... 7 database(s)` (`shared`, `agent_workflows`, `weatherorb`, `weatherorb_dbos`, `athena`,
`postgres`, `spike_s1`).

### Lock-table sizing

`max_locks_per_transaction` is `1024` in `cluster.yaml` (the Postgres default of 64 gave 64 × 100 =
6 400 slots). It is a postmaster setting, so a change applies only after the server restarts (dotfiles'
`pg-apply` reports it; the owner restarts the service).

Why: the backup's snapshot holder runs the exact-`COUNT(*)` SQL for every table in one `REPEATABLE READ`
transaction, and `count(*)` also locks each table's indexes while planning, so it holds a lock on
(nearly) every table and index of the database until the dump finishes. `pg_dump` then locks every
table too. `agent_workflows` has one `agw_t_*` schema per tenant (8 tables, ~35 indexes each) and grows
daily; the plain default failed the nightly backup with `out of shared memory` / `HINT: You might need to
increase "max_locks_per_transaction"` from 2026-10-31.

Sizing (2026-11-01, `agent_workflows`: 422 tenant schemas, 3 346 tables, 14 528 indexes ≈ 17.9k
slots for the holder + 3.4k for `pg_dump` ≈ 21.3k): 1024 × 100 = 102 400 slots, ~4.8× headroom for a
few MB of shared memory. Re-measure (run `make sql-postgres DB=agent_workflows` and paste):

```sql
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

`scripts/health-pg-dev.sh` prints one line and exits 0/1: `SELECT 1` over the socket, `127.0.0.1:5432` accepting connections,
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
- `make restore-local` (the S3 DR drill) stays MacBook-only. It drops and restores the schemas the
  dump carries inside `${POSTGRES_DB}`; the database itself and every other database stay.
- The `postgres-dev-data` volume is never removed or recreated by any target here.
- Do not `brew services stop postgresql@18`: weatherorb, Athena and everything above depend on it.
