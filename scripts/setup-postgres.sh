#!/usr/bin/env bash
set -euo pipefail

# Idempotent Postgres schema + user setup.
# Runs against the main Postgres database (${POSTGRES_DB}).
# Each app gets its own schema and a dedicated user with schema-only access.
# Run via: make postgres-setup
# Requires: postgres container running, 1Password secrets in environment via op run.

psql_main() {
  docker exec -i postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" "$@"
}

echo "==> Setting up Postgres schemas and users..."

# ---------------------------------------------------------------------------
# Umami analytics — schema: umami, user: umami
# ---------------------------------------------------------------------------
echo "--> umami"

psql_main <<SQL
-- Create schema if not exists
CREATE SCHEMA IF NOT EXISTS umami;

-- pgcrypto must be created by superuser; place it in umami schema so Prisma
-- migration's "CREATE EXTENSION IF NOT EXISTS pgcrypto" finds it there
CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA umami;

-- Create role if not exists, always sync password (for secret rotations)
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'umami') THEN
    CREATE ROLE umami WITH LOGIN PASSWORD '${UMAMI_DB_PASSWORD}';
  ELSE
    ALTER ROLE umami WITH PASSWORD '${UMAMI_DB_PASSWORD}';
  END IF;
END
\$\$;

-- Grant database connect
GRANT CONNECT ON DATABASE "${POSTGRES_DB}" TO umami;

-- Grant schema access (no access to public schema)
GRANT USAGE, CREATE ON SCHEMA umami TO umami;

-- Grants on existing + future objects in umami schema
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA umami TO umami;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA umami TO umami;
ALTER DEFAULT PRIVILEGES IN SCHEMA umami GRANT ALL ON TABLES TO umami;
ALTER DEFAULT PRIVILEGES IN SCHEMA umami GRANT ALL ON SEQUENCES TO umami;
SQL

# ---------------------------------------------------------------------------
# basalt-ui-playground — schema: basalt_ui_playground, user: basalt_ui_playground
# ---------------------------------------------------------------------------
echo "--> basalt_ui_playground"

psql_main <<SQL
CREATE SCHEMA IF NOT EXISTS basalt_ui_playground;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'basalt_ui_playground') THEN
    CREATE ROLE basalt_ui_playground WITH LOGIN PASSWORD '${BASALT_UI_PLAYGROUND_DB_PASSWORD}';
  ELSE
    ALTER ROLE basalt_ui_playground WITH PASSWORD '${BASALT_UI_PLAYGROUND_DB_PASSWORD}';
  END IF;
END
\$\$;

GRANT CONNECT ON DATABASE "${POSTGRES_DB}" TO basalt_ui_playground;
-- Required for drizzle-kit migrate: it runs CREATE SCHEMA IF NOT EXISTS internally,
-- and PG checks CREATE ON DATABASE before the IF NOT EXISTS short-circuit.
GRANT CREATE ON DATABASE "${POSTGRES_DB}" TO basalt_ui_playground;
GRANT USAGE, CREATE ON SCHEMA basalt_ui_playground TO basalt_ui_playground;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA basalt_ui_playground TO basalt_ui_playground;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA basalt_ui_playground TO basalt_ui_playground;
ALTER DEFAULT PRIVILEGES IN SCHEMA basalt_ui_playground GRANT ALL ON TABLES TO basalt_ui_playground;
ALTER DEFAULT PRIVILEGES IN SCHEMA basalt_ui_playground GRANT ALL ON SEQUENCES TO basalt_ui_playground;
SQL

# ---------------------------------------------------------------------------
# argo — schema: argo, user: argo
# ---------------------------------------------------------------------------
echo "--> argo"

psql_main <<SQL
CREATE SCHEMA IF NOT EXISTS argo;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'argo') THEN
    CREATE ROLE argo WITH LOGIN PASSWORD '${ARGO_DB_PASSWORD}';
  ELSE
    ALTER ROLE argo WITH PASSWORD '${ARGO_DB_PASSWORD}';
  END IF;
END
\$\$;

GRANT CONNECT ON DATABASE "${POSTGRES_DB}" TO argo;
-- Required for migration tools (drizzle-kit / prisma) that run CREATE SCHEMA IF NOT EXISTS
-- internally — PG checks CREATE ON DATABASE before the IF NOT EXISTS short-circuit.
GRANT CREATE ON DATABASE "${POSTGRES_DB}" TO argo;
GRANT USAGE, CREATE ON SCHEMA argo TO argo;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA argo TO argo;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA argo TO argo;
ALTER DEFAULT PRIVILEGES IN SCHEMA argo GRANT ALL ON TABLES TO argo;
ALTER DEFAULT PRIVILEGES IN SCHEMA argo GRANT ALL ON SEQUENCES TO argo;
SQL

# ---------------------------------------------------------------------------
# shutterflow — schema: shutterflow, user: shutterflow
# Guarded: the local dev stack does not provision it (shutterflow runs its own dev Postgres,
# so .env.dev.tpl carries no SHUTTERFLOW_DB_PASSWORD) — skip instead of failing under set -u.
# ---------------------------------------------------------------------------
if [ -n "${SHUTTERFLOW_DB_PASSWORD:-}" ]; then
echo "--> shutterflow"

psql_main <<SQL
CREATE SCHEMA IF NOT EXISTS shutterflow;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'shutterflow') THEN
    CREATE ROLE shutterflow WITH LOGIN PASSWORD '${SHUTTERFLOW_DB_PASSWORD}';
  ELSE
    ALTER ROLE shutterflow WITH PASSWORD '${SHUTTERFLOW_DB_PASSWORD}';
  END IF;
END
\$\$;

GRANT CONNECT ON DATABASE "${POSTGRES_DB}" TO shutterflow;
-- Required for drizzle migrate: its migration runs CREATE SCHEMA IF NOT EXISTS, and PG checks
-- CREATE ON DATABASE before the IF NOT EXISTS short-circuit.
GRANT CREATE ON DATABASE "${POSTGRES_DB}" TO shutterflow;
GRANT USAGE, CREATE ON SCHEMA shutterflow TO shutterflow;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA shutterflow TO shutterflow;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA shutterflow TO shutterflow;
ALTER DEFAULT PRIVILEGES IN SCHEMA shutterflow GRANT ALL ON TABLES TO shutterflow;
ALTER DEFAULT PRIVILEGES IN SCHEMA shutterflow GRANT ALL ON SEQUENCES TO shutterflow;
SQL
else
echo "--> shutterflow (skipped: SHUTTERFLOW_DB_PASSWORD not set — prod-only schema)"
fi

# ---------------------------------------------------------------------------
# Future apps: add blocks here following the same pattern.
#
# Migration journals: each drizzle-kit app must keep its journal in its OWN
# schema (set `migrations: { schema: '<app>' }` in drizzle.config.ts), not the
# default shared `drizzle` schema. Then the role that owns the schema owns its
# journal — no cross-app collision, no extra grants needed here.
# ---------------------------------------------------------------------------

echo "==> Postgres setup complete."
