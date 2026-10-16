#!/usr/bin/env bash
# =============================================================================
# HyperDX dashboards + alerts as code — REST v2, both envs.
#
# Mongo (the dashboard/alert store) has no backup — observability/dashboards/
# and observability/alerts/ ARE the backup. `export` pulls every dashboard and
# alert down; `apply` validates (dashboards only — alerts have no /validate
# endpoint) and upserts (by NAME — HyperDX ids are per-env Mongo ObjectIds and
# don't round-trip) from those files back into an env, dashboards first, then
# alerts.
#
# Usage:
#   scripts/hyperdx-sync.sh export <dev|prod>
#   scripts/hyperdx-sync.sh apply  <dev|prod> [file ...]   # default: every
#                                                            # *.json in
#                                                            # observability/dashboards/
#                                                            # plus every
#                                                            # *.json in
#                                                            # observability/alerts/
#
# Env/key resolution:
#   dev  → ~/.config/hyperdx/local.env (HYPERDX_LOCAL_ACCESS_KEY), base
#          http://localhost:7707
#   prod → $HYPERDX_PROD_ACCESS_KEY if set, else `secrets-run read
#          op://vps/clickstack/AGENT_ACCESS_KEY` if secrets-run exists, else
#          `op read op://vps/clickstack/AGENT_ACCESS_KEY`. Base URL follows
#          the same ladder via $HYPERDX_PROD_BASE_URL / op://vps/config/DOMAIN.
#
# Alert files reference env-specific ids by NAME instead: `dashboardId` +
# `tileId` become `dashboard`/`tile` (tile title, i.e. the tile's own `name`),
# `savedSearchId` becomes `savedSearch`, and `channel.webhookId` becomes
# `channels[].webhook` (the singular `channel` mirrors `channels[0]` and is
# not stored). `apply` resolves those names back into ids via
# GET /dashboards, /saved-searches, /webhooks and fails with a clear message
# naming the unresolved reference. Run `make hyperdx-webhook-setup` before
# applying any alert that references a webhook by name.
#
# Dashboard tiles carry the same problem one level down: a tile's `sourceId`
# (and a table tile's row-click search target, when it points at a source)
# are per-env ids too. Both get swapped for the source NAME on export and
# resolved back via GET /sources on apply, failing clearly on an unknown
# source name. A SQL tile's `config.connectionId` gets the same treatment via
# GET /connections, swapped for `connection` (name) on export and resolved
# back on apply, failing clearly on an unknown connection name.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DASH_DIR="${REPO_ROOT}/observability/dashboards"
ALERT_DIR="${REPO_ROOT}/observability/alerts"

usage() {
  echo "Usage: $0 export <dev|prod>" >&2
  echo "       $0 apply  <dev|prod> [file ...]" >&2
}

resolve_env() {
  case "$1" in
  dev)
    local file="${HOME}/.config/hyperdx/local.env"
    [[ -f "$file" ]] || {
      echo "ERROR: ${file} not found — run 'make hyperdx-dev-bootstrap' first." >&2
      exit 1
    }
    # shellcheck disable=SC1090
    source "$file"
    : "${HYPERDX_LOCAL_ACCESS_KEY:?missing HYPERDX_LOCAL_ACCESS_KEY in ${file} — run 'make hyperdx-dev-bootstrap'}"
    BASE="http://localhost:7707"
    KEY="$HYPERDX_LOCAL_ACCESS_KEY"
    ;;
  prod)
    if [[ -n "${HYPERDX_PROD_ACCESS_KEY:-}" ]]; then
      KEY="$HYPERDX_PROD_ACCESS_KEY"
    elif command -v secrets-run >/dev/null 2>&1; then
      KEY=$(secrets-run read "op://vps/clickstack/AGENT_ACCESS_KEY")
    else
      KEY=$(op read "op://vps/clickstack/AGENT_ACCESS_KEY")
    fi
    if [[ -n "${HYPERDX_PROD_BASE_URL:-}" ]]; then
      BASE="$HYPERDX_PROD_BASE_URL"
    elif command -v secrets-run >/dev/null 2>&1; then
      BASE="https://hyperdx.$(secrets-run read "op://vps/config/DOMAIN")"
    else
      BASE="https://hyperdx.$(op read "op://vps/config/DOMAIN")"
    fi
    ;;
  *)
    echo "ERROR: unknown env '$1' (expected dev|prod)" >&2
    exit 1
    ;;
  esac
}

