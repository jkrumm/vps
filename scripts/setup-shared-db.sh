#!/usr/bin/env bash
# =============================================================================
# Idempotent provisioning of the mini's `shared` database + the read-only Argo
# role on `agent_workflows`. Dev host only (docs/mini-postgres.md → "shared").
# Run via: make db-shared   (secrets arrive through secrets-run + .env.dev.tpl)
#
# `shared` = one login role per writer, each OWNING its own schema (role name ==
# schema name) and every object it creates there, each with its own connection
# limit. Roles cannot see each other's schemas; the only cross-schema access is
# the SHARED_READS table below. PUBLIC cannot connect to the database.
#
# Adding a writer (software-factory F1 etc.) = ONE row in WRITERS, a password
# ref in .env.dev.tpl (+ the op field and headless.refs first, see the docs),
# then `make db-shared`. Rows for a writer whose password env is unset are
# skipped, so the script never fails under `set -u` on a machine without it.
#
# Passwords reach the server through the container environment (`docker exec -e
# NAME`, value never in argv) and psql's `\set pw `printenv``, and are quoted by
# the server's format(%L) — never spliced into SQL text.
#
# Ends with assertions that FAIL the script on any miss (real logins over TCP
# from the host, so pg_hba's scram path is exercised, not the in-container
# loopback trust rule).
# =============================================================================
set -euo pipefail

# --- Configuration: the whole change for a new writer is one row here --------
# role (= schema) | connection limit | password env var
WRITERS=(
  "usage|10|SHARED_USAGE_DB_PASSWORD"
  "argo|20|ARGO_DB_PASSWORD"
)
# reader|owner — reader gets USAGE + SELECT (now and for future tables) on owner's schema
SHARED_READS=(
  "argo|usage"
)
SHARED_DB=shared
# Read-only role on the agent_workflows database (not a writer: owns nothing).
RO_ROLE=argo_agw_ro
RO_DB=agent_workflows
RO_LIMIT=5
RO_PW_ENV=ARGO_AGW_RO_DB_PASSWORD
# -----------------------------------------------------------------------------

# Homebrew psql (the TCP assertions run from the host); launchd/minimal PATH safe.
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"

PGHOST_TCP=127.0.0.1
PGPORT_TCP=5432

psql_su() { # psql_su <db> [psql args...]; SQL on stdin; $PW_VALUE (if set) is passed by name
  local db="$1"; shift
  docker exec -i -e PW_VALUE postgres \
    psql -X -U "${POSTGRES_USER}" -d "${db}" -v ON_ERROR_STOP=1 "$@"
}

su_q() { psql_su "$1" -qAt -c "$2"; } # su_q <db> <sql> — one-shot superuser query

row_field() { # row_field "<a|b|c>" <1-based index>
  echo "$1" | cut -d'|' -f"$2"
}

pwenv_of() { # pwenv_of <writer role> -> its password env var name
  local row
  for row in "${WRITERS[@]}"; do
    [ "$(row_field "${row}" 1)" = "$1" ] && { row_field "${row}" 3; return; }
  done
  return 1
}

is_provisioned() { # is_provisioned <env var name>
  [ -n "${!1:-}" ]
}

