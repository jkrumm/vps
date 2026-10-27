#!/usr/bin/env bash
# =============================================================================
# Local Postgres restore from S3 — non-interactive, dev-only.
#
# Pulls the latest (or named) whole-DB backup from S3 and restores it into the
# local `postgres` container started by compose.dev.yml. Used to:
#   - Validate the prod backup chain is replayable (DR drill from a clean Mac)
#   - Seed local dev with a full prod mirror (all schemas at once)
#
# WARNING: drops and recreates the entire local ${POSTGRES_DB} — every local
# schema (public, umami, argo, basalt_ui_playground, …) is replaced. For a
# single app's schema only, use sync-pg-schema-from-vps.sh instead.
#
# For fresh-from-prod data (no S3 round trip), use sync-pg-schema-from-vps.sh
# (`make pg-sync-schema SCHEMA=<app>`). The whole-DB sync was retired: the mini's
# Postgres is a maintained instance. This script replaces ${POSTGRES_DB} only —
# the separate agent_workflows database (and any other database) is untouched.
# Prod restore (interactive, drops prod DB) is restore-pg.sh.
#
# Usage:  make restore-local
#         BACKUP_FILE=postgres_..._YYYYMMDD_HHMMSS.dump make restore-local
#
# Required env (resolved by op run --env-file=.env.tpl):
#   POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_S3_BUCKET, AWS_S3_ENDPOINT
# =============================================================================
set -euo pipefail

BACKUP_PREFIX="backups/vps/postgres"

log() { echo "[$(date +%H:%M:%S)] $*"; }

docker inspect -f '{{.State.Status}}' postgres >/dev/null 2>&1 || {
  echo "ERROR: local 'postgres' container not running. Run 'make up' first."; exit 1;
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

TMP=$(mktemp /tmp/pg_restore_local_XXXXXX.dump)
trap 'rm -f "${TMP}"' EXIT

log "Downloading ${FILE} from S3..."
aws s3 cp "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${FILE}" "${TMP}" \
  --endpoint-url "${AWS_S3_ENDPOINT}" >/dev/null

log "Dropping and recreating local database ${POSTGRES_DB}..."
docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres \
  dropdb -U "${POSTGRES_USER}" --if-exists --force "${POSTGRES_DB}"
docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres \
  createdb -U "${POSTGRES_USER}" "${POSTGRES_DB}"

log "Restoring ${FILE} → local postgres..."
docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres \
  pg_restore -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --no-owner --no-privileges < "${TMP}"

log "Re-applying schema grants (setup-postgres.sh) — dropdb wiped per-DB grants..."
"$(dirname "$0")/setup-postgres.sh"

log "Restore complete. Schema summary:"
docker exec -i -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres \
  psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -P pager=off -c \
  "SELECT schemaname, count(*) AS tables, COALESCE(sum(n_live_tup),0) AS approx_rows
     FROM pg_stat_user_tables GROUP BY schemaname ORDER BY schemaname;"
