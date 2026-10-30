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
#   counts.tsv         db|key|rows — exact COUNT(*) per table plus relation-kind
#                      counts, taken INSIDE the same exported snapshot the dump
#                      reads (a REPEATABLE READ transaction held open while
#                      pg_dump --snapshot runs), so the manifest describes the
#                      dump exactly and the restore drill compares equality, no
#                      matter what writes concurrently.
#   SHA256SUMS         verified on the HomeLab after upload
# Uploaded to <name>.incomplete and renamed only after the checksum passes, so
# "newest backup" can never be a half-written one.
#
# Retention: the newest ${PG_DEV_BACKUP_KEEP:-14} complete backups on the
# HomeLab; older ones and stale .incomplete dirs are deleted at the end of a
# successful run. No client credential: the dump runs inside the container over
# its unix socket and the upload is keyless Tailscale SSH.
#
# On a fully green run it pushes an Uptime Kuma heartbeat (URL from the chmod-600 file
# ~/.config/uptime-kuma/pg-backup-push-url; absent = logged and skipped, never a failure).
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

# Dump one database and its exact counts from ONE snapshot. A background psql holds a
# REPEATABLE READ transaction open (commands arrive on a FIFO), exports its snapshot id,
# runs the count SQL, and stays open until pg_dump --snapshot=<id> is done.
dump_with_counts() {
  local db="$1" fifo="${STAGE}/hold.fifo" out="${STAGE}/holder.out" err="${STAGE}/holder.err" holder snap=""
  : > "${out}"; : > "${err}"
  mkfifo "${fifo}"
  docker exec -i postgres psql -U "${PGU}" -d "${db}" -qAt -F'|' -v ON_ERROR_STOP=1 < "${fifo}" > "${out}" 2> "${err}" &
  holder=$!
  exec 3> "${fifo}"
  {
    echo "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;"
    echo "SELECT 'SNAP|' || pg_export_snapshot();"
    echo "\\echo COUNTS_BEGIN"
    cat "${HERE}/pg-counts.sql"
    echo "\\echo COUNTS_END"
  } >&3
  # wait for the counts to be complete (or the holder to die)
  while ! grep -q '^COUNTS_END$' "${out}"; do
    if ! kill -0 "${holder}" 2>/dev/null; then
      exec 3>&-
      echo "ERROR: snapshot holder for ${db} died: $(cat "${err}")"; return 1
    fi
    sleep 0.2
  done
  snap=$(sed -n 's/^SNAP|//p' "${out}")
  [[ -n "${snap}" ]] || { exec 3>&-; echo "ERROR: no snapshot id exported for ${db}"; return 1; }

  docker exec postgres pg_dump -U "${PGU}" -d "${db}" --snapshot="${snap}" --format=custom --compress=6 > "${STAGE}/${db}.dump" || {
    exec 3>&-; wait "${holder}" 2>/dev/null || true; return 1; }

  # end the holder's transaction (EOF on stdin) and collect its output
  exec 3>&-
  wait "${holder}" || { echo "ERROR: snapshot holder for ${db} failed: $(cat "${err}")"; return 1; }
  sed -n '/^COUNTS_BEGIN$/,/^COUNTS_END$/p' "${out}" | { grep -v '^COUNTS_' || true; } \
    | LC_ALL=C sort -t'|' -k1,1 | sed "s/^/${db}|/" >> "${STAGE}/counts.tsv"
  rm -f "${fifo}" "${out}" "${err}"
}

: > "${STAGE}/counts.tsv"
for db in ${DBS}; do
  log "database ${db}"
  dump_with_counts "${db}"
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

# Success heartbeat — only reached when the whole run is green (set -e: a failed upload, drill or
# retention never gets here), so a missed push in Uptime Kuma means a failed OR a missed night.
# The push URL lives in a chmod-600 file, not the secrets cache (same rule as the devhost/drift
# heartbeats, dotfiles/scripts/lib/kuma-push.sh). No file yet = no monitor yet: log and carry on.
KUMA_LIB="${HERE}/../../dotfiles/scripts/lib/kuma-push.sh"
[[ -r "${KUMA_LIB}" ]] || KUMA_LIB="${HOME}/SourceRoot/dotfiles/scripts/lib/kuma-push.sh"
PUSH_URL_FILE="${HOME}/.config/uptime-kuma/pg-backup-push-url"
if [[ ! -r "${PUSH_URL_FILE}" ]]; then
  log "kuma: ${PUSH_URL_FILE} not found — no heartbeat pushed"
elif [[ ! -r "${KUMA_LIB}" ]]; then
  log "kuma: kuma-push.sh not found — no heartbeat pushed"
else
  # shellcheck source=/dev/null
  source "${KUMA_LIB}"
  # A heartbeat problem must never fail a backup that is already verified and uploaded.
  if push_url=$(kuma_resolve_push_url "" "${PUSH_URL_FILE}") \
    && kuma_push "${push_url}" up "backup ${NAME} ok, $(echo "${DBS}" | wc -w | tr -d ' ') databases"; then
    log "kuma: heartbeat pushed"
  else
    log "kuma: heartbeat push failed (backup itself is fine)"
  fi
fi
