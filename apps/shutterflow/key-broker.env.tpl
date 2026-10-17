# shutterflow-key-broker's env (shutterflow 0040, deploy/hosted-storage.md) — rendered by
# `make shutterflow-env` to apps/shutterflow/key-broker.env (gitignored, 0640 owner:ROLLHOOK_GID)
# and passed to that container only (`env_file:`). Its own 1Password item: the B2 key below can
# create and delete keys and files across the whole B2 account.
B2_APPLICATION_KEY_ID=op://vps/shutterflow-key-broker/B2_APPLICATION_KEY_ID
B2_APPLICATION_KEY=op://vps/shutterflow-key-broker/B2_APPLICATION_KEY
B2_BUCKET_ID=op://vps/shutterflow-key-broker/B2_BUCKET_ID
B2_BUCKET_NAME=op://vps/shutterflow-key-broker/B2_BUCKET_NAME
KEY_BROKER_HMAC_SECRET=op://vps/shutterflow-key-broker/KEY_BROKER_HMAC_SECRET
