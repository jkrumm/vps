# shellcheck shell=bash
# =============================================================================
# Shared by the mini-Postgres scripts (backup-pg-dev.sh, restore-drill-pg-dev.sh,
# health-pg-dev.sh, pg-counts.sh, db-counts.sh, restore-pg-local.sh). Source it; it
# runs nothing. bash 3.2 compatible (health-pg-dev.sh runs under Apple's /bin/bash).
#
# The mini has one Postgres: the Homebrew server (postgresql@18). Homebrew's client
# binaries talk to it over the unix socket in /tmp, port 5432, as the OS user, which is
# the server's superuser under local trust (no credential). Roles, databases and settings
# are declared in dotfiles (config/postgres/cluster.yaml) and applied by
# `make -C ~/SourceRoot/dotfiles pg-apply`, never from here.
#
# After pg_select_target: PGU (superuser name), pg_exec / pg_exec_i (run a client binary
# by name; _i passes stdin through), pg_target_label.
# =============================================================================

PG_BIN="${PG_DEV_BIN:-/opt/homebrew/opt/postgresql@18/bin}"
PG_BARE_SOCKDIR="${PG_DEV_SOCKDIR:-/tmp}"
PG_BARE_PORT="${PG_DEV_PORT:-5432}"

# Sets PGU, or prints why no server is available and returns 1.
pg_select_target() {
  [[ -x "${PG_BIN}/psql" ]] || { echo "ERROR: ${PG_BIN}/psql not found (brew install postgresql@18)"; return 1; }
  PGU=$(id -un)
  "${PG_BIN}/pg_isready" -q -h "${PG_BARE_SOCKDIR}" -p "${PG_BARE_PORT}" || {
    echo "ERROR: no Postgres accepting connections on the unix socket ${PG_BARE_SOCKDIR}:${PG_BARE_PORT}."
    return 1
  }
}

pg_target_label() {
  echo "Postgres (socket ${PG_BARE_SOCKDIR}:${PG_BARE_PORT})"
}

# pg_exec <client binary> [args...] — psql, pg_dump, pg_dumpall, pg_restore, createdb, dropdb.
pg_exec() {
  local bin="$1"; shift
  "${PG_BIN}/${bin}" -h "${PG_BARE_SOCKDIR}" -p "${PG_BARE_PORT}" -U "${PGU}" "$@"
}

# Same as pg_exec; kept for call sites that pass stdin, so they read as such.
pg_exec_i() {
  pg_exec "$@"
}
