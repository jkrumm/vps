# gh-actions-telemetry (the mini's LaunchAgent): resolved by `secrets-run run --env-file=` at every tick.
# GH_TOKEN is the mini's GitHub credential; the poller only issues GETs (Actions read). A read-only token of its own
# (fine-grained, Actions + Metadata read on all repos) replaces this one line without a code change.
GH_TOKEN=op://mini/github/token
DOMAIN=op://vps/config/DOMAIN
HYPERDX_API_KEY=op://vps/argo/HYPERDX_API_KEY_PROD
