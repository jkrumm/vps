#!/usr/bin/env bash
# =============================================================================
# Local Postgres restore from S3 — non-interactive, dev-only.
#
# Pulls the latest (or named) whole-DB backup from S3 and restores its schemas into
# ${POSTGRES_DB} of the Postgres of the machine it runs on (the Homebrew server on the unix
# socket /tmp:5432 as the OS user, scripts/lib-pg-dev.sh; the database must already exist). Used to:
#   - Validate the prod backup chain is replayable (DR drill from a clean Mac)
#   - Seed local dev with a full prod mirror (all schemas at once)
#
# WARNING: drops every schema the dump carries (umami, argo, basalt_ui_playground, …,
# CASCADE) from ${POSTGRES_DB} and restores them from the dump. The database itself
# is never dropped — it is the server's maintenance database, declared in dotfiles
# config/postgres/cluster.yaml — and schemas the dump does not carry (modelpick) and every
# other database (agent_workflows, shared, athena, weatherorb, …) are untouched.
# For a single app's schema only, use sync-pg-schema-from-vps.sh instead.
#
# Roles, database, schema ownership and default privileges are the cluster's
# (`make -C ~/SourceRoot/dotfiles pg-apply`). A dropped schema takes its default
# privileges with it, so the script re-grants the schema's same-named role (the
# convention: role == schema) after the restore.
#
# For fresh-from-prod data (no S3 round trip), use sync-pg-schema-from-vps.sh
# (`make pg-sync-schema SCHEMA=<app>`).
# Prod restore (interactive, drops prod DB) is restore-pg.sh.
#
# Usage:  make restore-local
#         BACKUP_FILE=postgres_..._YYYYMMDD_HHMMSS.dump make restore-local
#         RESTORE_DB=<scratch db> make restore-local     # a database other than ${POSTGRES_DB}
#
# Required env (resolved by op run --env-file=.env.tpl):
#   POSTGRES_DB
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_S3_BUCKET, AWS_S3_ENDPOINT
# =============================================================================
set -euo pipefail

BACKUP_PREFIX="backups/vps/postgres"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-pg-dev.sh
source "${HERE}/lib-pg-dev.sh"

log() { echo "[$(date +%H:%M:%S)] $*"; }

: "${POSTGRES_DB:?must be set (run via make restore-local)}"
DB="${RESTORE_DB:-${POSTGRES_DB}}"
[[ "${DB}" =~ ^[a-z_][a-z0-9_]*$ ]] || { echo "ERROR: database '${DB}' is not a plain lower-case identifier"; exit 1; }

pg_select_target || exit 1
[[ "$(pg_exec psql -d postgres -Atc "SELECT count(*) FROM pg_database WHERE datname = '${DB}'")" == "1" ]] || {
  echo "ERROR: database '${DB}' does not exist on the $(pg_target_label) — declare it in dotfiles config/postgres/cluster.yaml, then make -C ~/SourceRoot/dotfiles pg-apply"
  exit 1
}

if [[ -n "${BACKUP_FILE:-}" ]]; then
  FILE="${BACKUP_FILE}"
else
  log "Resolving latest backup in s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/ ..."
  FILE=$(aws s3 ls "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/" \
      --endpoint-url "${AWS_S3_ENDPOINT}" \
    | awk '{print $4}' \
    | grep -E "^postgres_${POSTGRES_DB}_[0-9]+_[0-9]+\.dump$" \
    | sort -r | head -1)
  [[ -z "${FILE}" ]] && { echo "ERROR: no matching backup found."; exit 1; }
fi
log "Using: ${FILE}"

WORK=$(mktemp -d /tmp/pg_restore_local_XXXXXX)
trap 'rm -rf "${WORK}"' EXIT
TMP="${WORK}/backup.dump"

log "Downloading ${FILE} from S3..."
aws s3 cp "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${FILE}" "${TMP}" \
  --endpoint-url "${AWS_S3_ENDPOINT}" >/dev/null

# The dump's table of contents: its schemas (all but public, which is the database's own) and a
# list that skips what exists anyway (public, plpgsql) so pg_restore --exit-on-error stays strict.
pg_exec pg_restore -l "${TMP}" > "${WORK}/toc.all"
SCHEMAS=$(awk '$4 == "SCHEMA" && $6 != "public" { print $6 }' "${WORK}/toc.all")
grep -v -E ' (SCHEMA - public|EXTENSION - plpgsql|COMMENT - (SCHEMA public|EXTENSION plpgsql)) ' "${WORK}/toc.all" > "${WORK}/toc.restore"
[[ -n "${SCHEMAS}" ]] || { echo "ERROR: the dump carries no schemas — refusing to restore nothing"; exit 1; }
for s in ${SCHEMAS}; do
  [[ "${s}" =~ ^[a-z_][a-z0-9_]*$ ]] || { echo "ERROR: unexpected schema name '${s}' in the dump"; exit 1; }
done

log "Dropping the dump's schemas from ${DB}: ${SCHEMAS//$'\n'/ }"
for s in ${SCHEMAS}; do
  pg_exec_i psql -d "${DB}" -qX -v ON_ERROR_STOP=1 -v s="${s}" <<'SQL'
DROP SCHEMA IF EXISTS :"s" CASCADE;
SQL
done

log "Restoring ${FILE} → ${DB} on the $(pg_target_label)..."
pg_exec pg_restore -d "${DB}" -L "${WORK}/toc.restore" --no-owner --no-privileges --exit-on-error "${TMP}"

log "Re-granting each schema's same-named role (default privileges went with the dropped schema)..."
for s in ${SCHEMAS}; do
  [[ "$(pg_exec psql -d "${DB}" -Atc "SELECT count(*) FROM pg_roles WHERE rolname = '${s}'")" == "1" ]] || continue
  pg_exec_i psql -d "${DB}" -qX -v ON_ERROR_STOP=1 -v s="${s}" <<'SQL'
SELECT current_user AS su \gset
GRANT USAGE, CREATE ON SCHEMA :"s" TO :"s";
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA :"s" TO :"s";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA :"s" TO :"s";
ALTER DEFAULT PRIVILEGES FOR ROLE :"su" IN SCHEMA :"s" GRANT ALL ON TABLES TO :"s";
ALTER DEFAULT PRIVILEGES FOR ROLE :"su" IN SCHEMA :"s" GRANT ALL ON SEQUENCES TO :"s";
SQL
done

log "Restore complete. Schema summary:"
pg_exec psql -d "${DB}" -P pager=off -c \
  "SELECT schemaname, count(*) AS tables, COALESCE(sum(n_live_tup),0) AS approx_rows
     FROM pg_stat_user_tables GROUP BY schemaname ORDER BY schemaname;"