# Validate the table once: identifiers and limits are interpolated by psql/format, so keep them tame.
for row in "${WRITERS[@]}"; do
  [[ "$(row_field "${row}" 1)" =~ ^[a-z_][a-z0-9_]*$ ]] || { echo "ERROR: bad writer role in '${row}'"; exit 1; }
  [[ "$(row_field "${row}" 2)" =~ ^[0-9]+$ ]] || { echo "ERROR: bad connection limit in '${row}'"; exit 1; }
  [[ "$(row_field "${row}" 3)" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "ERROR: bad password env in '${row}'"; exit 1; }
done

[ -n "${POSTGRES_USER:-}" ] || { echo "ERROR: POSTGRES_USER not set (run via make db-shared)"; exit 1; }
[[ "$(docker inspect -f '{{.State.Status}}' postgres 2>/dev/null)" == "running" ]] || {
  echo "ERROR: local 'postgres' container not running."; exit 1; }

echo "==> Setting up the ${SHARED_DB} database..."

# ---------------------------------------------------------------------------
# Database: created if missing, owner = the superuser, closed to PUBLIC.
# ---------------------------------------------------------------------------
echo "--> database ${SHARED_DB}"
psql_su "${POSTGRES_DB:-postgres}" -v db="${SHARED_DB}" <<'SQL'
-- CREATE DATABASE cannot run inside a DO block: generate it and gexec it.
SELECT format('CREATE DATABASE %I', :'db')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db')
\gexec

REVOKE CONNECT ON DATABASE :"db" FROM PUBLIC;
SQL
psql_su "${SHARED_DB}" <<'SQL'
REVOKE ALL ON SCHEMA public FROM PUBLIC;
SQL

# ---------------------------------------------------------------------------
# Writers: login role + own schema + own connection limit + own search_path.
# ---------------------------------------------------------------------------
for row in "${WRITERS[@]}"; do
  role=$(row_field "${row}" 1)
  limit=$(row_field "${row}" 2)
  pwvar=$(row_field "${row}" 3)

  if ! is_provisioned "${pwvar}"; then
    echo "--> ${role} (skipped: ${pwvar} not set)"
    continue
  fi
  echo "--> ${role} (schema ${role}, connection limit ${limit})"

  PW_VALUE="${!pwvar}" psql_su "${SHARED_DB}" -v role="${role}" -v limit="${limit}" -v db="${SHARED_DB}" <<'SQL'
\set pw `printenv PW_VALUE`

SELECT format('%s ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE CONNECTION LIMIT %s PASSWORD %L',
              CASE WHEN EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') THEN 'ALTER' ELSE 'CREATE' END,
              :'role', :limit, :'pw')
\gexec

GRANT CONNECT ON DATABASE :"db" TO :"role";
CREATE SCHEMA IF NOT EXISTS :"role" AUTHORIZATION :"role";
ALTER SCHEMA :"role" OWNER TO :"role";
REVOKE ALL ON SCHEMA :"role" FROM PUBLIC;
ALTER ROLE :"role" IN DATABASE :"db" SET search_path = :"role";
SQL
done

# ---------------------------------------------------------------------------
# Cross-schema reads: the only way one writer sees another's schema.
# Applied only when both roles and the owner's schema exist (a skipped writer
# leaves its pair for the run that has both).
# ---------------------------------------------------------------------------
for pair in "${SHARED_READS[@]}"; do
  reader=$(row_field "${pair}" 1)
  owner=$(row_field "${pair}" 2)
  echo "--> ${reader} reads schema ${owner}"

  psql_su "${SHARED_DB}" -v reader="${reader}" -v owner="${owner}" <<'SQL'
SELECT EXISTS (SELECT FROM pg_roles WHERE rolname = :'reader')
   AND EXISTS (SELECT FROM pg_roles WHERE rolname = :'owner')
   AND EXISTS (SELECT FROM pg_namespace WHERE nspname = :'owner') AS ready
\gset

\if :ready
  GRANT USAGE ON SCHEMA :"owner" TO :"reader";
  GRANT SELECT ON ALL TABLES IN SCHEMA :"owner" TO :"reader";
  ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA :"owner" GRANT SELECT ON TABLES TO :"reader";
\else
  \echo   (skipped: reader, owner or the owner schema does not exist yet)
\endif
SQL
done

# ---------------------------------------------------------------------------
# argo_agw_ro — read-only on agent_workflows. Not pg_read_all_data (that is
# cluster-wide): USAGE on every non-system schema + SELECT on its tables and
# sequences, and default privileges so what the owner creates later stays
# readable (agent_workflows creates schemas at runtime). The grantor for the
# defaults is the REAL owner of the database, looked up, not assumed.
# ---------------------------------------------------------------------------
if is_provisioned "${RO_PW_ENV}"; then
  if [ "$(su_q "${POSTGRES_DB:-postgres}" "SELECT count(*) FROM pg_database WHERE datname = '${RO_DB}'")" != "1" ]; then
    echo "--> ${RO_ROLE} (skipped: database ${RO_DB} does not exist yet — run make postgres-setup first)"
  else
    echo "--> ${RO_ROLE} (read-only on ${RO_DB}, connection limit ${RO_LIMIT})"
    PW_VALUE="${!RO_PW_ENV}" psql_su "${RO_DB}" -v role="${RO_ROLE}" -v limit="${RO_LIMIT}" -v db="${RO_DB}" <<'SQL'
\set pw `printenv PW_VALUE`

SELECT format('%s ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE CONNECTION LIMIT %s PASSWORD %L',
              CASE WHEN EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') THEN 'ALTER' ELSE 'CREATE' END,
              :'role', :limit, :'pw')
\gexec

GRANT CONNECT ON DATABASE :"db" TO :"role";

SELECT pg_get_userbyid(datdba) AS owner FROM pg_database WHERE datname = :'db'
\gset

-- Existing objects. Schemas can vanish between the list and the grant (the app's test
-- suites create and drop schemas), so a missing one is skipped, not fatal.
SELECT set_config('shared.ro_role', :'role', false) \g /dev/null
DO $$
DECLARE s name;
BEGIN
  FOR s IN SELECT nspname FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' LOOP
    BEGIN
      EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I', s, current_setting('shared.ro_role'));
      EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', s, current_setting('shared.ro_role'));
      EXECUTE format('GRANT SELECT ON ALL SEQUENCES IN SCHEMA %I TO %I', s, current_setting('shared.ro_role'));
    EXCEPTION WHEN invalid_schema_name THEN
      NULL;
    END;
  END LOOP;
END
$$;

-- Future objects the owner creates (no IN SCHEMA: covers schemas that do not exist yet).
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" GRANT USAGE ON SCHEMAS TO :"role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" GRANT SELECT ON TABLES TO :"role";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" GRANT SELECT ON SEQUENCES TO :"role";
SQL
  fi
else
  echo "--> ${RO_ROLE} (skipped: ${RO_PW_ENV} not set)"
fi

# ---------------------------------------------------------------------------
# Assertions. Real logins over TCP from the host with the real passwords
# (PGPASSWORD in the process environment, never argv). Any miss fails the run.
# ---------------------------------------------------------------------------
echo "==> Verifying..."
command -v psql >/dev/null 2>&1 || { echo "ERROR: host psql not found (brew install postgresql@18) — the TCP login assertions need it"; exit 1; }

FAILED=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; FAILED=1; }

