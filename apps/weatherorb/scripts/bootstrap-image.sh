#!/usr/bin/env bash
# Seed the registry with the :initial weatherorb-edge image so RollHook has a running
# container to authorize OIDC deploys against. Run once per fresh server before the
# first GitHub Actions deploy can succeed. Idempotent — re-running rebuilds and re-pushes.
#
# Unlike research-gateway this does NOT clone from GitHub: the build context is pushed
# here from the mini by `make edge-bootstrap` in the weatherorb repo (map/ + deploy/edge/),
# so a private repo needs no token on the server.
#
# Run via:  make weatherorb-bootstrap-image
# Requires: ROLLHOOK_SECRET in env (provided by op run via the Make target).

set -euo pipefail

: "${ROLLHOOK_SECRET:?ROLLHOOK_SECRET not set — run via 'make weatherorb-bootstrap-image'}"

REGISTRY="rollhook.jkrumm.com"
SRC_DIR="${WEATHERORB_SRC_DIR:-/tmp/weatherorb-bootstrap}"

if [ ! -f "${SRC_DIR}/deploy/edge/Dockerfile" ]; then
  echo "✗ ${SRC_DIR}/deploy/edge/Dockerfile missing — run 'make edge-bootstrap' in the weatherorb repo on the mini first" >&2
  exit 1
fi
# /tmp is world-writable: only build a context this user created, never one planted there.
if [ ! -O "${SRC_DIR}" ]; then
  echo "✗ ${SRC_DIR} is not owned by $(id -un) — refusing to build a context someone else wrote" >&2
  exit 1
fi

echo "[1/3] docker login ${REGISTRY}"
echo "${ROLLHOOK_SECRET}" | docker login "${REGISTRY}" -u rollhook --password-stdin

echo "[2/3] Build ${REGISTRY}/weatherorb-edge:initial"
docker build \
  -t "${REGISTRY}/weatherorb-edge:initial" \
  -t "${REGISTRY}/weatherorb-edge:latest" \
  -f "${SRC_DIR}/deploy/edge/Dockerfile" \
  "${SRC_DIR}"

echo "[3/3] Push images"
docker push "${REGISTRY}/weatherorb-edge:initial"
docker push "${REGISTRY}/weatherorb-edge:latest"

echo
echo "Done. Now:"
echo "  1. make weatherorb-env"
echo "  2. make weatherorb-up"
