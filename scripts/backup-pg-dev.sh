#!/usr/bin/env bash
# =============================================================================
# Nightly backup of the Mac mini's Postgres (compose.dev.yml) → the HomeLab.
# Dev-host only. Scheduled by the com.jkrumm.vps-pg-backup LaunchAgent
# (launchd/, installed by `make dev-pg-launchd`) through `jobrun`, which writes
# the run record that `jobs-grade` turns into a Slack alert on failure OR on a
# missed night — that is the visibility, there is no log nobody reads. Manual:
# `make dev-pg-backup`.
#
# One backup = one directory <UTC timestamp>/ on the HomeLab holding
#   globals.sql        roles + their password verifiers (pg_dumpall --globals-only)
#   <database>.dump    pg_dump custom format, one per non-template database
#   counts.tsv         db|schema.table|rows_before|rows_after — exact COUNT(*)
#                      taken immediately BEFORE and AFTER each dump. The restore
#                      drill checks the restored count lies inside that bracket
#                      (exact when the table is quiet, tolerant only of proven
#                      concurrent writes).
#   SHA256SUMS         verified on the HomeLab after upload
# Uploaded to <name>.incomplete and renamed only after the checksum passes, so
# "newest backup" can never be a half-written one.
#
# Retention: the newest ${PG_DEV_BACKUP_KEEP:-14} complete backups on the
# HomeLab; older ones and stale .incomplete dirs are deleted at the end of a
# successful run. No client credential: the dump runs inside the container over
# its unix socket and the upload is keyless Tailscale SSH.
#
# Env (all optional):
#   PG_DEV_BACKUP_DEST  <ssh-host>:<absolute path>  (default homelab:/mnt/hdd/backups/vps-mini-postgres)
#   PG_DEV_BACKUP_KEEP  backups to keep (default 14)
#   PG_DEV_BACKUP_VERIFY  1 (default) restores the fresh backup into scratch DBs and fails the run on any mismatch
# =============================================================================
set -euo pipefail
umask 077

DEST="${PG_DEV_BACKUP_DEST:-homelab:/mnt/hdd/backups/vps-mini-postgres}"
KEEP="${PG_DEV_BACKUP_KEEP:-14}"
DEST_HOST="${DEST%%:*}"
DEST_PATH="${DEST#*:}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# launchd hands agents a minimal PATH; docker lives in Homebrew's.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

[[ "${DEST_PATH}" == /* && "${DEST_PATH}" != "/" ]] || { echo "ERROR: PG_DEV_BACKUP_DEST needs an absolute path, got '${DEST}'"; exit 1; }
[[ "${KEEP}" =~ ^[0-9]+$ && "${KEEP}" -ge 3 ]] || { echo "ERROR: PG_DEV_BACKUP_KEEP must be an integer >= 3"; exit 1; }
[[ "$(docker inspect -f '{{.State.Status}}' postgres 2>/dev/null)" == "running" ]] || {
  echo "ERROR: local 'postgres' container not running."; exit 1; }

PGU=$(docker exec postgres printenv POSTGRES_USER)
NAME=$(date -u +%Y%m%dT%H%M%SZ)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pg-dev-backup.XXXXXX")
trap 'rm -rf "${STAGE}"' EXIT

log "Backup ${NAME} → ${DEST_HOST}:${DEST_PATH}/"

log "roles (globals)"
docker exec postgres pg_dumpall -U "${PGU}" --globals-only > "${STAGE}/globals.sql"
grep -q 'CREATE ROLE' "${STAGE}/globals.sql" || { echo "ERROR: globals.sql has no roles — refusing to ship an empty dump"; exit 1; }

DBS=$(docker exec postgres psql -U "${PGU}" -d postgres -At \
  -c "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY 1")
[[ -n "${DBS}" ]] || { echo "ERROR: no databases to back up"; exit 1; }

: > "${STAGE}/counts.tsv"
for db in ${DBS}; do
  log "database ${db}"
  "${HERE}/pg-counts.sh" "${db}" > "${STAGE}/before.txt"
  docker exec postgres pg_dump -U "${PGU}" -d "${db}" --format=custom --compress=6 > "${STAGE}/${db}.dump"
  "${HERE}/pg-counts.sh" "${db}" > "${STAGE}/after.txt"
  # full outer join on the key; a table seen in only one snapshot counts as 0 in the other
  LC_ALL=C join -t'|' -a1 -a2 -e0 -o 0,1.2,2.2 "${STAGE}/before.txt" "${STAGE}/after.txt" \
    | sed "s/^/${db}|/" >> "${STAGE}/counts.tsv"
  rm -f "${STAGE}/before.txt" "${STAGE}/after.txt"
done

( cd "${STAGE}" && shasum -a 256 globals.sql counts.tsv ./*.dump | sed 's# \./# #' > SHA256SUMS )

log "upload"
"${SSH[@]}" "${DEST_HOST}" "umask 077 && mkdir -p '${DEST_PATH}/${NAME}.incomplete'"
COPYFILE_DISABLE=1 tar --no-xattrs -C "${STAGE}" -cf - . | "${SSH[@]}" "${DEST_HOST}" "tar -C '${DEST_PATH}/${NAME}.incomplete' -xf -"
"${SSH[@]}" "${DEST_HOST}" "cd '${DEST_PATH}/${NAME}.incomplete' && sha256sum -c --quiet SHA256SUMS && mv '${DEST_PATH}/${NAME}.incomplete' '${DEST_PATH}/${NAME}'"
log "uploaded and verified: $(du -sh "${STAGE}" | cut -f1) in $(echo "${DBS}" | wc -w | tr -d ' ') database(s)"

# Verify the backup we just wrote by restoring it (the drill refetches it from the
# HomeLab, so the transfer is covered too). Not optional by default: pg_dump's
# pg_get_*def calls do not honour the dump snapshot, so DDL running during a dump
# (a migration) can leave a syntactically broken definition in an archive whose
# checksum is perfectly fine. A failure here fails the run — and keeps retention
# from pruning on the strength of a bad backup.
if [[ "${PG_DEV_BACKUP_VERIFY:-1}" == "1" ]]; then
  log "verify: restore drill on ${NAME}"
  BACKUP="${NAME}" "${HERE}/restore-drill-pg-dev.sh"
fi

# Retention — names are matched against the strict timestamp pattern, so
# nothing else in the directory can be selected.
"${SSH[@]}" "${DEST_HOST}" "cd '${DEST_PATH}' \
  && ls -1d [0-9]*T*Z 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z\$' | sort | head -n -${KEEP} | xargs -r rm -rf -- \
  && find . -maxdepth 1 -name '*.incomplete' -mmin +1440 -exec rm -rf -- {} +"
log "retention: newest ${KEEP} kept"
log "Backup ${NAME} complete."