pg_as() { # pg_as <role> <db> <password env var name> <sql>
  PGPASSWORD="${!3}" PGCONNECT_TIMEOUT=10 \
    psql -X -qAt -h "${PGHOST_TCP}" -p "${PGPORT_TCP}" -U "$1" -d "$2" -v ON_ERROR_STOP=1 -c "$4"
}

expect_eq() { # expect_eq <description> <expected> <command...>
  local desc="$1" want="$2" got; shift 2
  if got=$("$@" 2>&1) && [ "${got}" = "${want}" ]; then pass "${desc}"; else fail "${desc} (want '${want}', got '${got}')"; fi
}
expect_ok() { # expect_ok <description> <command...>
  local desc="$1" out; shift
  if out=$("$@" 2>&1); then pass "${desc}"; else fail "${desc}: ${out}"; fi
}
expect_denied() { # expect_denied <description> <command...> — must fail with a permission error
  local desc="$1" out; shift
  if out=$("$@" 2>&1); then fail "${desc} (unexpectedly allowed)"; return; fi
  if echo "${out}" | grep -qi 'permission denied'; then pass "${desc}"; else fail "${desc} (failed, but not on permissions: ${out})"; fi
}

SCRATCH=_assert_tmp
cleanup() {
  local row
  for row in "${WRITERS[@]}"; do
    su_q "${SHARED_DB}" "DROP TABLE IF EXISTS \"$(row_field "${row}" 1)\".${SCRATCH}" >/dev/null 2>&1 || true
  done
  su_q "${RO_DB}" "DROP SCHEMA IF EXISTS ${SCRATCH} CASCADE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# PUBLIC has no CONNECT on the database (ACL, not just behaviour)
expect_eq "PUBLIC has no CONNECT on ${SHARED_DB}" "t" su_q "${POSTGRES_DB:-postgres}" \
  "SELECT NOT EXISTS (SELECT FROM pg_database d, aclexplode(coalesce(d.datacl, acldefault('d', d.datdba))) a
                      WHERE d.datname = '${SHARED_DB}' AND a.grantee = 0 AND a.privilege_type = 'CONNECT')"

