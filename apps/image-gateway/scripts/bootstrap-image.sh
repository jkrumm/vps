#!/usr/bin/env bash
# Seed the registry with an :initial image-gateway image so RollHook has a
# running container to authorize OIDC deploys against. Run once per fresh
# server before the first GitHub Actions deploy succeeds.
#
# Idempotent — re-running just rebuilds and re-pushes.
#
# Run via:  make image-gateway-bootstrap-image
# Requires: ROLLHOOK_SECRET in env (provided by op run via the Make target).

set -euo pipefail

: "${ROLLHOOK_SECRET:?ROLLHOOK_SECRET not set — run via 'make image-gateway-bootstrap-image'}"

REGISTRY="rollhook.jkrumm.com"
SRC_DIR="${IMAGE_GATEWAY_SRC_DIR:-/tmp/image-gateway-bootstrap}"
REPO_URL="https://github.com/jkrumm/image-gateway"

if [ ! -d "${SRC_DIR}/.git" ]; then
  echo "[1/4] Cloning ${REPO_URL} → ${SRC_DIR}"
  rm -rf "${SRC_DIR}"
  git clone --depth=1 "${REPO_URL}" "${SRC_DIR}"
else
  echo "[1/4] Updating ${SRC_DIR}"
  git -C "${SRC_DIR}" fetch --depth=1 origin master
  git -C "${SRC_DIR}" reset --hard origin/master
fi

echo "[2/4] docker login ${REGISTRY}"
echo "${ROLLHOOK_SECRET}" | docker login "${REGISTRY}" -u rollhook --password-stdin

# NOTE: image-gateway is a bun MONOREPO — the gateway depends on the `shared/`
# workspace package, so the build context is the REPO ROOT and the Dockerfile
# path is gateway/Dockerfile. This differs from a single-package app
# (context == Dockerfile dir) and matches .github/workflows/deploy.yml,
# which passes context: . and dockerfile: gateway/Dockerfile. Building with the
# gateway dir as context fails on the missing shared/ workspace.
echo "[3/4] Build ${REGISTRY}/image-gateway:initial"
docker build \
  -t "${REGISTRY}/image-gateway:initial" \
  -t "${REGISTRY}/image-gateway:latest" \
  -f "${SRC_DIR}/gateway/Dockerfile" \
  "${SRC_DIR}"

echo "[4/4] Push images"
docker push "${REGISTRY}/image-gateway:initial"
docker push "${REGISTRY}/image-gateway:latest"

echo
echo "Done. Now:"
echo "  1. make image-gateway-env"
echo "  2. make image-gateway-up"
