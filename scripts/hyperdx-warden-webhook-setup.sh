#!/usr/bin/env bash
# =============================================================================
# HyperDX → warden webhook setup — idempotent, prod-only.
#
# Ensures a HyperDX generic webhook named "Warden ingest" exists, POSTing every
# alert transition (ALERT and OK) to warden's ingest door. The body template
# renders warden's `/ingest/hyperdx` contract {alert, state, message, url, value};
# the bearer goes in a write-only header. Create-or-update by NAME, like
# hyperdx-webhook-setup.sh. Alerts reference it by name (`channels` in
# observability/alerts/*.json) next to "Slack #alerts", which stays the
# human-readable mirror.
#
# Runs from the mini or the VPS host: secrets resolve through `secrets-run` when
# it exists (the mini's offline cache), else `op read`. Never prints the token,
# the access key or the URL's credentials.
#   op://vps/clickstack/AGENT_ACCESS_KEY  HyperDX user access key
#   op://vps/config/DOMAIN                HyperDX base host
#   op://mini/warden-ingest/token         the bearer (same value warden checks)
#
# Usage: make hyperdx-warden-webhook-setup
# =============================================================================
set -euo pipefail

WEBHOOK_NAME="Warden ingest"
INGEST_URL="${WARDEN_INGEST_URL:-https://warden-ingest.mini.jkrumm.com/ingest/hyperdx}"

read_secret() {
  local ref="$1" val
  if command -v secrets-run >/dev/null 2>&1; then
    val=$(secrets-run read "$ref" 2>/dev/null) || val=""
  else
    val=$(op read "$ref" 2>/dev/null) || val=""
  fi
  if [[ -z "$val" ]]; then
    echo "ERROR: could not read ${ref}" >&2
    exit 1
  fi
  printf '%s' "$val"
}

KEY="${HYPERDX_PROD_ACCESS_KEY:-$(read_secret op://vps/clickstack/AGENT_ACCESS_KEY)}"
BASE="https://hyperdx.$(read_secret op://vps/config/DOMAIN)"
TOKEN=$(read_secret op://mini/warden-ingest/token)

# `title` carries the alert's name (warden fingerprints it, digits stripped), `body` the detail line.
BODY=$(WEBHOOK_NAME="$WEBHOOK_NAME" INGEST_URL="$INGEST_URL" TOKEN="$TOKEN" python3 -c "
import json, os
template = '{\"alert\": \"{{title}}\", \"state\": \"{{state}}\", \"message\": \"{{body}}\", \"url\": \"{{link}}\", \"value\": \"{{value}}\"}'
print(json.dumps({
    'name': os.environ['WEBHOOK_NAME'],
    'service': 'generic',
    'url': os.environ['INGEST_URL'],
    'description': 'Alerts into warden /ingest/hyperdx (ops-signals Wave 15). Token header is write-only here.',
    'body': template,
    'headers': {'Authorization': 'Bearer ' + os.environ['TOKEN'], 'Content-Type': 'application/json'},
}))
")

EXISTING_ID=$(curl -fsS "${BASE}/api/api/v2/webhooks" -H "Authorization: Bearer ${KEY}" |
  WEBHOOK_NAME="$WEBHOOK_NAME" python3 -c "
import json, os, sys
data = json.load(sys.stdin).get('data', [])
match = next((w for w in data if w.get('name') == os.environ['WEBHOOK_NAME']), None)
print(match['id'] if match else '')
")

if [[ -n "$EXISTING_ID" ]]; then
  curl -fsS -X PUT "${BASE}/api/api/v2/webhooks/${EXISTING_ID}" \
    -H "Authorization: Bearer ${KEY}" -H "Content-Type: application/json" \
    --data-binary "$BODY" >/dev/null
  echo "webhook ok (${EXISTING_ID})"
else
  NEW_ID=$(curl -fsS -X POST "${BASE}/api/api/v2/webhooks" \
    -H "Authorization: Bearer ${KEY}" -H "Content-Type: application/json" \
    --data-binary "$BODY" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])")
  echo "webhook ok (${NEW_ID})"
fi
