# Disaster Recovery — restoring a PRODUCTION database from S3

> Restoring prod **overwrites the live database**. This is a last-resort
> operation. There is **no `make` target** for it on purpose. Read this whole
> page before you touch anything.

## What is allowed (and what isn't)

| Operation | How | Guarded? |
|-|-|-|
| Backup prod → S3 | `make backup` / `make fpp-backup` (+ nightly cron) | no — safe |
| Local ← prod (db→db) | `make pg-sync-schema SCHEMA=…`, `make fpp-sync-from-prod` | dev-only, never touches prod |
| Local ← S3 | `make restore-local`, `make fpp-restore-local` | dev-only, never touches prod |
| Verify counts | `make db-counts` | read-only, both envs |
| **Prod ← S3 (restore)** | **scripts below — no make target** | **heavily gated** |

Nothing else writes to prod. The dev syncs always replace the **whole schema**
(Postgres, `pg-sync-schema`) or the whole MariaDB database — there is no partial/table-level
operation to reason about. The whole-DB Postgres sync was retired: the mini's Postgres is a
maintained instance (`docs/mini-postgres.md`).

## The guard on the prod-restore scripts

`scripts/restore-pg.sh` and `apps/fpp/scripts/restore-mariadb.sh` refuse to run
unless every gate passes:

1. **No passwordless sudo.** If `sudo` needs no password (the VPS runs NOPASSWD
   sudo), the script aborts. This blocks accidental runs on the server.
2. **Real sudo password.** It runs `sudo -v`, forcing a human to authenticate.
3. **Type the exact database name.** A final typed confirmation.

Because of gate 1, the normal path is blocked on the VPS. For a genuine
on-server recovery (the prod DB physically lives on the VPS), set
`BREAK_GLASS=1` to bypass gate 1 — you still face gates 2 and 3.

## Recovery procedure

### 1. Pick the backup version

```bash
# Postgres
op run --env-file=.env.tpl -- \
  aws s3 ls "s3://$AWS_S3_BUCKET/backups/vps/postgres/" --endpoint-url "$AWS_S3_ENDPOINT"
# MariaDB
op run --env-file=.env.tpl -- \
  aws s3 ls "s3://$AWS_S3_BUCKET/backups/vps/mariadb/" --endpoint-url "$AWS_S3_ENDPOINT"
```

Validate the chosen dump **first** without touching prod — restore it locally and
confirm the row counts are sane:

```bash
BACKUP_FILE=postgres_<db>_YYYYMMDD_HHMMSS.dump make restore-local   # dev box
make db-counts                                                      # exact COUNT(*) per table
```

### 2. Restore prod (on the VPS, deliberate)

Postgres, in this order:

```bash
ssh vps
cd ~/vps
# a. Roles first. They are cluster-level: they survive the drop, but a fresh
#    cluster has none, and the restore needs every schema-owning role to exist.
make postgres-setup
# b. Restore. Drops (--force, disconnects clients) and recreates the database,
#    and restores ownership (no --no-owner), so each app role owns its schema,
#    tables and migration journal. GRANTs are not taken from the dump.
BREAK_GLASS=1 BACKUP_FILE=postgres_<db>_YYYYMMDD_HHMMSS.dump \
  op run --env-file=.env.tpl -- ./scripts/restore-pg.sh
# c. Grants again. The drop wiped database-level grants (CONNECT, CREATE);
#    postgres-setup is idempotent and re-applies them and the schema grants.
make postgres-setup
```

MariaDB (interactive filename prompt), then its grants:

```bash
BREAK_GLASS=1 op run --env-file=.env.tpl -- ./apps/fpp/scripts/restore-mariadb.sh
make fpp-mariadb-setup
```

Answer the sudo prompt and type the database name when asked.

### 3. Verify

```bash
make shell-postgres        # spot-check rows per schema
make fpp-shell             # spot-check fpp tables
```

Check Postgres ownership: every app schema, and its tables, owned by the app
role (none by the superuser):

```sql
SELECT n.nspname, pg_get_userbyid(n.nspowner) AS owner FROM pg_namespace n
 WHERE n.nspname NOT LIKE 'pg\_%' AND n.nspname <> 'information_schema' ORDER BY 1;
SELECT schemaname, tableowner, count(*) FROM pg_tables
 WHERE schemaname NOT IN ('pg_catalog','information_schema') GROUP BY 1,2 ORDER BY 1;
```

If a schema or its tables show the wrong owner (a restore taken with the old
`--no-owner` behaviour), fix per schema as superuser:
`REASSIGN OWNED BY <superuser> TO <app>` is too broad, so use
`ALTER SCHEMA <app> OWNER TO <app>` plus `ALTER TABLE <app>.<t> OWNER TO <app>`
per table, then `make postgres-setup`.

## Postgres major-version upgrade

Same restore mechanism: `make backup`, bump the image tag in
`compose.infra.yml`, then restore into the new container via the gated
`scripts/restore-pg.sh` (or `pg_upgrade` in place). Always test on a copy first.
