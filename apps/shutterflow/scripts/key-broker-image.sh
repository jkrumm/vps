#!/usr/bin/env bash
# Build and push rollhook.jkrumm.com/shutterflow-key-broker:<sha> (shutterflow 0040). The broker
# has no CI deploy; this is its only build path. Ship the source first, as for the share server
# (bootstrap-image.sh), from the commit whose sha you pass:
#
#   git -C <shutterflow checkout> archive <sha> | ssh vps 'rm -rf /tmp/shutterflow-bootstrap && mkdir -p /tmp/shutterflow-bootstrap && tar -x -C /tmp/shutterflow-bootstrap'
#
# Run via:  make shutterflow-key-broker-image TAG=<sha>
# Requires: ROLLHOOK_SECRET in env (provided by op run via the Make target).

set -euo pipefail

TAG="${1:?usage: key-broker-image.sh <shutterflow commit sha>}"
: "${ROLLHOOK_SECRET:?ROLLHOOK_SECRET not set — run via 'make shutterflow-key-broker-image'}"

REGISTRY="rollhook.jkrumm.com"
SRC_DIR="${SHUTTERFLOW_SRC_DIR:-/tmp/shutterflow-bootstrap}"
IMAGE="${REGISTRY}/shutterflow-key-broker:${TAG}"

if [ ! -f "${SRC_DIR}/apps/key-broker/Dockerfile" ]; then
  echo "✗ ${SRC_DIR}/apps/key-broker/Dockerfile not found — ship the source first (see the header of this script)"
  exit 1
fi

echo "[1/3] docker login ${REGISTRY}"
echo "${ROLLHOOK_SECRET}" | docker login "${REGISTRY}" -u rollhook --password-stdin

echo "[2/3] Build ${IMAGE}"
docker build -t "${IMAGE}" -f "${SRC_DIR}/apps/key-broker/Dockerfile" "${SRC_DIR}"

echo "[3/3] Push ${IMAGE}"
docker push "${IMAGE}"

echo "Done. Pin ${TAG} in apps/shutterflow/compose.yml, then:  make shutterflow-env && make shutterflow-up"
