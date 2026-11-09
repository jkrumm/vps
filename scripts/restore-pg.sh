#!/usr/bin/env bash
# =============================================================================
# PostgreSQL restore from object storage backup → OVERWRITES the PRODUCTION DB.
#
# THIS IS A LAST-RESORT DISASTER-RECOVERY TOOL. There is deliberately NO `make`
# target for it. It is heavily gated (see guard below). For the full procedure
# read docs/disaster-recovery.md FIRST.
#
# Usage (human, deliberate):
#   op run --env-file=.env.tpl -- env BACKUP_FILE=<file> ./scripts/restore-pg.sh
#
# Required env vars (from 1Password via .env.tpl):
#   POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
#   AWS_S3_BUCKET, AWS_S3_ENDPOINT
# =============================================================================
set -euo pipefail

BACKUP_FILE="${BACKUP_FILE:-}"
BACKUP_PREFIX="backups/vps/postgres"

if [[ -z "${BACKUP_FILE}" ]]; then
  echo "Usage: BACKUP_FILE=<filename> ./scripts/restore-pg.sh"
  echo ""
  echo "Available backups:"
  aws s3 ls "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/" \
    --endpoint-url "${AWS_S3_ENDPOINT}" \
    | awk '{print $4}' | sort
  exit 1
fi

# ─── PRODUCTION RESTORE GUARD ────────────────────────────────────────────────
# Overwrites PROD. No make target. Human-only. See docs/disaster-recovery.md.
#   1. refuses on passwordless-sudo hosts (the VPS) unless BREAK_GLASS=1
#   2. requires a real sudo password (proves a present human / local machine)
#   3. requires typing the exact database name
echo
echo "##############################################################"
echo "#  DANGER: about to DROP & RESTORE the PRODUCTION database.   #"
echo "##############################################################"
sudo -k 2>/dev/null || true
if [[ "${BREAK_GLASS:-}" != "1" ]] && sudo -n true 2>/dev/null; then
  echo "REFUSED: passwordless sudo detected — this looks like the VPS."
  echo "Run from your local machine (password-protected sudo). For genuine"
  echo "on-server DR, re-run with BREAK_GLASS=1. See docs/disaster-recovery.md."
  exit 1
fi
echo "Authenticate as a human operator (sudo password required):"
sudo -v
echo "Backup file: ${BACKUP_FILE}"
read -rp "Type the database name to confirm: " confirm
[[ "${confirm}" != "${POSTGRES_DB}" ]] && { echo "Name mismatch. Aborted."; exit 1; }
# ─────────────────────────────────────────────────────────────────────────────

echo "Downloading ${BACKUP_FILE} from S3..."
TMPFILE=$(mktemp /tmp/pg_restore_XXXXXX.dump)
trap 'rm -f "${TMPFILE}"' EXIT

aws s3 cp "s3://${AWS_S3_BUCKET}/${BACKUP_PREFIX}/${BACKUP_FILE}" "${TMPFILE}" \
  --endpoint-url "${AWS_S3_ENDPOINT}"

# Ownership is restored (no --no-owner): each schema-owning role must own its
# schema, tables and migration journal again (AGENTS.md, Postgres Schema Model).
# Roles are cluster-level and survive dropdb, but on a fresh cluster they must
# exist BEFORE this runs — `make postgres-setup` first (docs/disaster-recovery.md).
# --no-privileges: GRANTs are not taken from the dump; `make postgres-setup`
# re-applies them (idempotent) afterwards.
echo "Restoring into ${POSTGRES_DB}..."
docker run --rm \
  --network postgres-net \
  -e PGPASSWORD="${POSTGRES_PASSWORD}" \
  -v "${TMPFILE}:/backup.dump:ro" \
  postgres:18 \
  sh -c "
    dropdb --force --host=postgres --username=${POSTGRES_USER} --if-exists ${POSTGRES_DB} &&
    createdb --host=postgres --username=${POSTGRES_USER} ${POSTGRES_DB} &&
    pg_restore --host=postgres --username=${POSTGRES_USER} --dbname=${POSTGRES_DB} --no-privileges /backup.dump
  "

echo "Restore complete: ${POSTGRES_DB}"
echo "Next: make postgres-setup (re-applies grants), then check ownership — docs/disaster-recovery.md"
