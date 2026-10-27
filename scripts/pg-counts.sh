#!/usr/bin/env bash
# =============================================================================
# Exact row counts for ONE database of the local dev Postgres — read-only. The
# drill uses it on its scratch databases; the backup runs the same SQL
# (pg-counts.sql) inside the dump's snapshot.
#
# Prints stable-sorted `key|value` lines on stdout, see pg-counts.sql.
#
# Usage: pg-counts.sh <database>
# No secrets: the superuser name comes from the container's own environment and
# the connection is the in-container unix socket.
# =============================================================================
set -euo pipefail

DB="${1:?usage: pg-counts.sh <database>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PGU=$(docker exec postgres printenv POSTGRES_USER)

docker exec -i postgres psql -U "${PGU}" -d "${DB}" -At -F'|' -v ON_ERROR_STOP=1 < "${HERE}/pg-counts.sql" \
  | LC_ALL=C sort -t'|' -k1,1
