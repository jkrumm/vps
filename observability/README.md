# Observability — dashboards + alerts as code

`dashboards/*.json` and `alerts/*.json` are the on-disk source of truth for
HyperDX dashboards and alerts. **Mongo (the dashboard/alert store inside
`clickstack`) has no backup** — these directories are the backup, and the
only way to move a dashboard or alert between dev and prod.

Each dashboard file is named `<slug>.json` (slugified from the dashboard
name), with keys sorted and the dashboard document's own
ids/timestamps/team stripped so the file is env-portable — dashboard ids are
per-env Mongo ObjectIds and never round-trip between dev and prod. Nested ids
(tile ids, `tiles[].containerId`, `containers[].id`) are structural, not
server-owned metadata, and are kept as-is — the dashboard write schema
requires them back. A tile's `config.sourceId` (and a table tile's row-click
search target, when it points at a source) and a SQL tile's
`config.connectionId` are also per-env ids — both are swapped for the
referenced source/connection's **name** (`source` / `connection`) on export
and resolved back via `GET /sources` / `GET /connections` on apply.

Each alert file is named `<slug>.json` (slugified from the alert name, or
`alert-<id>` when unnamed), with ids/timestamps/state/team stripped. Alerts
reference dashboards, tiles, saved searches, and webhooks by **name** instead
of by env-specific id: `dashboardId`+`tileId` become `dashboard`+`tile` (tile
title), `savedSearchId` becomes `savedSearch`, `channels[].webhookId` becomes
`channels[].webhook` (every alert: `Slack #alerts`).

## Loop

```bash
# Webhook first — alerts referencing a channel resolve the webhook by name.
make hyperdx-webhook-setup                 # prod-only, idempotent

# Pull every dashboard and alert from an env down to these directories
make hyperdx-export ENV=dev
make hyperdx-export ENV=prod

# Edit dashboards/*.json / alerts/*.json by hand, or via HyperDX MCP tools
# against dev, then export again to capture the result.

# Validate + upsert (by NAME) dashboards, then alerts, from these
# directories into an env
make hyperdx-apply ENV=dev
make hyperdx-apply ENV=prod
```

`apply` runs `POST /dashboards/validate` on every dashboard file first and
prints its errors before touching anything (alerts have no `/validate`
endpoint — an unresolved name reference is caught and reported before any
write). A dashboard or alert whose name already exists in the target env is
updated in place (`PUT`); a new name is created (`POST`). Alerts always apply
after dashboards, since a tile-based alert needs the target env's dashboard
and tile ids to already resolve.

See `docs/observability.md` → "Agent access — MCP + REST" for the full HTTP
contract and the dedicated agent user this tooling authenticates as.
