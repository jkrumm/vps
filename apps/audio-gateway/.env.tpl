# audio-gateway .env.tpl — 1Password references resolved by `op inject`.
# Run `make audio-gateway-env` to materialize → apps/audio-gateway/.env (gitignored).
# Re-run after rotating any secret.
IU_API_KEY=op://common/anthropic/API_KEY
IU_OPENAI_BASE_URL=op://common/anthropic/OPENAI_BASE_URL
IU_GEMINI_BASE_URL=op://common/anthropic/GEMINI_BASE_URL
DOMAIN=op://vps/config/DOMAIN
USAGE_DB=/data/usage.db
STT_PROMPT=Die Aufnahme ist auf Deutsch oder Englisch.
# Usage telemetry → Argo. 'both' = local SQLite + push. Internal docker route over the
# shared proxy net; ARGO_API_SECRET must match argo-api's API_SECRET (same 1Password item).
USAGE_SINK=both
USAGE_HTTP_URL=http://argo-api:4000/usage/records
USAGE_SOURCE_LABEL=audio-gateway
ARGO_API_SECRET=op://common/api/SECRET
MACHINE=vps
# No podcast secrets here (IMAGE_GATEWAY_API_KEY, ABS_*): the pipeline runs on the mini
# instance; this container is STT/TTS only (PODCAST_ENABLED=false in compose.yml).
