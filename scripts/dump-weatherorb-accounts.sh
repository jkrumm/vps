#!/usr/bin/env bash
# =============================================================================
# weatherorb accounts — hourly pg_dump of the weatherorb_accounts database
# Runs as root via cron (see cron/weatherorb-accounts-dump). Safe to run by hand with sudo.
#
# Writes weatherorb_accounts-<UTC %Y%m%dT%H%MZ>.dump (custom format) into
# /var/backups/weatherorb-accounts, verified with pg_restore --list before it becomes visible
# (tmp file → atomic rename), root:wo-backup 0640, newest 48 kept. The homelab pulls the
# directory as `wo-backup` over Tailscale SSH (scripts/setup-weatherorb-backup-user.sh).
#
# Required env vars (sourced from /etc/vps/weatherorb-accounts-dump.env — see the cron file):
#   WEATHERORB_ACCOUNT_DB_PASSWORD
# =============================================================================
set -euo pipefail

: "${WEATHERORB_ACCOUNT_DB_PASSWORD:?WEATHERORB_ACCOUNT_DB_PASSWORD not set}"

BACKUP_DIR="/var/backups/weatherorb-accounts"
BACKUP_GROUP="wo-backup"
KEEP=48
IMAGE="postgres:18"
DB="weatherorb_accounts"
DB_USER="weatherorb_account"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

[[ -d "${BACKUP_DIR}" ]] || { log "✗ ${BACKUP_DIR} missing — run 'make weatherorb-backup-user' first"; exit 1; }

FINAL="${BACKUP_DIR}/${DB}-$(date -u +%Y%m%dT%H%M%SZ).dump"
TMP="$(mktemp "${BACKUP_DIR}/.${DB}.XXXXXX.tmp")"
trap 'rm -f "${TMP}"' EXIT

log "Dumping ${DB} → ${FINAL}"
# One-shot container on postgres-net (same postgres:18 image as the server), streamed to the host.
docker run --rm \
  --network postgres-net \
  -e PGPASSWORD="${WEATHERORB_ACCOUNT_DB_PASSWORD}" \
  "${IMAGE}" \
  pg_dump \
    --host=postgres \
    --username="${DB_USER}" \
    --dbname="${DB}" \
    --format=custom \
  > "${TMP}"

# A truncated or empty dump must never become the newest file the homelab pulls.
docker run --rm -i "${IMAGE}" pg_restore --list < "${TMP}" > /dev/null

chown "root:${BACKUP_GROUP}" "${TMP}"
chmod 0640 "${TMP}"
mv -f "${TMP}" "${FINAL}"
log "Dump verified: ${FINAL} ($(stat -c %s "${FINAL}") bytes)"

# Retention: keep the newest ${KEEP} (names sort chronologically).
ls -1 "${BACKUP_DIR}/${DB}"-*.dump 2>/dev/null | sort | head -n "-${KEEP}" | xargs -r rm -f --
log "Done."
