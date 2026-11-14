#!/usr/bin/env bash
# =============================================================================
# Converge the LOCAL dev MariaDB root password onto .env.dev.tpl. Dev-only.
#
# Why this is needed at all
# -------------------------
# The image applies MARIADB_ROOT_PASSWORD ONLY when initializing an empty data
# directory; it is ignored on every subsequent start. So a volume created before the
# dev-only credentials existed keeps whatever password initialized it — silently.
# Nothing warns, the container comes up healthy, the healthcheck passes (it uses
# the unix socket). Only a TCP connection using the template's value fails.
#
# Postgres is not part of this any more: the mini's Postgres is the Homebrew server, whose
# superuser is the OS user over a 0700 socket (no password), and every app role's password
# is declared in dotfiles config/postgres/cluster.yaml (`make -C ~/SourceRoot/dotfiles pg-apply`).
#
# Usage:  make dev-db-passwords
#
# Required env (resolved by secrets-run run --env-file=.env.dev.tpl):
#   MARIADB_ROOT_PASSWORD
# =============================================================================
set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }

# --- MariaDB -----------------------------------------------------------------
# Deliberately NOT converged here, because it cannot be. MariaDB's root has no
# socket-trust equivalent (`docker exec mariadb mariadb -u root` returns
# ERROR 1045), so changing the password requires knowing the CURRENT one — which
# on a stale volume is prod's op://vps/mariadb/ROOT_PASSWORD, deliberately absent
# from this machine's cache. Fetching it here would defeat the entire point of
# the dev-only split.
#
# So: report accurately and name both routes. Do not "fix" this by caching the
# prod ref.
if ! docker inspect -f '{{.State.Status}}' mariadb >/dev/null 2>&1; then
  log "  · mariadb container not running — skipping its check"
  exit 0
fi

if docker exec -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" mariadb \
     mariadb -h 127.0.0.1 -u root -e "select 1" >/dev/null 2>&1; then
  log "  ✓ mariadb root already matches .env.dev.tpl — nothing to do"
  exit 0
fi

cat <<'EOF'

  ! mariadb root does NOT match .env.dev.tpl, and this script cannot fix it.
    Its volume predates the dev-only credentials, and changing a MariaDB
    password requires the current one — which is prod's, and is deliberately
    not cached on this machine.

    Two ways out, both fine:

      a) Recreate the volume (loses local FPP dev data, which is re-syncable):
           make down
           docker volume rm vps_mariadb-dev-data
           make up                  # re-inits with the dev-only password
           make fpp-sync-from-prod  # repopulate; needs no credential

      b) From the MacBook, where prod's password resolves:
           ALTER USER 'root'@'%' IDENTIFIED BY '<the dev-only password>';

EOF
exit 1