cmd_export() {
  local env="$1"
  resolve_env "$env"
  mkdir -p "$DASH_DIR" "$ALERT_DIR"

  local dash_resp source_resp connection_resp
  dash_resp=$(curl -fsS "${BASE}/api/api/v2/dashboards" -H "Authorization: Bearer ${KEY}")
  source_resp=$(curl -fsS "${BASE}/api/api/v2/sources" -H "Authorization: Bearer ${KEY}")
  connection_resp=$(curl -fsS "${BASE}/api/api/v2/connections" -H "Authorization: Bearer ${KEY}")

  HDX_RESP="$dash_resp" HDX_SOURCE="$source_resp" HDX_CONNECTION="$connection_resp" HDX_DIR="$DASH_DIR" python3 <<'PY'
import json
import os
import re
import sys

# Top-level only — server-owned fields on the dashboard document itself.
# Nested ids (tiles[].id, tiles[].containerId, containers[].id, ...) are
# structural, not server-assigned metadata, and the write schema requires
# them back (e.g. containers[].id) — stripping them recursively broke apply.
STRIP_KEYS = {"id", "_id", "createdAt", "updatedAt", "team"}


def slugify(name):
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or "dashboard"


def strip(dash):
    return {k: v for k, v in dash.items() if k not in STRIP_KEYS}


# Tile configs embed per-env source ids (config.sourceId, and a table tile's
# "click a row to search" link at config.onClick.target when its mode is
# "id" — the only other id shape in the tile schema) — both make `apply`
# fail into a different env. Swap every one for the source's NAME instead:
# any dict with a "sourceId" key, or any {"mode": "id", "id": <sourceId>}
# shape, gets that id replaced by a "source" key holding the name. Matching
# is by id membership in the known source map, not by JSON path, so an
# unrelated onClick target (e.g. type "dashboard", where target.id is a
# dashboard id, not a source id) is left untouched.
def resolve_source_refs(obj, source_name_by_id, dash_name):
    if isinstance(obj, dict):
        obj = dict(obj)
        if isinstance(obj.get("sourceId"), str):
            sid = obj.pop("sourceId")
            name = source_name_by_id.get(sid)
            if name is None:
                sys.exit(f"ERROR: dashboard '{dash_name}' references unknown sourceId {sid}")
            obj["source"] = name
        elif (
            obj.get("mode") == "id"
            and isinstance(obj.get("id"), str)
            and obj["id"] in source_name_by_id
        ):
            obj["source"] = source_name_by_id[obj.pop("id")]
        return {k: resolve_source_refs(v, source_name_by_id, dash_name) for k, v in obj.items()}
    if isinstance(obj, list):
        return [resolve_source_refs(v, source_name_by_id, dash_name) for v in obj]
    return obj


# A SQL tile's config.connectionId is a per-env id too (the ClickHouse
# connection registered in that env's Mongo). Swap it for the connection's
# NAME the same way: any dict with a "connectionId" key gets that id
# replaced by a "connection" key holding the name.
def resolve_connection_refs(obj, connection_name_by_id, dash_name):
    if isinstance(obj, dict):
        obj = dict(obj)
        if isinstance(obj.get("connectionId"), str):
            cid = obj.pop("connectionId")
            name = connection_name_by_id.get(cid)
            if name is None:
                sys.exit(f"ERROR: dashboard '{dash_name}' references unknown connectionId {cid}")
            obj["connection"] = name
        return {k: resolve_connection_refs(v, connection_name_by_id, dash_name) for k, v in obj.items()}
    if isinstance(obj, list):
        return [resolve_connection_refs(v, connection_name_by_id, dash_name) for v in obj]
    return obj


resp = json.loads(os.environ["HDX_RESP"])
sources = json.loads(os.environ["HDX_SOURCE"]).get("data", [])
source_name_by_id = {s["id"]: s.get("name") for s in sources}
connections = json.loads(os.environ["HDX_CONNECTION"]).get("data", [])
connection_name_by_id = {c["id"]: c.get("name") for c in connections}
out_dir = os.environ["HDX_DIR"]
dashboards = resp.get("data", [])
count = 0
for dash in dashboards:
    cleaned = strip(dash)
    cleaned = resolve_source_refs(cleaned, source_name_by_id, cleaned.get("name", "dashboard"))
    cleaned = resolve_connection_refs(cleaned, connection_name_by_id, cleaned.get("name", "dashboard"))
    slug = slugify(dash.get("name", "dashboard"))
    path = os.path.join(out_dir, f"{slug}.json")
    with open(path, "w") as f:
        json.dump(cleaned, f, indent=2, sort_keys=True)
        f.write("\n")
    count += 1
print(f"exported {count} dashboard(s) to {out_dir}")
PY

  local search_resp webhook_resp alert_resp
  search_resp=$(curl -fsS "${BASE}/api/api/v2/saved-searches" -H "Authorization: Bearer ${KEY}")
  webhook_resp=$(curl -fsS "${BASE}/api/api/v2/webhooks" -H "Authorization: Bearer ${KEY}")
  alert_resp=$(curl -fsS "${BASE}/api/api/v2/alerts" -H "Authorization: Bearer ${KEY}")

  HDX_DASH="$dash_resp" HDX_SEARCH="$search_resp" HDX_WEBHOOK="$webhook_resp" \
    HDX_ALERT="$alert_resp" HDX_DIR="$ALERT_DIR" python3 <<'PY'
import json
import os
import re
import sys

# `channels` is the server-side mirror of `channel` (HyperDX >= 2.36) and carries a raw
# webhook id; the request schema only takes `channel`, so it never round-trips.
ALERT_STRIP_KEYS = {"id", "state", "teamId", "silenced", "executionErrors", "createdAt", "updatedAt"}


def slugify(name):
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or "alert"


dashboards = json.loads(os.environ["HDX_DASH"]).get("data", [])
searches = json.loads(os.environ["HDX_SEARCH"]).get("data", [])
webhooks = json.loads(os.environ["HDX_WEBHOOK"]).get("data", [])
alerts = json.loads(os.environ["HDX_ALERT"]).get("data", [])
out_dir = os.environ["HDX_DIR"]

dash_by_id = {d["id"]: d for d in dashboards}
search_name_by_id = {s["id"]: s.get("name") for s in searches}
webhook_name_by_id = {w["id"]: w.get("name") for w in webhooks}

count = 0
for alert in alerts:
    if "weatherorb" in (alert.get("tags") or []):
        continue  # owned and applied by the weatherorb repo (ops/clickstack/alerts.json)
    a = {k: v for k, v in alert.items() if k not in ALERT_STRIP_KEYS}

    dashboard_id = a.pop("dashboardId", None)
    tile_id = a.pop("tileId", None)
    saved_search_id = a.pop("savedSearchId", None)

    if dashboard_id:
        dash = dash_by_id.get(dashboard_id)
        if dash is None:
            sys.exit(f"ERROR: alert '{alert.get('name')}' references unknown dashboardId {dashboard_id}")
        a["dashboard"] = dash.get("name")
        if tile_id:
            tile = next((t for t in dash.get("tiles", []) if t.get("id") == tile_id), None)
            if tile is None:
                sys.exit(f"ERROR: alert '{alert.get('name')}' references unknown tileId {tile_id} on dashboard '{dash.get('name')}'")
            a["tile"] = tile.get("name")

    if saved_search_id:
        name = search_name_by_id.get(saved_search_id)
        if name is None:
            sys.exit(f"ERROR: alert '{alert.get('name')}' references unknown savedSearchId {saved_search_id}")
        a["savedSearch"] = name

    # `channels` (HyperDX >= 2.36, 1-10 webhooks) is the source of truth; the singular `channel` is its
    # first-entry mirror, so the file keeps only `channels`, webhooks by name.
    channels = a.pop("channels", None) or ([a["channel"]] if a.get("channel") else [])
    a.pop("channel", None)
    named = []
    for channel in channels:
        if isinstance(channel, dict) and channel.get("type") == "webhook":
            webhook_id = channel.get("webhookId")
            name = webhook_name_by_id.get(webhook_id)
            if name is None:
                sys.exit(f"ERROR: alert '{alert.get('name')}' references unknown webhookId {webhook_id}")
            channel = {k: v for k, v in channel.items() if k != "webhookId"}
            channel["webhook"] = name
        named.append(channel)
    if named:
        a["channels"] = named

    slug_source = alert.get("name") or f"alert-{alert.get('id', 'unknown')}"
    slug = slugify(slug_source)
    path = os.path.join(out_dir, f"{slug}.json")
    with open(path, "w") as f:
        json.dump(a, f, indent=2, sort_keys=True)
        f.write("\n")
    count += 1
print(f"exported {count} alert(s) to {out_dir}")
PY
}

