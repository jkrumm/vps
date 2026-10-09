#!/usr/bin/env bash
# =============================================================================
# HyperDX agent user setup — idempotent, prod-only.
#
# Ensures a dedicated HyperDX user (AGENT_EMAIL) exists in the team and that
# its accessKey matches AGENT_ACCESS_KEY, so agents (Claude Code sessions,
# agent-gateway `otel`) can call the MCP server and REST v2 API without ever
# holding the human's password. Re-run after rotating any of the three
# 1Password fields — idempotent re-runs are no-ops beyond the smoke test.
#
# Requires (1Password `vps` vault, item "clickstack" — create these fields BY
# HAND first; the VPS service account has no write permission):
#   AGENT_EMAIL         e.g. hyperdx-agent@jkrumm.com
#   AGENT_PASSWORD      policy: 12-72 chars, upper + lower + digit + special
#   AGENT_ACCESS_KEY    a uuid v4, lowercase
#
# Usage: make hyperdx-agent-setup   (ENV=prod, runs on the VPS host)
# =============================================================================
set -euo pipefail

read_secret() {
  local field="$1" val
  if ! val=$(op read "op://vps/clickstack/${field}" 2>/dev/null); then
    echo "ERROR: could not read op://vps/clickstack/${field} — create this field in 1Password first (vps vault, item 'clickstack')." >&2
    exit 1
  fi
  printf '%s' "$val"
}

# Guards against JS-injection into the mongo --eval strings built below —
# every value interpolated there must pass through this first.
sanitize() {
  local val="$1"
  if [[ ! "$val" =~ ^[A-Za-z0-9@._-]+$ ]]; then
    echo "ERROR: unexpected characters in a value used inside a Mongo eval query" >&2
    exit 1
  fi
  printf '%s' "$val"
}

AGENT_EMAIL=$(read_secret AGENT_EMAIL)
AGENT_EMAIL=$(sanitize "$AGENT_EMAIL")
AGENT_PASSWORD=$(read_secret AGENT_PASSWORD)
AGENT_ACCESS_KEY=$(read_secret AGENT_ACCESS_KEY)
AGENT_ACCESS_KEY=$(sanitize "$AGENT_ACCESS_KEY")

DOMAIN=$(op read "op://vps/config/DOMAIN" 2>/dev/null) || {
  echo "ERROR: could not read op://vps/config/DOMAIN" >&2
  exit 1
}
BASE="https://hyperdx.${DOMAIN}"

mongo_eval() {
  docker exec clickstack mongo --quiet hyperdx --eval "$1"
}

# ---------------------------------------------------------------------------
# 1. Ensure the user exists. There is no admin endpoint that creates a second
#    user directly — go through the same invite + team-setup-token flow the
#    HyperDX UI uses for "invite a teammate".
# ---------------------------------------------------------------------------
EXISTING=$(mongo_eval "print(JSON.stringify(db.users.findOne({email:'${AGENT_EMAIL}'},{_id:1})))")

if [[ "$EXISTING" == "null" ]]; then
  TEAM_JSON=$(mongo_eval "print(JSON.stringify(db.teams.findOne({},{_id:1})))")
  if [[ "$TEAM_JSON" == "null" ]]; then
    echo "ERROR: no HyperDX team found — register the first (human) user via the UI first." >&2
    exit 1
  fi
  TEAM_ID=$(python3 -c "import json,sys; print(json.load(sys.stdin)['_id']['\$oid'])" <<<"$TEAM_JSON")

  TOKEN=$(openssl rand -hex 16)
  mongo_eval "db.teaminvites.insertOne({teamId: ObjectId('${TEAM_ID}'), email: '${AGENT_EMAIL}', token: '${TOKEN}', createdAt: new Date()})" >/dev/null

  # Password goes through an env var (not argv, not a bash-interpolated JSON
  # literal) and the request body through a heredoc (not a curl argv) so it
  # never appears in `ps`.
  BODY=$(AGENT_PW="$AGENT_PASSWORD" python3 -c "import json,os,sys; sys.stdout.write(json.dumps({'password': os.environ['AGENT_PW']}))")
  HTTP_CODE=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/api/team/setup/${TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @- <<EOF
$BODY
EOF
)
  if [[ "$HTTP_CODE" != "303" ]]; then
    echo "ERROR: POST /api/team/setup/<token> returned HTTP ${HTTP_CODE} (expected 303)" >&2
    exit 1
  fi

  EXISTING=$(mongo_eval "print(JSON.stringify(db.users.findOne({email:'${AGENT_EMAIL}'},{_id:1})))")
  if [[ "$EXISTING" == "null" ]]; then
    echo "ERROR: user still missing after the team-setup POST" >&2
    exit 1
  fi
fi
echo "user ok"

# ---------------------------------------------------------------------------
# 2. Force accessKey to the 1Password value. Idempotent — safe to re-run
#    even when it already matches.
# ---------------------------------------------------------------------------
mongo_eval "db.users.updateOne({email:'${AGENT_EMAIL}'},{\$set:{accessKey:'${AGENT_ACCESS_KEY}'}})" >/dev/null
CURRENT=$(mongo_eval "print(JSON.stringify(db.users.findOne({email:'${AGENT_EMAIL}'},{accessKey:1,_id:0})))")
if [[ "$CURRENT" != *"\"accessKey\":\"${AGENT_ACCESS_KEY}\""* ]]; then
  echo "ERROR: accessKey update did not take effect" >&2
  exit 1
fi
echo "accessKey ok"

# ---------------------------------------------------------------------------
# 3. Smoke test — MCP initialize.
# ---------------------------------------------------------------------------
RESP=$(curl -fsS -X POST "${BASE}/api/mcp" \
  -H "Authorization: Bearer ${AGENT_ACCESS_KEY}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"vps-agent-setup","version":"1.0.0"}}}')

python3 -c "
import json, sys
resp = sys.stdin.read()
line = next((l for l in resp.splitlines() if l.startswith('data: ')), None)
if not line:
    print('ERROR: no MCP data line in response', file=sys.stderr)
    sys.exit(1)
info = json.loads(line[6:]).get('result', {}).get('serverInfo', {})
print(f\"MCP serverInfo: {info.get('name')} {info.get('version')}\")
" <<<"$RESP"
