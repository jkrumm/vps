#!/usr/bin/env bash
# =============================================================================
# Manual image upgrade for the Mac mini's Postgres (compose.dev.yml). Dev-host
# only; `make dev-pg-upgrade`. The dev twin of `make infra-upgrade`, with the two
# guards that one leaves to the operator:
#
#   1. A backup to the HomeLab runs FIRST and must succeed (backup-pg-dev.sh).
#   2. A MAJOR bump is refused. `postgres:18` floats across 18.x, so pull+up is
#      a minor upgrade. Another major cannot start on this data directory — the
#      container would crash-loop — so the script stops before touching it and
#      points at the dump/restore procedure in docs/mini-postgres.md.
#
# Invoked through make with $(OP_RUN_DEV) so compose can interpolate the
# service's env; the script itself reads no secret.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "${HERE}")"
log() { echo "[$(date +%H:%M:%S)] $*"; }

[[ "$(docker inspect -f '{{.State.Status}}' postgres 2>/dev/null)" == "running" ]] || {
  echo "ERROR: local 'postgres' container not running. Run 'make up' first."; exit 1; }

# Pin the compose project to the one that OWNS the running container. Compose derives the
# default from the checkout directory, so from a worktree it would build a second project
# with an empty data volume and then collide on the fixed container name.
PROJECT=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' postgres)
[[ -n "${PROJECT}" ]] || { echo "ERROR: cannot read the compose project of the postgres container"; exit 1; }
COMPOSE=(docker compose -p "${PROJECT}" -f "${ROOT}/compose.dev.yml")

PGU=$(docker exec postgres printenv POSTGRES_USER)
before=$(docker exec postgres psql -U "${PGU}" -d postgres -Atc 'SHOW server_version')
data_major=$(docker exec postgres psql -U "${PGU}" -d postgres -Atc 'SHOW server_version_num')
data_major=$((data_major / 10000))
log "running ${before} (data directory major ${data_major})"

log "backup first"
"${HERE}/backup-pg-dev.sh"

log "pull"
"${COMPOSE[@]}" pull postgres
image=$("${COMPOSE[@]}" config --images postgres)
new_major=$(docker run --rm --entrypoint postgres "${image}" --version | sed -E 's/^postgres \(PostgreSQL\) ([0-9]+).*/\1/')
if [[ "${new_major}" != "${data_major}" ]]; then
  echo "REFUSED: ${image} is PostgreSQL ${new_major}, the data directory is ${data_major}. A major upgrade is a dump/restore — see docs/mini-postgres.md → Major upgrade. Nothing was restarted."
  exit 1
fi

log "recreate (only if the image or config changed)"
"${COMPOSE[@]}" up -d postgres

for _ in $(seq 1 30); do
  [[ "$(docker inspect -f '{{.State.Health.Status}}' postgres 2>/dev/null)" == "healthy" ]] && break
  sleep 2
done
[[ "$(docker inspect -f '{{.State.Health.Status}}' postgres 2>/dev/null)" == "healthy" ]] || { echo "ERROR: postgres not healthy 60s after the upgrade"; exit 1; }

after=$(docker exec postgres psql -U "${PGU}" -d postgres -Atc 'SHOW server_version')
log "now running ${after}"
"${HERE}/health-pg-dev.sh"
