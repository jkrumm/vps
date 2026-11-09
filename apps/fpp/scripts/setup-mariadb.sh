#!/usr/bin/env bash
set -euo pipefail

# Idempotent MariaDB schema + user setup for FPP.
# Runs against the running mariadb container.
# Run via: make fpp-mariadb-setup
# Requires: mariadb container running, 1Password secrets in env via op run.

# shellcheck disable=SC2120 # "$@" is optional passthrough
mariadb_root() {
  docker exec -i \
    -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" \
    mariadb mariadb -u root "$@"
}

echo "==> Setting up MariaDB schema and user for FPP..."

# ---------------------------------------------------------------------------
# Free Planning Poker — database: ${MARIADB_DB}, user: fpp@'%'
# - REQUIRE SSL on the user enforces TLS even if --require-secure-transport
#   were ever relaxed (defense in depth).
# - Wildcard host ('%') because Vercel functions don't have stable egress IPs.
# - ALL PRIVILEGES on the single FPP database — Drizzle migrations need
#   CREATE/ALTER/DROP/INDEX. Scoped to one database, not server-wide.
# ---------------------------------------------------------------------------
echo "--> ${MARIADB_DB} / fpp"

mariadb_root <<SQL
CREATE DATABASE IF NOT EXISTS \`${MARIADB_DB}\`
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'fpp'@'%' IDENTIFIED BY '${MARIADB_FPP_PASSWORD}'
  REQUIRE SSL;

-- Sync password and TLS requirement on every run (rotation-safe)
ALTER USER 'fpp'@'%' IDENTIFIED BY '${MARIADB_FPP_PASSWORD}'
  REQUIRE SSL;

GRANT ALL PRIVILEGES ON \`${MARIADB_DB}\`.* TO 'fpp'@'%';

FLUSH PRIVILEGES;
SQL

echo "==> MariaDB setup complete."
