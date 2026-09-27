# FPP-scoped env template — materialized via `op inject` to apps/fpp/.env
# so RollHook's `docker compose up --scale` (which doesn't go through `op run`)
# can resolve ${VAR} interpolations in apps/fpp/compose.yml.
#
# Refresh after rotating any secret:
#   make fpp-env
#
# The resulting apps/fpp/.env is gitignored, chmod 600, and lives on VPS only.

DOMAIN=op://vps/config/DOMAIN

MARIADB_DB=op://vps/config/MARIADB_DB
MARIADB_ROOT_PASSWORD=op://vps/mariadb/ROOT_PASSWORD
MARIADB_FPP_PASSWORD=op://vps/mariadb/FPP_PASSWORD

FPP_SERVER_SECRET=op://vps/fpp/SERVER_SECRET
FPP_SERVER_SENTRY_DSN=op://vps/fpp/SERVER_SENTRY_DSN
FPP_ANALYTICS_SECRET_TOKEN=op://vps/fpp/ANALYTICS_SECRET_TOKEN
FPP_ANALYTICS_SENTRY_DSN=op://vps/fpp/ANALYTICS_SENTRY_DSN
FPP_EMAIL_GATEWAY_SECRET_KEY=op://vps/email-gateway/SECRET_KEY

UPTIME_KUMA_FPP_ANALYTICS_UPDATER_PUSH_URL=op://vps/config/UPTIME_KUMA_FPP_ANALYTICS_UPDATER_PUSH_URL
