# bun-email-api scoped env template — materialized via `op inject` to
# apps/bun-email-api/.env so RollHook's `docker compose up --scale` (which
# doesn't go through `op run`) can resolve ${VAR} interpolations in
# apps/bun-email-api/compose.yml.
#
# Refresh after rotating any secret:
#   make bun-email-api-env
#
# The resulting apps/bun-email-api/.env is gitignored, chmod 644, and lives
# on VPS only. 644 (not 600) because the RollHook container runs as a
# non-root user whose uid doesn't match jkrumm's uid; VPS has no other
# shell users so the local-readability risk is bounded.

DOMAIN=op://vps/config/DOMAIN

BEA_SECRET_KEY=op://vps/bun-email-api/SECRET_KEY
BEA_RESEND_API_KEY=op://vps/bun-email-api/RESEND_API_KEY
BEA_RECEIVER_EMAIL=op://vps/bun-email-api/RECEIVER_EMAIL
BEA_SY_SERENDIPITY_RECEIVER_EMAIL=op://vps/bun-email-api/SY_SERENDIPITY_RECEIVER_EMAIL
