#!/usr/bin/env bash
# =============================================================================
# Readiness probe for the Mac mini's Postgres (compose.dev.yml). Dev-host only.
# One line on stdout, exit 0 healthy / 1 not. `make dev-pg-health`.
#
# Built to be called by the mini's devhost heartbeat (a `probe_postgres` service
# entry — see docs/mini-postgres.md); it holds no Kuma URL itself, so a probe
# failure and a missing heartbeat can never be confused. bash 3.2 compatible
# (that heartbeat runs under Apple's /bin/bash).
#
# Checks: container running + healthy, SELECT 1 over the unix socket, the
# published 127.0.0.1:5432 port accepting connections (the path every host app
# uses), and each database in PG_DEV_REQUIRE_DBS (default: agent_workflows)
# present with its owning role.
# =============================================================================
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
REQUIRE_DBS="${PG_DEV_REQUIRE_DBS-agent_workflows}"

bad() { echo "postgres: $*"; exit 1; }

state=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' postgres 2>/dev/null) \
  || bad "container 'postgres' not found"
[[ "${state}" == "running healthy" ]] || bad "container is '${state}'"

PGU=$(docker exec postgres printenv POSTGRES_USER 2>/dev/null) || bad "cannot read the container environment"
docker exec postgres psql -U "${PGU}" -d postgres -Atc 'SELECT 1' >/dev/null 2>&1 || bad "SELECT 1 failed over the socket"
nc -z -w 3 127.0.0.1 5432 >/dev/null 2>&1 || bad "127.0.0.1:5432 not accepting connections"

for db in ${REQUIRE_DBS}; do
  owner=$(docker exec postgres psql -U "${PGU}" -d postgres -Atc \
    "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${db}'" 2>/dev/null) || bad "catalog query failed"
  [[ -n "${owner}" ]] || bad "database '${db}' missing (run make postgres-setup ENV=dev)"
  [[ "${owner}" == "${db}" ]] || bad "database '${db}' owned by '${owner}', expected '${db}'"
done

echo "postgres ok"
