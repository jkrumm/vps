#!/usr/bin/env bash
# Seed the registry with :initial email-gateway image so RollHook has a
# running container to authorize OIDC deploys against. Run once per fresh
# server before the first GitHub Actions deploy succeeds.
#
# Idempotent — re-running just rebuilds and re-pushes.
#
# Run via:  make email-gateway-bootstrap-image
# Requires: ROLLHOOK_SECRET in env (provided by op run via the Make target).

set -euo pipefail

: "${ROLLHOOK_SECRET:?ROLLHOOK_SECRET not set — run via 'make email-gateway-bootstrap-image'}"

REGISTRY="rollhook.jkrumm.com"
SRC_DIR="${EG_SRC_DIR:-/tmp/email-gateway-bootstrap}"
REPO_URL="https://github.com/jkrumm/email-gateway"

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

echo "[3/4] Build ${REGISTRY}/email-gateway:initial"
docker build \
  -t "${REGISTRY}/email-gateway:initial" \
  -t "${REGISTRY}/email-gateway:latest" \
  -f "${SRC_DIR}/Dockerfile" \
  "${SRC_DIR}"

echo "[4/4] Push ${REGISTRY}/email-gateway:{initial,latest}"
docker push "${REGISTRY}/email-gateway:initial"
docker push "${REGISTRY}/email-gateway:latest"

echo "Done. Now run:  make email-gateway-env && make email-gateway-up"
