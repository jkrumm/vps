# VPS .env.tpl — secrets and config via 1Password
# Usage: op run --env-file=.env.tpl -- docker compose up -d

# --- Cloudflare ---
# Token + account + primary zone ID live in `common` — shared with HomeLab.
# Tunnel token + tunnel ID are per-server (HomeLab and VPS run separate tunnels).
# Variable names match the unified /cloudflare skill (~/SourceRoot/.claude/skills/cloudflare/).
CLOUDFLARE_API_TOKEN=op://common/cloudflare/DNS_API_TOKEN
CLOUDFLARE_ACCOUNT_ID=op://common/cloudflare/ACCOUNT_ID
CLOUDFLARE_ZONE_ID=op://common/cloudflare/ZONE_ID_JKRUMM_COM
CLOUDFLARE_TUNNEL_ID=op://vps/cloudflare-tunnel/TUNNEL_ID
CLOUDFLARE_TUNNEL_TOKEN=op://vps/cloudflare-tunnel/TOKEN

# --- Postgres ---
POSTGRES_DB=op://vps/config/POSTGRES_DB
POSTGRES_USER=op://vps/config/POSTGRES_USER
POSTGRES_PASSWORD=op://vps/postgres/PASSWORD

# --- MariaDB (FPP — exposed on :33306 for Vercel, see apps/fpp/) ---
MARIADB_DB=op://vps/config/MARIADB_DB
MARIADB_ROOT_PASSWORD=op://vps/mariadb/ROOT_PASSWORD
MARIADB_FPP_PASSWORD=op://vps/mariadb/FPP_PASSWORD

# --- FPP services (apps/fpp/compose.yml — fpp-server, fpp-analytics, updater) ---
# Items to create in 1Password before first `make fpp-up`. Paths chosen to keep
# fpp-* secrets co-located in op://vps/fpp/.
FPP_SERVER_SECRET=op://vps/fpp/SERVER_SECRET
FPP_SERVER_SENTRY_DSN=op://vps/fpp/SERVER_SENTRY_DSN
FPP_ANALYTICS_SECRET_TOKEN=op://vps/fpp/ANALYTICS_SECRET_TOKEN
FPP_ANALYTICS_SENTRY_DSN=op://vps/fpp/ANALYTICS_SENTRY_DSN
FPP_BEA_BASE_URL=op://vps/fpp/BEA_BASE_URL
FPP_BEA_SECRET_KEY=op://vps/fpp/BEA_SECRET_KEY
UPTIME_KUMA_FPP_ANALYTICS_UPDATER_PUSH_URL=op://vps/config/UPTIME_KUMA_FPP_ANALYTICS_UPDATER_PUSH_URL

# --- Services ---
UMAMI_DB_PASSWORD=op://vps/umami/DB_PASSWORD
UMAMI_APP_SECRET=op://vps/umami/APP_SECRET
ARGO_DB_PASSWORD=op://vps/argo/DB_PASSWORD
BASALT_UI_PLAYGROUND_DB_PASSWORD=op://vps/basalt-ui-playground/DB_PASSWORD
SHUTTERFLOW_DB_PASSWORD=op://vps/shutterflow/DB_PASSWORD
ROLLHOOK_SECRET=op://vps/rollhook/SECRET
BESZEL_AGENT_KEY=op://vps/beszel/AGENT_KEY
EXPRESS_SESSION_SECRET=op://vps/clickstack/EXPRESS_SESSION_SECRET
# HyperDX ingestion key — auth header on OTLP export from Traefik (traces + metrics).
# Shared with argo for now (revoke-independently is a future refactor: generate a
# dedicated Traefik key in HyperDX → Team Settings and move this reference).
HYPERDX_API_KEY=op://vps/argo/HYPERDX_API_KEY_PROD

# --- imgproxy (apps/imgproxy/compose.yml — image CDN over the img/ prefix) ---
# Shares the existing object-storage bucket with the backups below, so the key
# MUST be namePrefix-restricted to img/ — that restriction is enforced by B2
# server-side and is what keeps imgproxy away from backups/. Read-only.
# Bucket coordinates are reused from the shared `common` item.
IMGPROXY_B2_KEY_ID=op://vps/imgproxy/B2_KEY_ID
IMGPROXY_B2_APP_KEY=op://vps/imgproxy/B2_APP_KEY
IMGPROXY_B2_BUCKET=op://common/backblaze-s3/BUCKET
IMGPROXY_B2_ENDPOINT=op://common/backblaze-s3/ENDPOINT
IMGPROXY_B2_REGION=op://common/backblaze-s3/REGION

# --- Notifications ---
# WATCHTOWER_URL is the shoutrrr-format (slack://...) for Watchtower's notifier.
# WEBHOOK_UPDATES is the plain https webhook for the same #updates channel — used
# by services (e.g. rollhook) that POST raw JSON to a webhook URL directly.
SLACK_WATCHTOWER_URL=op://common/slack/WATCHTOWER_URL
SLACK_WEBHOOK_UPDATES=op://common/slack/WEBHOOK_UPDATES

# --- Backups ---
AWS_ACCESS_KEY_ID=op://common/backblaze-s3/ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY=op://common/backblaze-s3/SECRET_ACCESS_KEY
AWS_S3_BUCKET=op://common/backblaze-s3/BUCKET
AWS_S3_ENDPOINT=op://common/backblaze-s3/ENDPOINT

# --- Monitoring ---
UPTIME_KUMA_PUSH_URL=op://vps/config/UPTIME_KUMA_PUSH_URL
UPTIME_KUMA_FPP_BACKUP_PUSH_URL=op://vps/config/UPTIME_KUMA_FPP_BACKUP_PUSH_URL
UPTIME_KUMA_POSTGRES_PUSH_URL=op://vps/config/UPTIME_KUMA_POSTGRES_PUSH_URL

# --- Network config ---
VPS_TAILSCALE_IP=op://vps/config/VPS_TAILSCALE_IP
DOMAIN=op://vps/config/DOMAIN
ACME_EMAIL=op://vps/config/ACME_EMAIL
