#!/usr/bin/env bash
# =============================================================================
# PostgreSQL backup — pg_dump → object storage (S3-compatible)
# Runs via cron (see cron/pg-backup). Can also be triggered manually: make backup
# On success: pings Uptime Kuma push monitor.
# On failure: sends down status to Uptime Kuma + exits non-zero.
#
# Required env vars (from 1Password via .env.tpl):
#   POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#   AWS_S3_BUCKET, AWS_S3_ENDPOINT
#   UPTIME_KUMA_PUSH_URL
# =============================================================================
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILENAME="postgres_${POSTGRES_DB}_${TIMESTAMP}.dump"
BACKUP_PREFIX="backups/vps/postgres"
# Retention is enforced by the B2 bucket lifecycle rule on prefix `backups/vps/`
# (hide after 14 days, delete 1 day after hiding). The shared backup key has no
# deleteFiles capability — append-only by design for ransomware safety.

log() { echo "[$(date +%H:%M:%S)] $*"; }

ping_kuma() {
  local status="$1"
  local msg="$2"
  if [[ -n "${UPTIME_KUMA_PUSH_URL:-}" ]]; then
    curl -fsSL --max-time 10 "${UPTIME_KUMA_PUSH_URL}?status=${status}&msg=${msg}&ping=" > /dev/null 2>&1 || true
  fi
}

TMP=$(mktemp /tmp/pg_backup_XXXXXX.dump)

cleanup() {
  local rc=$?
  rm -f "${TMP}"
  if [[ ${rc} -ne 0 ]]; then
    log "Backup FAILED: ${BACKUP_FILENAME}"
    ping_kuma "down" "backup_failed"
  fi
}
trap cleanup EXIT

log "Starting backup: ${BACKUP_FILENAME}"

# Dump to a temp file first and verify it BEFORE upload: the bucket is append-only
# (no delete), so a truncated object could never be removed and would sit there as the
# "newest backup". pipefail + set -e abort on a failed dump; pg_restore --list proves the
# archive is complete and readable. Uses the same postgres:18 image as the running database.
docker run --rm \
  --network postgres-net \
  -e PGPASSWORD="${POSTGRES_PASSWORD}" \
  postgres:18 \
  pg_dump \
    --host=postgres \
    --username="${POSTGRES_USER}" \
    --dbname="${POSTGRES_DB}" \
    --format=custom \
    --compress=9 \
  > "${TMP}"

docker run --rm -i postgres:18 pg_restore --list < "${TMP}" > /dev/null
LOCAL_SIZE=$(wc -c < "${TMP}" | tr -d ' ')
log "Dump verified: ${LOCAL_SIZE} bytes"

aws s3 cp "${TMP}" "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${BACKUP_FILENAME}" \
  --endpoint-url "${AWS_S3_ENDPOINT}" \
  --storage-class STANDARD

REMOTE_SIZE=$(aws s3api head-object \
  --bucket "${AWS_S3_BUCKET}" --key "${BACKUP_PREFIX}/${BACKUP_FILENAME}" \
  --endpoint-url "${AWS_S3_ENDPOINT}" \
  --query ContentLength --output text)
if [[ "${REMOTE_SIZE}" != "${LOCAL_SIZE}" ]]; then
  log "Upload size mismatch: local ${LOCAL_SIZE}, remote ${REMOTE_SIZE}"
  exit 1
fi

log "Backup uploaded: s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${BACKUP_FILENAME}"

# Retention handled by B2 lifecycle rule — no client-side pruning needed.

log "Backup complete."
ping_kuma "up" "backup_ok"