cmd_apply() {
  local env="$1"
  shift
  resolve_env "$env"

  local files=("$@")
  if [[ ${#files[@]} -eq 0 ]]; then
    shopt -s nullglob
    files=("$DASH_DIR"/*.json)
    shopt -u nullglob
  fi

  local failed=0

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "no dashboard files to apply"
  else
    local existing source_resp connection_resp
    existing=$(curl -fsS "${BASE}/api/api/v2/dashboards" -H "Authorization: Bearer ${KEY}")
    source_resp=$(curl -fsS "${BASE}/api/api/v2/sources" -H "Authorization: Bearer ${KEY}")
    connection_resp=$(curl -fsS "${BASE}/api/api/v2/connections" -H "Authorization: Bearer ${KEY}")

    for file in "${files[@]}"; do
      echo "--> ${file}"

      local body
      if ! body=$(HDX_SOURCE="$source_resp" HDX_CONNECTION="$connection_resp" HDX_FILE="$file" python3 <<'PY'
import json
import os
import sys

sources = json.loads(os.environ["HDX_SOURCE"]).get("data", [])
source_id_by_name = {s.get("name"): s["id"] for s in sources}
connections = json.loads(os.environ["HDX_CONNECTION"]).get("data", [])
connection_id_by_name = {c.get("name"): c["id"] for c in connections}

with open(os.environ["HDX_FILE"]) as f:
    dash = json.load(f)

# Inverse of the export-time transform: any dict holding a "source" key
# (name) is either a tile config's source reference or an onClick target —
# distinguish by "mode" and restore the id under the matching key.
def restore_source_refs(obj, dash_name):
    if isinstance(obj, dict):
        obj = dict(obj)
        if isinstance(obj.get("source"), str):
            name = obj.pop("source")
            source_id = source_id_by_name.get(name)
            if source_id is None:
                sys.exit(f"ERROR: dashboard '{dash_name}' references unknown source '{name}'")
            key = "id" if obj.get("mode") == "id" else "sourceId"
            obj[key] = source_id
        return {k: restore_source_refs(v, dash_name) for k, v in obj.items()}
    if isinstance(obj, list):
        return [restore_source_refs(v, dash_name) for v in obj]
    return obj

# Inverse of the export-time connection transform: any dict holding a
# "connection" key (name) restores the connectionId.
def restore_connection_refs(obj, dash_name):
    if isinstance(obj, dict):
        obj = dict(obj)
        if isinstance(obj.get("connection"), str):
            name = obj.pop("connection")
            connection_id = connection_id_by_name.get(name)
            if connection_id is None:
                sys.exit(f"ERROR: dashboard '{dash_name}' references unknown connection '{name}'")
            obj["connectionId"] = connection_id
        return {k: restore_connection_refs(v, dash_name) for k, v in obj.items()}
    if isinstance(obj, list):
        return [restore_connection_refs(v, dash_name) for v in obj]
    return obj

resolved = restore_source_refs(dash, dash.get("name", "dashboard"))
resolved = restore_connection_refs(resolved, dash.get("name", "dashboard"))
print(json.dumps(resolved))
PY
      ); then
        echo "  ✗ ${body}"
        failed=1
        continue
      fi

      local validate_resp valid
      validate_resp=$(curl -fsS -X POST "${BASE}/api/api/v2/dashboards/validate" \
        -H "Authorization: Bearer ${KEY}" \
        -H "Content-Type: application/json" \
        --data-binary "$body")
      valid=$(python3 -c "import json,sys; print(json.load(sys.stdin)['valid'])" <<<"$validate_resp")

      if [[ "$valid" != "True" ]]; then
        echo "  ✗ invalid:"
        python3 -c "
import json, sys
for e in json.load(sys.stdin)['errors']:
    print(f\"    {e['path']}: {e['message']}\")
" <<<"$validate_resp"
        failed=1
        continue
      fi

      local name existing_id
      name=$(python3 -c "import json,sys; print(json.load(sys.stdin)['name'])" <<<"$body")
      existing_id=$(HDX_NAME="$name" python3 -c "
import json, os, sys
name = os.environ['HDX_NAME']
data = json.loads(sys.stdin.read()).get('data', [])
match = next((d for d in data if d.get('name') == name), None)
print(match['id'] if match else '')
" <<<"$existing")

      if [[ -n "$existing_id" ]]; then
        curl -fsS -X PUT "${BASE}/api/api/v2/dashboards/${existing_id}" \
          -H "Authorization: Bearer ${KEY}" \
          -H "Content-Type: application/json" \
          --data-binary "$body" >/dev/null
        echo "  ✓ updated ${name} (${existing_id})"
      else
        curl -fsS -X POST "${BASE}/api/api/v2/dashboards" \
          -H "Authorization: Bearer ${KEY}" \
          -H "Content-Type: application/json" \
          --data-binary "$body" >/dev/null
        echo "  ✓ created ${name}"
      fi
    done
  fi

  # Explicit dashboard files = a targeted apply; alerts reference dashboards by
  # name and would only fail against an environment that lacks the rest.
  if [[ $# -eq 0 ]]; then
    apply_alerts || failed=1
  else
    echo "skipping alerts (explicit dashboard files given)"
  fi

  [[ "$failed" -eq 0 ]]
}

apply_alerts() {
  mkdir -p "$ALERT_DIR"
  shopt -s nullglob
  local files=("$ALERT_DIR"/*.json)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "no alert files to apply"
    return 0
  fi

  local dash_resp search_resp webhook_resp alert_resp
  dash_resp=$(curl -fsS "${BASE}/api/api/v2/dashboards" -H "Authorization: Bearer ${KEY}")
  search_resp=$(curl -fsS "${BASE}/api/api/v2/saved-searches" -H "Authorization: Bearer ${KEY}")
  webhook_resp=$(curl -fsS "${BASE}/api/api/v2/webhooks" -H "Authorization: Bearer ${KEY}")
  alert_resp=$(curl -fsS "${BASE}/api/api/v2/alerts" -H "Authorization: Bearer ${KEY}")

  local failed=0
  for file in "${files[@]}"; do
    echo "--> ${file}"

    local body
    if ! body=$(HDX_DASH="$dash_resp" HDX_SEARCH="$search_resp" HDX_WEBHOOK="$webhook_resp" HDX_FILE="$file" python3 <<'PY'
import json
import os
import sys

dashboards = json.loads(os.environ["HDX_DASH"]).get("data", [])
searches = json.loads(os.environ["HDX_SEARCH"]).get("data", [])
webhooks = json.loads(os.environ["HDX_WEBHOOK"]).get("data", [])

dash_by_name = {d.get("name"): d for d in dashboards}
search_id_by_name = {s.get("name"): s.get("id") for s in searches}
webhook_id_by_name = {w.get("name"): w.get("id") for w in webhooks}

with open(os.environ["HDX_FILE"]) as f:
    alert = json.load(f)

dashboard_name = alert.pop("dashboard", None)
tile_title = alert.pop("tile", None)
saved_search_name = alert.pop("savedSearch", None)

if dashboard_name is not None:
    dash = dash_by_name.get(dashboard_name)
    if dash is None:
        sys.exit(f"ERROR: unresolved dashboard reference '{dashboard_name}'")
    alert["dashboardId"] = dash["id"]
    if tile_title is not None:
        tile = next(
            (t for t in dash.get("tiles", []) if t.get("name") == tile_title),
            None,
        )
        if tile is None:
            sys.exit(f"ERROR: unresolved tile reference '{tile_title}' on dashboard '{dashboard_name}'")
        alert["tileId"] = tile["id"]

if saved_search_name is not None:
    search_id = search_id_by_name.get(saved_search_name)
    if search_id is None:
        sys.exit(f"ERROR: unresolved savedSearch reference '{saved_search_name}'")
    alert["savedSearchId"] = search_id

# Files carry `channels` (names) or the legacy singular `channel`; the API gets both, `channel` mirroring
# channels[0] (a body with only `channel` would replace a multi-channel alert with one).
channels = alert.pop("channels", None) or ([alert["channel"]] if alert.get("channel") else [])
resolved = []
for channel in channels:
    if isinstance(channel, dict) and "webhook" in channel:
        channel = dict(channel)
        webhook_name = channel.pop("webhook")
        webhook_id = webhook_id_by_name.get(webhook_name)
        if webhook_id is None:
            sys.exit(f"ERROR: unresolved webhook reference '{webhook_name}'")
        channel["webhookId"] = webhook_id
    resolved.append(channel)
if resolved:
    alert["channels"] = resolved
    alert["channel"] = resolved[0]

print(json.dumps(alert))
PY
    ); then
      echo "  ✗ ${body}"
      failed=1
      continue
    fi

    local name existing_id
    name=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('name') or '')" <<<"$body")
    existing_id=$(HDX_NAME="$name" python3 -c "
import json, os, sys
name = os.environ['HDX_NAME']
data = json.loads(sys.stdin.read()).get('data', [])
match = next((a for a in data if (a.get('name') or '') == name), None)
print(match['id'] if match else '')
" <<<"$alert_resp")

    if [[ -n "$existing_id" ]]; then
      curl -fsS -X PUT "${BASE}/api/api/v2/alerts/${existing_id}" \
        -H "Authorization: Bearer ${KEY}" \
        -H "Content-Type: application/json" \
        --data-binary "$body" >/dev/null
      echo "  ✓ updated ${name} (${existing_id})"
    else
      local resp new_id
      resp=$(curl -fsS -X POST "${BASE}/api/api/v2/alerts" \
        -H "Authorization: Bearer ${KEY}" \
        -H "Content-Type: application/json" \
        --data-binary "$body")
      new_id=$(python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])" <<<"$resp")
      echo "  ✓ created ${name} (${new_id})"
    fi
  done

  [[ "$failed" -eq 0 ]]
}

main() {
  [[ $# -ge 1 ]] || {
    usage
    exit 1
  }
  local sub="$1"
  shift
  case "$sub" in
  export)
    [[ $# -ge 1 ]] || {
      usage
      exit 1
    }
    cmd_export "$1"
    ;;
  apply)
    [[ $# -ge 1 ]] || {
      usage
      exit 1
    }
    local env="$1"
    shift
    cmd_apply "$env" "$@"
    ;;
  *)
    usage
    exit 1
    ;;
  esac
}

main "$@"
