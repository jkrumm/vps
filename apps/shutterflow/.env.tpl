# shutterflow scoped env template — materialized via `op inject` to apps/shutterflow/.env so
# RollHook's `docker compose up --scale` (which doesn't go through `op run`) can resolve the
# ${VAR} interpolations in apps/shutterflow/compose.yml. `make shutterflow-env` also appends
# SHUTTERFLOW_TRUSTED_PROXIES (the `proxy` network CIDR, read from docker, not stored anywhere).
#
# Refresh after rotating any secret:
#   make shutterflow-env
#
# The resulting apps/shutterflow/.env is gitignored, chmod 644 (the RollHook container runs as a
# non-root uid — same trade-off as apps/bun-email-api/.env.tpl), and lives on the VPS only.

POSTGRES_DB=op://vps/config/POSTGRES_DB

SHUTTERFLOW_DB_PASSWORD=op://vps/shutterflow/DB_PASSWORD
SHUTTERFLOW_BETTER_AUTH_SECRET=op://vps/shutterflow/BETTER_AUTH_SECRET
SHUTTERFLOW_RESEND_API_KEY=op://vps/shutterflow/RESEND_API_KEY
SHUTTERFLOW_GOOGLE_CLIENT_ID=op://vps/shutterflow/GOOGLE_CLIENT_ID
SHUTTERFLOW_GOOGLE_CLIENT_SECRET=op://vps/shutterflow/GOOGLE_CLIENT_SECRET
SHUTTERFLOW_IMGPROXY_KEY=op://vps/shutterflow/IMGPROXY_KEY
SHUTTERFLOW_IMGPROXY_SALT=op://vps/shutterflow/IMGPROXY_SALT

# Bucket coordinates — shared with the backups and imgproxy (common item, not secret).
SHUTTERFLOW_B2_BUCKET=op://common/backblaze-s3/BUCKET
SHUTTERFLOW_B2_ENDPOINT=op://common/backblaze-s3/ENDPOINT
SHUTTERFLOW_B2_REGION=op://common/backblaze-s3/REGION

# Server key: listBuckets,listFiles,readFiles,writeFiles,deleteFiles on
# shutterflow/prod/derivatives/ only (presigned staging uploads, copy → served, deletes).
SHUTTERFLOW_STORAGE_B2_KEY_ID=op://vps/shutterflow/STORAGE_B2_KEY_ID
SHUTTERFLOW_STORAGE_B2_APP_KEY=op://vps/shutterflow/STORAGE_B2_APP_KEY
# CDN key: listBuckets,listFiles,readFiles on shutterflow/prod/derivatives/ only.
SHUTTERFLOW_CDN_B2_KEY_ID=op://vps/shutterflow/CDN_B2_KEY_ID
SHUTTERFLOW_CDN_B2_APP_KEY=op://vps/shutterflow/CDN_B2_APP_KEY
# No masters key here, ever: the server must not be able to read originals (0018).
