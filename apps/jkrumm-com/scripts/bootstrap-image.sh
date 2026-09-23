#!/usr/bin/env bash
# Seed the registry with an :initial jkrumm-com image so RollHook has a
# running container to authorize OIDC deploys against. Run once per fresh
# server before the first GitHub Actions deploy succeeds.
#
# RollHook's discover step matches a *running* container by image name and reads
# its compose labels; with no container it fails ErrServiceNotFound. Hence the
# chicken-and-egg this script breaks.
#
# Idempotent — re-running just rebuilds and re-pushes.
#
# Run via:  make jkrumm-com-bootstrap-image
# Requires: ROLLHOOK_SECRET in env (provided by op run via the Make target).

set -euo pipefail

: "${ROLLHOOK_SECRET:?ROLLHOOK_SECRET not set — run via 'make jkrumm-com-bootstrap-image'}"

REGISTRY="rollhook.jkrumm.com"
SRC_DIR="${JKRUMM_COM_SRC_DIR:-/tmp/jkrumm-com-bootstrap}"
REPO_URL="https://github.com/jkrumm/jkrumm.com"

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

# Single-repo build — the Dockerfile lives at the repo root with root as context.
echo "[3/4] Build ${REGISTRY}/jkrumm-com:initial"
docker build \
  -t "${REGISTRY}/jkrumm-com:initial" \
  -t "${REGISTRY}/jkrumm-com:latest" \
  -f "${SRC_DIR}/Dockerfile" \
  "${SRC_DIR}"

echo "[4/4] Push ${REGISTRY}/jkrumm-com:{initial,latest}"
docker push "${REGISTRY}/jkrumm-com:initial"
docker push "${REGISTRY}/jkrumm-com:latest"

echo "Done. Now run:  make jkrumm-com-up"
