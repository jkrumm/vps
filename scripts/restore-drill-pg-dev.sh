#!/usr/bin/env bash
# =============================================================================
# Restore drill for the Mac mini's Postgres backups. Dev-host only, read-only
# against the live instance (it only ever creates and drops its OWN scratch
# databases). `make dev-pg-restore-drill`.
#
# 1. Fetches the newest COMPLETE backup from the HomeLab (or BACKUP=<name>),
#    verifies SHA256SUMS — so the transfer path is part of the drill.
# 2. Checks globals.sql carries the cluster roles.
# 3. Restores every <database>.dump into a scratch database
#    `restore_drill_<ts>_<n>` with pg_restore --exit-on-error.
# 4. Compares the restored table set, exact row counts and relation-kind counts
#    to counts.tsv, which the backup took from the SOURCE inside the very
#    snapshot the dump read — so the comparison is plain equality.
# 5. Drops the scratch databases it created and exits non-zero on any mismatch
#    or error.
#
# Housekeeping at the start: it drops leftovers of crashed drills — databases
# named exactly restore_drill_<14 digits>_<n> whose timestamp is more than two
# hours old (a live drill, e.g. the verify step of a backup, is younger) — and
# sweeps pg-dev-drill.* / pg-dev-backup.* directories older than two hours from
# TMPDIR. Nothing else is ever dropped. Env: PG_DEV_BACKUP_DEST as in
# backup-pg-dev.sh.
# =============================================================================
set -euo pipefail
umask 077

DEST="${PG_DEV_BACKUP_DEST:-homelab:/mnt/hdd/backups/vps-mini-postgres}"
DEST_HOST="${DEST%%:*}"
DEST_PATH="${DEST#*:}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "DRILL FAIL: $*" >&2; FAILED=1; }

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
FAILED=0

[[ "$(docker inspect -f '{{.State.Status}}' postgres 2>/dev/null)" == "running" ]] || {
  echo "ERROR: local 'postgres' container not running."; exit 1; }
PGU=$(docker exec postgres printenv POSTGRES_USER)

# --- housekeeping: leftovers of crashed runs --------------------------------
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d \( -name 'pg-dev-drill.*' -o -name 'pg-dev-backup.*' \) -mmin +120 \
  -exec rm -rf {} + 2>/dev/null || true
CUTOFF=$(date -v-2H +%Y%m%d%H%M%S 2>/dev/null || date -d '-2 hours' +%Y%m%d%H%M%S)
STALE=$(docker exec postgres psql -U "${PGU}" -d postgres -At -c \
  "SELECT datname FROM pg_database WHERE datname ~ '^restore_drill_[0-9]{14}_[0-9]+\$' ORDER BY 1")
for old in ${STALE}; do
  stamp=${old#restore_drill_}; stamp=${stamp%%_*}
  if [[ "${stamp}" < "${CUTOFF}" ]]; then
    docker exec postgres dropdb -U "${PGU}" --force "${old}" && log "dropped stale scratch database ${old}"
  fi
done

NAME="${BACKUP:-}"
if [[ -z "${NAME}" ]]; then
  NAME=$("${SSH[@]}" "${DEST_HOST}" "cd '${DEST_PATH}' && ls -1d [0-9]*T*Z 2>/dev/null | grep -E '^[0-9]{8}T[0-9]{6}Z\$' | sort | tail -1")
fi
[[ -n "${NAME}" ]] || { echo "ERROR: no complete backup found in ${DEST_HOST}:${DEST_PATH}"; exit 1; }
[[ "${NAME}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo "ERROR: BACKUP must look like 20260101T030000Z, got '${NAME}'"; exit 1; }

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/pg-dev-drill.XXXXXX")
SCRATCH=()
cleanup() {
  local s
  # shellcheck disable=SC2048,SC2086
  for s in ${SCRATCH[@]+"${SCRATCH[@]}"}; do
    docker exec postgres dropdb -U "${PGU}" --if-exists --force "${s}" >/dev/null 2>&1 \
      && log "dropped scratch database ${s}" || echo "WARN: could not drop scratch database ${s}" >&2
  done
  rm -rf "${STAGE}"
}
trap cleanup EXIT

log "Drill against backup ${NAME}"
"${SSH[@]}" "${DEST_HOST}" "tar -C '${DEST_PATH}/${NAME}' -cf - ." | tar -C "${STAGE}" -xf -
( cd "${STAGE}" && shasum -a 256 -c --quiet SHA256SUMS ) || { echo "DRILL FAIL: checksum mismatch after download"; exit 1; }
log "checksums verified"

grep -q 'CREATE ROLE' "${STAGE}/globals.sql" || fail "globals.sql has no CREATE ROLE"

STAMP=$(date +%Y%m%d%H%M%S)
N=0
for dump in "${STAGE}"/*.dump; do
  db=$(basename "${dump}" .dump)
  N=$((N + 1))
  scratch="restore_drill_${STAMP}_${N}"
  docker exec postgres createdb -U "${PGU}" "${scratch}"
  SCRATCH+=("${scratch}")

  log "restore ${db} → ${scratch}"
  if ! docker exec -i postgres pg_restore -U "${PGU}" -d "${scratch}" --no-owner --no-privileges --exit-on-error < "${dump}"; then
    fail "pg_restore of ${db} failed"
    continue
  fi

  "${HERE}/pg-counts.sh" "${scratch}" > "${STAGE}/restored.txt"
  # counts.tsv rows for this db → key|rows, joined to the restored key|rows; the full outer
  # join makes a missing or surplus table show as a mismatch. Exact equality.
  awk -F'|' -v db="${db}" '$1 == db { print $2 "|" $3 }' "${STAGE}/counts.tsv" | LC_ALL=C sort -t'|' -k1,1 > "${STAGE}/expected.txt"
  report=$(LC_ALL=C join -t'|' -a1 -a2 -e MISSING -o 0,1.2,2.2 "${STAGE}/expected.txt" "${STAGE}/restored.txt" \
    | awk -F'|' '
        { key = $1; want = $2; got = $3;
          if (want != got) { printf "%s: expected %s, restored %s\n", key, want, got; bad++; next }
          if (key !~ /^~/) { tables++; rows += got }
        }
        END { if (bad) exit 1; printf "%d tables, %d rows\n", tables, rows }') || {
    fail "${db}: restored data differs from the source counts recorded in the dump's snapshot:"
    printf '%s\n' "${report}" | sed 's/^/    /' >&2
    continue
  }
  log "  ✓ ${db}: ${report}"
done

[[ ${N} -gt 0 ]] || fail "backup ${NAME} contains no database dumps"

if [[ ${FAILED} -ne 0 ]]; then
  echo "DRILL FAIL: backup ${NAME}" >&2
  exit 1
fi
echo "DRILL PASS: backup ${NAME}, ${N} database(s) restored and matched the source counts"
