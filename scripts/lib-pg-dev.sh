# shellcheck shell=bash
# =============================================================================
# Shared by the mini-Postgres scripts (backup-pg-dev.sh, restore-drill-pg-dev.sh,
# health-pg-dev.sh, pg-counts.sh). Source it; it runs nothing. bash 3.2 compatible
# (health-pg-dev.sh runs under Apple's /bin/bash).
#
# Which server a run talks to is decided per run by pg_select_target:
#   container  the `postgres` container, while it runs — psql & co. run inside it
#              (`docker exec`), as the container's POSTGRES_USER, over its socket.
#   bare       otherwise: the Homebrew server (postgresql@18) of the mini —
#              Homebrew's client binaries over the unix socket in /tmp, port 5432,
#              as the OS user, which is that server's superuser under local trust
#              (no credential). Roles, databases and settings of the bare server
#              are declared in dotfiles (config/postgres/cluster.yaml) and applied
#              by `make -C ~/SourceRoot/dotfiles pg-apply`, never from here.
# PG_DEV_TARGET=container|bare forces one (default auto). The resolved choice is
# exported, so a child script (pg-counts.sh) follows its parent.
#
# After pg_select_target: PG_TARGET, PGU (superuser name), pg_exec / pg_exec_i
# (run a client binary by name; _i passes stdin through), pg_target_label.
# =============================================================================

PG_BIN="${PG_DEV_BIN:-/opt/homebrew/opt/postgresql@18/bin}"
PG_BARE_SOCKDIR="${PG_DEV_SOCKDIR:-/tmp}"
PG_BARE_PORT="${PG_DEV_PORT:-5432}"

pg_container_running() {
  [[ "$(docker inspect -f '{{.State.Status}}' postgres 2>/dev/null)" == "running" ]]
}

# Sets PG_TARGET and PGU, or prints why no server is available and returns 1.
pg_select_target() {
  local want="${PG_DEV_TARGET:-auto}"
  case "${want}" in
    auto) if pg_container_running; then PG_TARGET=container; else PG_TARGET=bare; fi ;;
    container | bare) PG_TARGET="${want}" ;;
    *) echo "ERROR: PG_DEV_TARGET must be auto, container or bare, got '${want}'"; return 1 ;;
  esac
  if [[ "${PG_TARGET}" == "container" ]]; then
    pg_container_running || { echo "ERROR: local 'postgres' container not running."; return 1; }
    PGU=$(docker exec postgres printenv POSTGRES_USER) || { echo "ERROR: cannot read POSTGRES_USER from the container"; return 1; }
  else
    [[ -x "${PG_BIN}/psql" ]] || { echo "ERROR: ${PG_BIN}/psql not found (brew install postgresql@18)"; return 1; }
    PGU=$(id -un)
    "${PG_BIN}/pg_isready" -q -h "${PG_BARE_SOCKDIR}" -p "${PG_BARE_PORT}" || {
      echo "ERROR: no Postgres accepting connections on the unix socket ${PG_BARE_SOCKDIR}:${PG_BARE_PORT}."
      return 1
    }
  fi
  export PG_DEV_TARGET="${PG_TARGET}"
}

pg_target_label() {
  if [[ "${PG_TARGET}" == "container" ]]; then
    echo "container postgres"
  else
    echo "bare server (socket ${PG_BARE_SOCKDIR}:${PG_BARE_PORT})"
  fi
}

# pg_exec <client binary> [args...] — psql, pg_dump, pg_dumpall, pg_restore, createdb, dropdb.
pg_exec() {
  local bin="$1"; shift
  if [[ "${PG_TARGET}" == "container" ]]; then
    docker exec postgres "${bin}" -U "${PGU}" "$@"
  else
    "${PG_BIN}/${bin}" -h "${PG_BARE_SOCKDIR}" -p "${PG_BARE_PORT}" -U "${PGU}" "$@"
  fi
}

pg_exec_i() {
  local bin="$1"; shift
  if [[ "${PG_TARGET}" == "container" ]]; then
    docker exec -i postgres "${bin}" -U "${PGU}" "$@"
  else
    "${PG_BIN}/${bin}" -h "${PG_BARE_SOCKDIR}" -p "${PG_BARE_PORT}" -U "${PGU}" "$@"
  fi
}
