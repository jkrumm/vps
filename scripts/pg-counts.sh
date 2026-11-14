#!/usr/bin/env bash
# =============================================================================
# Exact row counts for ONE database of the local dev Postgres — read-only. The
# drill uses it on its scratch databases; the backup runs the same SQL
# (pg-counts.sql) inside the dump's snapshot.
#
# Prints stable-sorted `key|value` lines on stdout, see pg-counts.sql.
#
# Usage: pg-counts.sh <database>
# No secrets: the container's unix socket or the bare server's (scripts/lib-pg-dev.sh);
# the target of the calling script is inherited through PG_DEV_TARGET.
# =============================================================================
set -euo pipefail

DB="${1:?usage: pg-counts.sh <database>}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-pg-dev.sh
source "${HERE}/lib-pg-dev.sh"
pg_select_target || exit 1

pg_exec_i psql -d "${DB}" -At -F'|' -v ON_ERROR_STOP=1 < "${HERE}/pg-counts.sql" \
  | LC_ALL=C sort -t'|' -k1,1
