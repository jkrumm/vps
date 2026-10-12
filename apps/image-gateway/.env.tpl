# Production secrets template for the VPS.
# Materialized into a real (gitignored) `.env` on the VPS via `op inject` — see DEPLOY.md.
# Place this file in the vps repo at apps/image-gateway/.env.tpl and re-run the env target
# after rotating any secret.

# Traefik's Host() rule interpolates ${DOMAIN} from THIS file, not the vps repo's top-level
# .env. RollHook runs `docker compose up --scale` directly — it does not go through `op run` —
# so anything compose.yml interpolates has to be resolvable here or it silently becomes the
# empty string. Omitting this produced a live router rule of Host(`image.`), which Traefik
# accepts without complaint and then 404s every request against, on a container reporting
# perfectly healthy.
DOMAIN=op://vps/config/DOMAIN

# Gateway's own bearer
API_SECRET=op://vps/image-gateway/API_SECRET

# Upstream OpenAI-compatible endpoint (the unified IU endpoint, same item argo/research-gateway use)
OPENAI_BASE_URL=op://common/anthropic/OPENAI_BASE_URL
OPENAI_API_KEY=op://common/anthropic/API_KEY

# Telemetry → argo (OPTIONAL — omit both to disable)
# Internal docker route on the VPS — argo is Tailscale-only (grey-cloud), so the
# container posts to argo-api directly over the shared monitoring-net, not the public host.
ARGO_USAGE_URL=http://argo-api:4000/usage/records
ARGO_API_SECRET=op://common/api/SECRET
