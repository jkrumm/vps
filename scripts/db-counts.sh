#!/usr/bin/env bash
# =============================================================================
# Read-only EXACT row counts per table — Postgres (all schemas) + MariaDB (fpp).
#
# Verification instrument, not an operation: prints stable-sorted
# `schema|table|rows` lines that are safe to `diff` between two database states
# (e.g. local-after-sync vs local-after-S3-restore, to prove the data matches).
#
# Why not the summaries the sync/restore scripts already print? Those use
# Postgres `n_live_tup` (stale until ANALYZE/autovacuum runs — often 0 right
# after a restore) and MariaDB `TABLE_ROWS` (an InnoDB estimate). Neither proves
# equality. This does an actual COUNT(*) per table.
#
# Dev (the mini): Postgres is the Homebrew server on the unix socket /tmp:5432 as the OS
# user (scripts/lib-pg-dev.sh), database ${POSTGRES_DB:-postgres}; MariaDB is the dev
# container. Prod: the compose.infra.yml postgres container and apps/fpp's mariadb.
# No `op run` — each credential is read from the container's own environment.
#
# Usage:  make db-counts          (ENV comes from the Makefile; prod = the container path)
# =============================================================================
set -euo pipefail

# Heredoc keeps the SQL literal so its single quotes / format() escapes don't
# collide with the shell. query_to_xml runs a real COUNT(*) per table.
COUNT_SQL=$(cat <<'SQL'
SELECT n.nspname, c.relname,
  (xpath('/row/c/text()',
     query_to_xml(format('select count(*) c from %I.%I', n.nspname, c.relname),
                  false, true, '')))[1]::text::bigint
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1, 2;
SQL
)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${ENV:-dev}" == "prod" ]]; then
  # prod: the infra container
  if docker inspect -f '{{.State.Status}}' postgres >/dev/null 2>&1; then
    echo "# postgres"
    PGU=$(docker exec postgres printenv POSTGRES_USER)
    PGD=$(docker exec postgres printenv POSTGRES_DB)
    docker exec -i postgres psql -U "${PGU}" -d "${PGD}" -At -F'|' <<<"${COUNT_SQL}" | sort
  else
    echo "# postgres: container not running — skipped"
  fi
else
  # dev: the bare server
  # shellcheck source=lib-pg-dev.sh
  source "${HERE}/lib-pg-dev.sh"
  if pg_select_target >/dev/null 2>&1; then
    echo "# postgres"
    pg_exec_i psql -d "${POSTGRES_DB:-postgres}" -At -F'|' -v ON_ERROR_STOP=1 <<<"${COUNT_SQL}" | sort
  else
    echo "# postgres: no server on ${PG_BARE_SOCKDIR}:${PG_BARE_PORT} — skipped"
  fi
fi

echo
if docker inspect -f '{{.State.Status}}' mariadb >/dev/null 2>&1; then
  echo "# mariadb"
  MDB=$(docker exec mariadb printenv MARIADB_DATABASE)
  MPW=$(docker exec mariadb printenv MARIADB_ROOT_PASSWORD)
  TABLES=$(docker exec -e MYSQL_PWD="${MPW}" mariadb \
    mariadb -u root -N -B -e \
    "SELECT table_name FROM information_schema.tables
      WHERE table_schema='${MDB}' AND table_type='BASE TABLE'")
  for t in ${TABLES}; do
    c=$(docker exec -e MYSQL_PWD="${MPW}" mariadb \
      mariadb -u root -N -B -e "SELECT COUNT(*) FROM \`${MDB}\`.\`${t}\`")
    echo "${MDB}|${t}|${c}"
  done | sort
else
  echo "# mariadb: container not running — skipped"
fi