for row in "${WRITERS[@]}"; do
  role=$(row_field "${row}" 1); limit=$(row_field "${row}" 2); pwvar=$(row_field "${row}" 3)
  is_provisioned "${pwvar}" || { echo "  - ${role}: skipped (not provisioned)"; continue; }

  expect_eq "${role}: logs in to ${SHARED_DB}, current_schema() = ${role}" "${role}" pg_as "${role}" "${SHARED_DB}" "${pwvar}" "SELECT current_schema()"
  expect_eq "${role}: connection limit ${limit}, not superuser/createdb/createrole" "${limit}|true" su_q "${SHARED_DB}" \
    "SELECT rolconnlimit || '|' || (NOT (rolsuper OR rolcreatedb OR rolcreaterole) AND rolcanlogin) FROM pg_roles WHERE rolname = '${role}'"
  expect_eq "${role}: owns its schema" "${role}" su_q "${SHARED_DB}" \
    "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = '${role}'"
  expect_ok "${role}: can CREATE TABLE in schema ${role}" pg_as "${role}" "${SHARED_DB}" "${pwvar}" "CREATE TABLE ${SCRATCH} (id int); DROP TABLE ${SCRATCH}"

  for other in "${WRITERS[@]}"; do
    other_role=$(row_field "${other}" 1)
    [ "${other_role}" = "${role}" ] && continue
    expect_denied "${role}: cannot CREATE TABLE in schema ${other_role}" pg_as "${role}" "${SHARED_DB}" "${pwvar}" "CREATE TABLE \"${other_role}\".${SCRATCH} (id int)"
  done
done

for pair in "${SHARED_READS[@]}"; do
  reader=$(row_field "${pair}" 1); owner=$(row_field "${pair}" 2)
  rpw=$(pwenv_of "${reader}"); opw=$(pwenv_of "${owner}")
  if ! is_provisioned "${rpw}" || ! is_provisioned "${opw}"; then
    echo "  - ${reader} reads ${owner}: skipped (not both provisioned)"; continue
  fi
  # the table is created AFTER the grants ran, so this also proves the default privileges
  expect_ok "${owner}: creates ${owner}.${SCRATCH} with a row" pg_as "${owner}" "${SHARED_DB}" "${opw}" "CREATE TABLE ${SCRATCH} (id int); INSERT INTO ${SCRATCH} VALUES (1)"
  expect_eq "${reader}: can SELECT a table created by ${owner}" "1" pg_as "${reader}" "${SHARED_DB}" "${rpw}" "SELECT count(*) FROM \"${owner}\".${SCRATCH}"
  expect_denied "${reader}: cannot INSERT into ${owner}.${SCRATCH}" pg_as "${reader}" "${SHARED_DB}" "${rpw}" "INSERT INTO \"${owner}\".${SCRATCH} VALUES (2)"
  expect_denied "${reader}: cannot CREATE TABLE in schema ${owner}" pg_as "${reader}" "${SHARED_DB}" "${rpw}" "CREATE TABLE \"${owner}\".${SCRATCH}_2 (id int)"
  su_q "${SHARED_DB}" "DROP TABLE IF EXISTS \"${owner}\".${SCRATCH}" >/dev/null
done

