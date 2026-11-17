# disk-watch cron env template — materialized to /etc/vps/disk-watch.env via
# `make cron-env-seed` (scripts/seed-cron-env.sh, `op inject`). Both refs are the ones
# scripts/hyperdx-webhook-setup.sh already reads for the ntfy `alerts` topic.

DOMAIN=op://vps/config/DOMAIN
NTFY_TOKEN=op://common/ntfy/TOKEN
