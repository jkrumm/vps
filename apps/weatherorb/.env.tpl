# weatherorb scoped env template — materialized via `op inject` to apps/weatherorb/.env so
# RollHook's `docker compose up` (which doesn't go through `op run`) can resolve the ${VAR}
# interpolations in apps/weatherorb/compose.yml. `make weatherorb-env` also appends DOMAIN,
# MINI_TAILSCALE_IP and MINI_TAILNET_HOST (read from this host's tailscale peer list — not secrets).
#
# Refresh after rotating any secret:
#   make weatherorb-env
#
# The resulting apps/weatherorb/.env is gitignored, chmod 644 (the RollHook container runs as a
# non-root uid — same trade-off as apps/shutterflow/.env.tpl), and lives on the VPS only.

WEATHERORB_ACCOUNT_DB_PASSWORD=op://vps/weatherorb-account/DB_PASSWORD
WEATHERORB_ACCOUNT_BETTER_AUTH_SECRET=op://vps/weatherorb-account/BETTER_AUTH_SECRET
