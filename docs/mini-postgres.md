# Mac mini Postgres — a maintained instance

The `postgres` service in `compose.dev.yml` (`postgres:18`, bound to `127.0.0.1:5432`, volume
`postgres-dev-data`) used to be a throwaway mirror of prod. Since P0b of agent-workflows it is a
**maintained instance**: it holds `agent_workflows`' system of record (run records, journal), so it
has roles and schemas, a nightly off-box backup, a restore drill, an upgrade path and a heartbeat.
Dev only: none of this runs on the VPS, which has its own cron backups (`scripts/backup-pg.sh`).

| Concern | Target / file |
|-|-|
| Roles, schemas, `agent_workflows` DB | `make postgres-setup ENV=dev` → `scripts/setup-postgres.sh` |
| `shared` database, writer roles, `argo_agw_ro` | `make db-shared` → `scripts/setup-shared-db.sh` |
| Nightly backup | `launchd/com.jkrumm.vps-pg-backup.plist.template` → `scripts/backup-pg-dev.sh` (`make dev-pg-backup`) |
| Restore drill | `make dev-pg-restore-drill` → `scripts/restore-drill-pg-dev.sh` |
| Upgrade | `make dev-pg-upgrade` → `scripts/upgrade-pg-dev.sh` |
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

No credential is involved: `pg_dump` runs inside the container over its unix socket and the upload
is keyless Tailscale SSH.

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

`make dev-pg-upgrade` — backup first (aborts if it fails), `pull`, recreate, wait healthy, probe.

- **Minor / patch** (`postgres:18` floats across 18.x): the above is all there is.
- **Major (e.g. 18 → 19):** refused by the target, because the new image cannot start on the old
  data directory. Procedure, with the old volume kept until the new one is proven:
  1. `make dev-pg-backup` and `make dev-pg-restore-drill` — a drilled backup in hand.
  2. Stop dependents (agent-workflows), then `make down` for the postgres service.
  3. In `compose.dev.yml` change the image tag **and** the volume name (e.g. `postgres-dev-data-19`,
     declared under `volumes:`). The old `postgres-dev-data` volume stays untouched as the rollback.
  4. `make up`, `make postgres-setup ENV=dev` (recreates roles, `agent_workflows` DB).
  5. Restore: roles first (`psql -f globals.sql` — "already exists" errors for roles that
     `postgres-setup` just recreated are expected), then for each database
     `pg_restore --no-owner -d <db>` into the empty database `postgres-setup` created
     (`createdb` first for any other, e.g. the shared `${POSTGRES_DB}` when it is not `postgres`).
  6. `make dev-pg-health`, `make db-counts` vs `counts.tsv`, then a fresh `make dev-pg-backup`.
  7. Remove the old volume only after a week of green nightly backups.

## Heartbeat

`scripts/health-pg-dev.sh` prints one line and exits 0/1: container running+healthy, `SELECT 1`
over the socket, `127.0.0.1:5432` accepting connections, `agent_workflows` present and owned by
its own role. It pushes nothing itself. The mini's readiness heartbeat is
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
- **weatherorb's Postgres.** Homebrew's `postgresql@18` on `127.0.0.1:5433` (databases `weatherorb`,
  `weatherorb_dbos`, test DBs; PostGIS 3.6, `shared_buffers=4GB`, loopback `trust`) is owned by the
  weatherorb repo and deliberately left alone: this instance is `postgres:18` without PostGIS, and
  the workload is a 7 GB live write path. Decided 2026-10-27 to leave it as is. If it moves, it moves
  as a weatherorb change, most likely into its own container (e.g. `postgres-weatherorb` on a
  PostGIS image, same backup/drill/upgrade scripts parameterised by container) rather than by
  swapping this instance's image. Do not `brew services stop postgresql@18` — weatherorb and
  the Athena cluster's binaries depend on it.