if is_provisioned "${RO_PW_ENV}" && [ "$(su_q "${POSTGRES_DB:-postgres}" "SELECT count(*) FROM pg_database WHERE datname = '${RO_DB}'")" = "1" ]; then
  expect_eq "${RO_ROLE}: logs in to ${RO_DB} over TCP" "${RO_ROLE}" pg_as "${RO_ROLE}" "${RO_DB}" "${RO_PW_ENV}" "SELECT current_user"
  expect_eq "${RO_ROLE}: connection limit ${RO_LIMIT}, no superuser/createdb/createrole" "${RO_LIMIT}|true" su_q "${RO_DB}" \
    "SELECT rolconnlimit || '|' || (NOT (rolsuper OR rolcreatedb OR rolcreaterole) AND rolcanlogin) FROM pg_roles WHERE rolname = '${RO_ROLE}'"
  expect_eq "${RO_ROLE}: not a member of any role" "0" su_q "${RO_DB}" \
    "SELECT count(*) FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.member WHERE r.rolname = '${RO_ROLE}'"

  # an existing table, whatever the app has created
  existing=$(su_q "${RO_DB}" "SELECT format('%I.%I', schemaname, tablename) FROM pg_tables
                              WHERE schemaname !~ '^pg_' AND schemaname <> 'information_schema' ORDER BY (schemaname = 'agw') DESC, 1 LIMIT 1")
  if [ -n "${existing}" ]; then
    expect_ok "${RO_ROLE}: can SELECT an existing table (${existing})" pg_as "${RO_ROLE}" "${RO_DB}" "${RO_PW_ENV}" "SELECT count(*) FROM ${existing}"
    expect_denied "${RO_ROLE}: cannot DELETE from ${existing}" pg_as "${RO_ROLE}" "${RO_DB}" "${RO_PW_ENV}" "DELETE FROM ${existing}"
  else
    echo "  - ${RO_DB} has no tables yet: existing-table read checks skipped"
  fi

  # an object the owner creates NOW must be readable without re-running this script (default privileges)
  ro_owner=$(su_q "${RO_DB}" "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${RO_DB}'")
  expect_ok "${ro_owner}: creates scratch schema ${SCRATCH} with a table" psql_su "${RO_DB}" -qAt \
    -c "SET ROLE \"${ro_owner}\"; CREATE SCHEMA ${SCRATCH}; CREATE TABLE ${SCRATCH}.t (id int); INSERT INTO ${SCRATCH}.t VALUES (1)"
  expect_eq "${RO_ROLE}: can SELECT a table in a schema created after the grants" "1" pg_as "${RO_ROLE}" "${RO_DB}" "${RO_PW_ENV}" "SELECT count(*) FROM ${SCRATCH}.t"
  expect_denied "${RO_ROLE}: cannot INSERT into ${SCRATCH}.t" pg_as "${RO_ROLE}" "${RO_DB}" "${RO_PW_ENV}" "INSERT INTO ${SCRATCH}.t VALUES (2)"
  expect_denied "${RO_ROLE}: cannot CREATE TABLE in schema ${SCRATCH}" pg_as "${RO_ROLE}" "${RO_DB}" "${RO_PW_ENV}" "CREATE TABLE ${SCRATCH}.t2 (id int)"
  expect_denied "${RO_ROLE}: cannot CREATE TABLE in public" pg_as "${RO_ROLE}" "${RO_DB}" "${RO_PW_ENV}" "CREATE TABLE public.${SCRATCH} (id int)"
  expect_denied "${RO_ROLE}: cannot CREATE SCHEMA" pg_as "${RO_ROLE}" "${RO_DB}" "${RO_PW_ENV}" "CREATE SCHEMA ${SCRATCH}_x"
  expect_denied "${RO_ROLE}: cannot connect to ${SHARED_DB} (no CONNECT via PUBLIC)" pg_as "${RO_ROLE}" "${SHARED_DB}" "${RO_PW_ENV}" "SELECT 1"
else
  echo "  - ${RO_ROLE}: skipped (not provisioned)"
fi

cleanup
if [ "${FAILED}" -ne 0 ]; then
  echo "==> ${SHARED_DB} verification FAILED." >&2
  exit 1
fi
echo "==> ${SHARED_DB} setup complete, all assertions passed."
