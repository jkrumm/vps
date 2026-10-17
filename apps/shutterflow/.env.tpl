# shutterflow scoped env template — materialized via `op inject` to apps/shutterflow/.env so
# RollHook's `docker compose up --scale` (which doesn't go through `op run`) can resolve the
# ${VAR} interpolations in apps/shutterflow/compose.yml. `make shutterflow-env` also appends
# SHUTTERFLOW_TRUSTED_PROXIES (the `proxy` network CIDR, read from docker, not stored anywhere).
#
# Refresh after rotating any secret:
#   make shutterflow-env
#
# The resulting apps/shutterflow/.env is gitignored, chmod 644 (the RollHook container runs as a
# non-root uid — same trade-off as apps/email-gateway/.env.tpl), and lives on the VPS only.

POSTGRES_DB=op://vps/config/POSTGRES_DB
DOMAIN=op://vps/config/DOMAIN

SHUTTERFLOW_DB_PASSWORD=op://vps/shutterflow/DB_PASSWORD
SHUTTERFLOW_BETTER_AUTH_SECRET=op://vps/shutterflow/BETTER_AUTH_SECRET
# Bearer for the email gateway's POST /shutterflow (auth-code mails) — the gateway's own field.
SHUTTERFLOW_EMAIL_GATEWAY_SECRET_KEY=op://vps/email-gateway/SHUTTERFLOW_SECRET_KEY
SHUTTERFLOW_GOOGLE_CLIENT_ID=op://vps/shutterflow/GOOGLE_CLIENT_ID
SHUTTERFLOW_GOOGLE_CLIENT_SECRET=op://vps/shutterflow/GOOGLE_CLIENT_SECRET
SHUTTERFLOW_IMGPROXY_KEY=op://vps/shutterflow/IMGPROXY_KEY
SHUTTERFLOW_IMGPROXY_SALT=op://vps/shutterflow/IMGPROXY_SALT

# Bucket coordinates — shared with the backups and imgproxy (common item, not secret).
SHUTTERFLOW_B2_BUCKET=op://common/backblaze-s3/BUCKET
SHUTTERFLOW_B2_ENDPOINT=op://common/backblaze-s3/ENDPOINT
SHUTTERFLOW_B2_REGION=op://common/backblaze-s3/REGION

# No masters key for the server, ever: it must not be able to read originals (0018).

# imgproxy's key (shutterflow 0042): readFiles ONLY on shutterflow/prod/masters/, its own item,
# passed to the shutterflow-imgproxy container only.
SHUTTERFLOW_IMGPROXY_B2_KEY_ID=op://vps/shutterflow-imgproxy/B2_KEY_ID
SHUTTERFLOW_IMGPROXY_B2_APP_KEY=op://vps/shutterflow-imgproxy/B2_APP_KEY

# The master-serving canary's reference (shutterflow 0042 safety 5): one of the owner's synced
# Finals and its sha256. Never re-edit or delete that Final while it is the reference.
SHUTTERFLOW_CANARY_OBJECT_KEY=op://vps/shutterflow/CANARY_OBJECT_KEY
SHUTTERFLOW_CANARY_SHA256=op://vps/shutterflow/CANARY_SHA256

# Custom domains (shutterflow 0037): the entitlement allowlist, comma-separated share-server user
# ids. Kept in 1Password rather than here because this repo is public.
SHUTTERFLOW_CUSTOM_DOMAINS_USER_IDS=op://vps/shutterflow/CUSTOM_DOMAINS_USER_IDS

# Hosted storage (shutterflow 0040): the secret the share server signs key-broker requests with
# (the same value as the broker's own item), and the entitlement allowlist (user ids, so here
# rather than in this public repo). The broker's B2 key is NOT here: key-broker.env.tpl.
SHUTTERFLOW_BROKER_HMAC_SECRET=op://vps/shutterflow/BROKER_HMAC_SECRET
SHUTTERFLOW_HOSTED_STORAGE_USER_IDS=op://vps/shutterflow/HOSTED_STORAGE_USER_IDS
