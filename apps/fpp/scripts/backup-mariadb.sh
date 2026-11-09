#!/usr/bin/env bash
# =============================================================================
# MariaDB backup — mariadb-dump → object storage (S3-compatible)
# Mirrors scripts/backup-pg.sh: B2 lifecycle handles retention,
# Uptime Kuma push monitor, runs in a one-shot mariadb:11.4 container.
#
# Required env vars (from 1Password via .env.tpl):
#   MARIADB_DB, MARIADB_ROOT_PASSWORD
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#   AWS_S3_BUCKET, AWS_S3_ENDPOINT
#   UPTIME_KUMA_FPP_BACKUP_PUSH_URL  (separate Kuma monitor from pg-backup)
# =============================================================================
set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILENAME="mariadb_${MARIADB_DB}_${TIMESTAMP}.sql.gz"
BACKUP_PREFIX="backups/vps/mariadb"
# Retention enforced by the B2 bucket lifecycle rule on prefix `backups/vps/`
# (hide after 14 days, delete 1 day after hiding) — same rule as Postgres backups.

log() { echo "[$(date +%H:%M:%S)] $*"; }

ping_kuma() {
  local status="$1"
  local msg="$2"
  if [[ -n "${UPTIME_KUMA_FPP_BACKUP_PUSH_URL:-}" ]]; then
    curl -fsSL --max-time 10 "${UPTIME_KUMA_FPP_BACKUP_PUSH_URL}?status=${status}&msg=${msg}&ping=" > /dev/null 2>&1 || true
  fi
}

TMP=$(mktemp /tmp/mariadb_backup_XXXXXX.sql.gz)

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

# Dump → gzip → temp file, verified, THEN uploaded: the bucket is append-only (no delete),
# so a truncated object could never be removed. mariadb-dump ends a complete dump with a
# "-- Dump completed" line; gzip -t proves the stream is intact. pipefail aborts on a failed dump.
# --single-transaction: consistent InnoDB snapshot without table locks.
# --routines + --triggers + --events: include stored procs, triggers, scheduled events.
# --ssl-verify-server-cert=0: server cert is *.free-planning-poker.com, internal hostname is `mariadb`.
#   Encryption still applies (require-secure-transport=ON), only hostname check is skipped —
#   acceptable on the private mariadb-net Docker network.
docker run --rm \
  --network mariadb-net \
  -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
  mariadb:11.4 \
  mariadb-dump \
    --host=mariadb \
    --user=root \
    --ssl-verify-server-cert=0 \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --databases "${MARIADB_DB}" \
  | gzip -9 \
  > "${TMP}"

gzip -t "${TMP}"
if ! gzip -dc "${TMP}" | tail -n 5 | grep -q '^-- Dump completed'; then
  log "Dump incomplete: no '-- Dump completed' trailer"
  exit 1
fi
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
log "Backup complete."
ping_kuma "up" "backup_ok"
