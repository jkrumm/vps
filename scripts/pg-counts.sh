#!/usr/bin/env bash
# =============================================================================
# Exact row counts for ONE database of the local dev Postgres — the instrument
# behind the mini's backup manifest and restore drill. Read-only.
#
# Prints stable-sorted `key|value` lines on stdout:
#   <schema>.<table>|<COUNT(*)>        one per ordinary table (not system schemas)
#   ~relkind.<k>|<n>                   user relations by kind (r table, i index,
#                                      S sequence, v view, m matview, p partitioned)
# The ~relkind rows make an EMPTY database verifiable too: a restore that lost
# every index still has zero rows to compare, but not the same index count.
#
# Usage: pg-counts.sh <database>
# No secrets: the superuser name comes from the container's own environment and
# the connection is the in-container unix socket.
# =============================================================================
set -euo pipefail

DB="${1:?usage: pg-counts.sh <database>}"
PGU=$(docker exec postgres printenv POSTGRES_USER)

docker exec -i postgres psql -U "${PGU}" -d "${DB}" -At -F'|' -v ON_ERROR_STOP=1 <<'SQL' | LC_ALL=C sort -t'|' -k1,1
SELECT n.nspname || '.' || c.relname,
  (xpath('/row/c/text()',
     query_to_xml(format('select count(*) c from %I.%I', n.nspname, c.relname),
                  false, true, '')))[1]::text::bigint
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast');
SELECT '~relkind.' || c.relkind::text, count(*)
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'i', 'S', 'v', 'm', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
GROUP BY c.relkind;
SQL
