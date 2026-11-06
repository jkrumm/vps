#!/usr/bin/env bash
# =============================================================================
# HyperDX ntfy webhook setup — idempotent, prod-only.
#
# Ensures a HyperDX webhook named "ntfy alerts" (service `generic`) exists: it
# POSTs to https://ntfy.<DOMAIN>/alerts with `Authorization: Bearer <token>`
# (token from op://common/ntfy/TOKEN) and a body template that becomes the
# ntfy message. HyperDX templates only the body, not header values (a `{{title}}`
# header arrives literally) and `{{body}}` holds escaped `\n` sequences, so the
# Title is static and the body is built from the plain fields. Create-or-update by NAME: a PUT re-applies URL, headers and
# body (headers are write-only in HyperDX, so there is nothing to diff — every
# run PUTs). Run this before `make hyperdx-apply` — alerts-as-code
# (scripts/hyperdx-sync.sh) resolves a `channels[].webhook` reference against
# this webhook by name.
#
# Access key: $HYPERDX_PROD_ACCESS_KEY if set, else `op read
# op://vps/clickstack/AGENT_ACCESS_KEY` (same user provisioned by
# hyperdx-agent-setup.sh). Base URL: https://hyperdx.<DOMAIN> from
# op://vps/config/DOMAIN. Never prints the ntfy token or the access key; the
# base URL of ntfy is derived from DOMAIN, never written into the repo.
#
# Usage: make hyperdx-webhook-setup   (ENV=prod, runs on the VPS host)
# =============================================================================
set -euo pipefail

WEBHOOK_NAME="ntfy alerts"

read_secret() {
  local ref="$1" hint="$2" val
  if ! val=$(op read "$ref" 2>/dev/null); then
    echo "ERROR: could not read ${ref} — ${hint}" >&2
    exit 1
  fi
  printf '%s' "$val"
}

if [[ -n "${HYPERDX_PROD_ACCESS_KEY:-}" ]]; then
  KEY="$HYPERDX_PROD_ACCESS_KEY"
else
  KEY=$(read_secret "op://vps/clickstack/AGENT_ACCESS_KEY" "run 'make hyperdx-agent-setup' first.")
fi

DOMAIN=$(read_secret "op://vps/config/DOMAIN" "check the vps vault's 'config' item.")
BASE="https://hyperdx.${DOMAIN}"

NTFY_TOKEN=$(read_secret "op://common/ntfy/TOKEN" "check the common vault's 'ntfy' item.")

BODY=$(WEBHOOK_NAME="$WEBHOOK_NAME" NTFY_URL="https://ntfy.${DOMAIN}/alerts" NTFY_TOKEN="$NTFY_TOKEN" python3 -c "
import json, os
print(json.dumps({
    'name': os.environ['WEBHOOK_NAME'],
    'service': 'generic',
    'url': os.environ['NTFY_URL'],
    'description': 'ntfy topic alerts; token header is write-only here, value in op://common/ntfy/TOKEN (make hyperdx-webhook-setup).',
    'headers': {
        'Authorization': 'Bearer ' + os.environ['NTFY_TOKEN'],
        'Title': 'HyperDX alert',
        'Priority': 'high',
        'Tags': 'rotating_light',
    },
    'body': '{{title}}\n{{state}}: {{value}} vs threshold {{threshold}}\n{{startTimeISO}} to {{endTimeISO}}\n{{link}}',
}))
")

EXISTING=$(curl -fsS "${BASE}/api/api/v2/webhooks" -H "Authorization: Bearer ${KEY}")
EXISTING_ID=$(WEBHOOK_NAME="$WEBHOOK_NAME" python3 -c "
import json, os, sys
name = os.environ['WEBHOOK_NAME']
data = json.loads(sys.stdin.read()).get('data', [])
match = next((w for w in data if w.get('name') == name), None)
print(match['id'] if match else '')
" <<<"$EXISTING")

if [[ -n "$EXISTING_ID" ]]; then
  curl -fsS -X PUT "${BASE}/api/api/v2/webhooks/${EXISTING_ID}" \
    -H "Authorization: Bearer ${KEY}" \
    -H "Content-Type: application/json" \
    --data-binary "$BODY" >/dev/null
  echo "webhook ok (${EXISTING_ID})"
else
  RESP=$(curl -fsS -X POST "${BASE}/api/api/v2/webhooks" \
    -H "Authorization: Bearer ${KEY}" \
    -H "Content-Type: application/json" \
    --data-binary "$BODY")
  NEW_ID=$(python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])" <<<"$RESP")
  echo "webhook ok (${NEW_ID})"
fi
