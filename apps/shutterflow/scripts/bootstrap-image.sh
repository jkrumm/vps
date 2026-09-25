#!/usr/bin/env bash
# Seed the registry with an :initial shutterflow-share image so RollHook has a running
# container to authorize OIDC deploys against. Run once per fresh server before the first
# GitHub Actions deploy.
#
# jkrumm/shutterflow is private and the VPS holds no GitHub credential, so the source is
# shipped from a machine that has a checkout (the build context is the monorepo root):
#
#   git -C <shutterflow checkout> archive master | ssh vps 'rm -rf /tmp/shutterflow-bootstrap && mkdir -p /tmp/shutterflow-bootstrap && tar -x -C /tmp/shutterflow-bootstrap'
#
# Idempotent — re-running rebuilds and re-pushes.
#
# Run via:  make shutterflow-bootstrap-image
# Requires: ROLLHOOK_SECRET in env (provided by op run via the Make target).

set -euo pipefail

: "${ROLLHOOK_SECRET:?ROLLHOOK_SECRET not set — run via 'make shutterflow-bootstrap-image'}"

REGISTRY="rollhook.jkrumm.com"
SRC_DIR="${SHUTTERFLOW_SRC_DIR:-/tmp/shutterflow-bootstrap}"

if [ ! -f "${SRC_DIR}/apps/share/Dockerfile" ]; then
  echo "✗ ${SRC_DIR}/apps/share/Dockerfile not found — ship the source first (see the header of this script)"
  exit 1
fi

echo "[1/3] docker login ${REGISTRY}"
echo "${ROLLHOOK_SECRET}" | docker login "${REGISTRY}" -u rollhook --password-stdin

echo "[2/3] Build ${REGISTRY}/shutterflow-share:initial"
docker build \
  -t "${REGISTRY}/shutterflow-share:initial" \
  -t "${REGISTRY}/shutterflow-share:latest" \
  -f "${SRC_DIR}/apps/share/Dockerfile" \
  "${SRC_DIR}"

echo "[3/3] Push ${REGISTRY}/shutterflow-share:{initial,latest}"
docker push "${REGISTRY}/shutterflow-share:initial"
docker push "${REGISTRY}/shutterflow-share:latest"

echo "Done. Now run:  make shutterflow-env && make shutterflow-up"
