# email-gateway scoped env template — materialized via `op inject` to
# apps/email-gateway/.env so RollHook's `docker compose up --scale` (which
# doesn't go through `op run`) can resolve ${VAR} interpolations in
# apps/email-gateway/compose.yml.
#
# Refresh after rotating any secret:
#   make email-gateway-env
#
# The resulting apps/email-gateway/.env is gitignored, chmod 644, and lives
# on VPS only. 644 (not 600) because the RollHook container runs as a
# non-root user whose uid doesn't match jkrumm's uid; VPS has no other
# shell users so the local-readability risk is bounded.

DOMAIN=op://vps/config/DOMAIN

EMAIL_GATEWAY_SECRET_KEY=op://vps/email-gateway/SECRET_KEY
EMAIL_GATEWAY_RESEND_API_KEY=op://vps/email-gateway/RESEND_API_KEY
EMAIL_GATEWAY_RECEIVER_EMAIL=op://vps/email-gateway/RECEIVER_EMAIL
EMAIL_GATEWAY_SY_SERENDIPITY_RECEIVER_EMAIL=op://vps/email-gateway/SY_SERENDIPITY_RECEIVER_EMAIL

# Spam filter — shared IU endpoint creds (same item research-gateway and argo use).
EMAIL_GATEWAY_LLM_BASE_URL=op://common/anthropic/OPENAI_BASE_URL
EMAIL_GATEWAY_LLM_API_KEY=op://common/anthropic/API_KEY

# Decision lane: Cloudflare Clef. Default route is IU's unified endpoint
# (clef-eu, reuses the LLM creds above, see DECISION_PROVIDER in compose.yml);
# this OpenRouter key is the alternative route (DECISION_PROVIDER=openrouter).
EMAIL_GATEWAY_OPENROUTER_API_KEY=op://common/openrouter/API_KEY

# Usage/cost telemetry to argo over the internal proxy network (same as
# image-gen-gateway). Unset -> reporting off.
EMAIL_GATEWAY_ARGO_USAGE_URL=http://argo-api:4000/usage/records
EMAIL_GATEWAY_ARGO_API_SECRET=op://common/api/SECRET

# /admin UI — basic auth password (user "admin"); /admin 404s when unset.
EMAIL_GATEWAY_ADMIN_PASSWORD=op://vps/email-gateway/ADMIN_PASSWORD

# /api/* bearer key (emails, stats, submissions); /api 404s when unset.
EMAIL_GATEWAY_API_KEY=op://vps/email-gateway/API_KEY

# IMAP ingest of hello@ from Proton Mail Bridge on the homelab (read-only),
# over the tailnet (ACL: tag:vps -> tag:homelab tcp:1143). Bridge's cert is
# self-signed for 127.0.0.1; the path is WireGuard-encrypted and ACL-scoped,
# so verification is skipped rather than pinned. Unset host -> ingest off.
EMAIL_GATEWAY_IMAP_HOST=op://common/config/HOMELAB_TAILSCALE_IP
EMAIL_GATEWAY_IMAP_USER=op://vps/email-gateway/IMAP_USER
EMAIL_GATEWAY_IMAP_PASSWORD=op://vps/email-gateway/IMAP_PASSWORD
