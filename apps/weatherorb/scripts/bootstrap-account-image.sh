#!/usr/bin/env bash
# Seed the registry with the :initial weatherorb-account image so RollHook has a running
# container to authorize OIDC deploys against. Run once per fresh server before the
# first GitHub Actions deploy can succeed. Idempotent — re-running rebuilds and re-pushes.
#
# Same shape as bootstrap-image.sh (the edge): the build context is pushed here from the mini
# (the weatherorb repo's deploy/account/Dockerfile and whatever it COPYs), so a private repo
# needs no token on the server. Default context dir is /tmp/weatherorb-account-bootstrap,
# separate from the edge's so the two bootstraps never overwrite each other.
#
# Run via:  make weatherorb-account-bootstrap-image
# Requires: ROLLHOOK_SECRET in env (provided by op run via the Make target).

set -euo pipefail

: "${ROLLHOOK_SECRET:?ROLLHOOK_SECRET not set — run via 'make weatherorb-account-bootstrap-image'}"

REGISTRY="rollhook.jkrumm.com"
SRC_DIR="${WEATHERORB_ACCOUNT_SRC_DIR:-/tmp/weatherorb-account-bootstrap}"

if [ ! -f "${SRC_DIR}/deploy/account/Dockerfile" ]; then
  echo "✗ ${SRC_DIR}/deploy/account/Dockerfile missing — push the weatherorb build context (deploy/account/ + its sources) from the mini first" >&2
  exit 1
fi
# /tmp is world-writable: only build a context this user created, never one planted there.
if [ ! -O "${SRC_DIR}" ]; then
  echo "✗ ${SRC_DIR} is not owned by $(id -un) — refusing to build a context someone else wrote" >&2
  exit 1
fi

echo "[1/3] docker login ${REGISTRY}"
echo "${ROLLHOOK_SECRET}" | docker login "${REGISTRY}" -u rollhook --password-stdin

echo "[2/3] Build ${REGISTRY}/weatherorb-account:initial"
docker build \
  -t "${REGISTRY}/weatherorb-account:initial" \
  -t "${REGISTRY}/weatherorb-account:latest" \
  -f "${SRC_DIR}/deploy/account/Dockerfile" \
  "${SRC_DIR}"

echo "[3/3] Push images"
docker push "${REGISTRY}/weatherorb-account:initial"
docker push "${REGISTRY}/weatherorb-account:latest"

echo
echo "Done. Now:"
echo "  1. make weatherorb-env"
echo "  2. make weatherorb-up"
