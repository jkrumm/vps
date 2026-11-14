#!/usr/bin/env bash
# =============================================================================
# Readiness probe for the Mac mini's Postgres. Dev-host only. One line on stdout,
# exit 0 healthy / 1 not. `make dev-pg-health`.
#
# Probes the Homebrew server (scripts/lib-pg-dev.sh: unix socket /tmp:5432, OS
# user). Built to be called by the mini's devhost heartbeat (a `probe_postgres`
# service entry — see docs/mini-postgres.md); it holds no Kuma URL itself, so a
# probe failure and a missing heartbeat can never be confused. bash 3.2 compatible
# (that heartbeat runs under Apple's /bin/bash).
#
# Checks: SELECT 1 over the unix socket, 127.0.0.1:5432 accepting connections (the path every host app
# uses), and each database in PG_DEV_REQUIRE_DBS (default: agent_workflows)
# present with its owning role.
# =============================================================================
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-pg-dev.sh
source "${HERE}/lib-pg-dev.sh"
REQUIRE_DBS="${PG_DEV_REQUIRE_DBS-agent_workflows}"

bad() { echo "postgres: $*"; exit 1; }

errf=$(mktemp "${TMPDIR:-/tmp}/pg-dev-health.XXXXXX")
trap 'rm -f "${errf}"' EXIT
# not in $(...): it must set PGU in this shell
pg_select_target > "${errf}" 2>&1 || bad "$(sed 's/^ERROR: //' "${errf}")"

pg_exec psql -d postgres -Atc 'SELECT 1' >/dev/null 2>&1 || bad "SELECT 1 failed over the socket"
nc -z -w 3 127.0.0.1 5432 >/dev/null 2>&1 || bad "127.0.0.1:5432 not accepting connections"

for db in ${REQUIRE_DBS}; do
  [[ "${db}" =~ ^[a-z_][a-z0-9_]*$ ]] || bad "PG_DEV_REQUIRE_DBS entry '${db}' is not a plain lower-case identifier"
  # name goes in as a psql variable, quoted by psql — and on stdin, because -c does not interpolate
  owner=$(printf '%s\n' "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = :'db'" \
    | pg_exec_i psql -d postgres -At -v "db=${db}" 2>/dev/null) || bad "catalog query failed"
  [[ -n "${owner}" ]] || bad "database '${db}' missing (declare it in dotfiles config/postgres/cluster.yaml, then make -C ~/SourceRoot/dotfiles pg-apply)"
  [[ "${owner}" == "${db}" ]] || bad "database '${db}' owned by '${owner}', expected '${db}'"
done

echo "postgres ok"
