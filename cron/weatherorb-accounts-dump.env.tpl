# weatherorb-accounts-dump cron env template — materialized to
# /etc/vps/weatherorb-accounts-dump.env via `make cron-env-seed` (scripts/seed-cron-env.sh,
# `op inject`). Scoped to only what scripts/dump-weatherorb-accounts.sh needs; re-seed after
# rotating the DB password.

WEATHERORB_ACCOUNT_DB_PASSWORD=op://vps/weatherorb-account/DB_PASSWORD
