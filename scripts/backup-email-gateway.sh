#!/usr/bin/env bash
# =============================================================================
# email-gateway backup — SQLite snapshots → gzip tarball → object storage (S3-compatible)
# Runs via cron (see cron/email-gateway-backup). Manual: op run --env-file=.env.tpl -- ./scripts/backup-email-gateway.sh
#
# The service keeps two SQLite stores in /var/lib/email-gateway (bind-mounted at /data):
# email-gateway.sqlite and mail.sqlite. Each is copied with SQLite's online `.backup`
# (consistent snapshot, safe while the service writes), checked with
# `PRAGMA integrity_check`, then both go into one tar.gz. The sqlite3 CLI is not
# assumed on the host or in the app image, so a one-shot alpine container runs it.
#
# Required env vars (from 1Password via .env.tpl):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#   AWS_S3_BUCKET, AWS_S3_ENDPOINT
# Optional:
#   EMAIL_GATEWAY_BACKUP_KUMA_PUSH_URL  (Uptime Kuma push monitor; skipped when unset)
# =============================================================================
set -euo pipefail

DATA_DIR="${EMAIL_GATEWAY_DATA_DIR:-/var/lib/email-gateway}"
DBS=(email-gateway.sqlite mail.sqlite)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILENAME="email-gateway_${TIMESTAMP}.tar.gz"
BACKUP_PREFIX="backups/vps/email-gateway"
# Retention: B2 lifecycle rule on prefix `backups/vps/` (see backup-pg.sh); the backup key
# cannot delete, so a bad object stays — it is reported, never silently "up".

log() { echo "[$(date +%H:%M:%S)] $*"; }

ping_kuma() {
  local status="$1" msg="$2"
  if [[ -n "${EMAIL_GATEWAY_BACKUP_KUMA_PUSH_URL:-}" ]]; then
    curl -fsSL --max-time 10 "${EMAIL_GATEWAY_BACKUP_KUMA_PUSH_URL}?status=${status}&msg=${msg}&ping=" > /dev/null 2>&1 || true
  fi
}

WORK=$(mktemp -d /tmp/email-gateway-backup.XXXXXX)

cleanup() {
  local rc=$?
  rm -rf "${WORK}"
  if [[ ${rc} -ne 0 ]]; then
    log "Backup FAILED: ${BACKUP_FILENAME}"
    ping_kuma "down" "backup_failed"
  fi
}
trap cleanup EXIT

log "Starting backup: ${BACKUP_FILENAME}"

mkdir "${WORK}/snap"
# Root in the container reads the app user's files; the snapshots are chowned back to the
# calling user. /data is mounted rw because a WAL-mode reader needs the -shm file.
docker run --rm \
  -v "${DATA_DIR}:/data" \
  -v "${WORK}/snap:/out" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  alpine:3 sh -euc '
    apk add --no-cache -q sqlite >/dev/null
    for db in '"${DBS[*]}"'; do
      [ -f "/data/${db}" ] || { echo "missing /data/${db}" >&2; exit 1; }
      sqlite3 "/data/${db}" ".backup /out/${db}"
      res=$(sqlite3 "/out/${db}" "PRAGMA integrity_check;")
      [ "${res}" = "ok" ] || { echo "integrity_check failed for ${db}: ${res}" >&2; exit 1; }
      echo "snapshot ok: ${db}"
    done
    chown -R "${HOST_UID}:${HOST_GID}" /out
  '

tar -C "${WORK}/snap" -czf "${WORK}/${BACKUP_FILENAME}" "${DBS[@]}"
tar -tzf "${WORK}/${BACKUP_FILENAME}" > /dev/null
LOCAL_SIZE=$(wc -c < "${WORK}/${BACKUP_FILENAME}" | tr -d ' ')

aws s3 cp "${WORK}/${BACKUP_FILENAME}" "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${BACKUP_FILENAME}" \
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

log "Backup uploaded: s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${BACKUP_FILENAME} (${LOCAL_SIZE} bytes)"
log "Backup complete."
ping_kuma "up" "backup_ok"
