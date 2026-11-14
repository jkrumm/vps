#!/usr/bin/env bash
# =============================================================================
# Direct VPS → local Postgres single-schema sync via SSH (Tailscale). Dev-only.
# Local side: the mini's Homebrew server on 127.0.0.1:5432 (scripts/lib-pg-dev.sh), logging
# in over TCP as the schema's role with its password.
#
# Generic version of what each app used to carry in its own repo. Pulls a fresh
# dump of ONE schema from prod and swaps its contents locally, leaving every
# other schema untouched. Least-privilege: dumps and restores as the schema's
# own role (role name == schema name), never the superuser.
#
# Why per-schema, and the only sync there is?
#   Postgres here is one DB with many schemas (public, umami, argo,
#   basalt_ui_playground) next to separate databases (agent_workflows). Seeding
#   one app must not clobber the others; the old whole-DB sync-from-prod did,
#   and was retired.
#
# Convention (matches the roles in dotfiles config/postgres/cluster.yaml and .env.tpl):
#   - role name      == schema name           (argo, umami, basalt_ui_playground)
#   - password env   == UPPER(schema)_DB_PASSWORD
#                       argo → ARGO_DB_PASSWORD, umami → UMAMI_DB_PASSWORD, …
#
# Usage:  make pg-sync-schema SCHEMA=argo
#         (apps delegate: `make -C ../vps pg-sync-schema SCHEMA=argo ENV=dev`)
#
# Required env (resolved by op run --env-file=.env.tpl):
#   POSTGRES_DB, <UPPER(SCHEMA)>_DB_PASSWORD
# =============================================================================
set -euo pipefail

: "${SCHEMA:?must set SCHEMA=<name> (e.g. SCHEMA=argo)}"
: "${POSTGRES_DB:?must be set}"

PWVAR="$(echo "${SCHEMA}" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD"
SCHEMA_PW="${!PWVAR:-}"
[[ -z "${SCHEMA_PW}" ]] && {
  echo "ERROR: ${PWVAR} not set — add it to .env.tpl or pass it in the environment."; exit 1;
}

log() { echo "[$(date +%H:%M:%S)] $*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-pg-dev.sh
source "${HERE}/lib-pg-dev.sh"
pg_select_target || exit 1
# The schema's own role, over TCP (the cluster's pg_hba admits app roles by password only).
local_psql() { PGPASSWORD="${SCHEMA_PW}" "${PG_BIN}/psql" -h 127.0.0.1 -p "${PG_BARE_PORT}" -U "${SCHEMA}" -d "${POSTGRES_DB}" "$@"; }

log "Dumping '${SCHEMA}' schema from VPS (as role ${SCHEMA}) → local..."
# pg_dump --clean emits a `DROP SCHEMA ${SCHEMA}` which the app role can't run
# (the schema is owned by the cluster superuser; the role only owns objects in
# it). Strip schema-level DDL — the schema already exists locally from
# the cluster (`make -C ~/SourceRoot/dotfiles pg-apply`); we only swap its contents.
ssh vps "docker exec postgres pg_dump -U '${SCHEMA}' -d '${POSTGRES_DB}' \
  --schema='${SCHEMA}' --clean --if-exists --no-owner --no-privileges" \
  | grep -v -E '^(DROP|CREATE|COMMENT ON|ALTER) SCHEMA' \
  | local_psql -v ON_ERROR_STOP=1

log "Sync complete. '${SCHEMA}' table summary:"
local_psql -P pager=off -c \
  "SELECT relname AS table, n_live_tup AS approx_rows
     FROM pg_stat_user_tables WHERE schemaname='${SCHEMA}'
    ORDER BY n_live_tup DESC;"
