#!/usr/bin/env bash
# Build the host-agent binaries from manifest.yaml for every platform the agent runs on.
#   agent/build.sh                  -> dist/host-agent-linux-amd64, -linux-arm64, -darwin-arm64
#   agent/build.sh darwin/arm64     -> only the named platforms
# Needs Go and the same ocb release the Dockerfile uses (installed into dist/.bin when absent).
set -euo pipefail

OCB_VERSION="0.165.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="${HERE}/dist"
PLATFORMS=("$@")
[[ ${#PLATFORMS[@]} -gt 0 ]] || PLATFORMS=(linux/amd64 linux/arm64 darwin/arm64)

mkdir -p "${DIST}/.bin"
if [[ ! -x "${DIST}/.bin/builder-${OCB_VERSION}" ]]; then
  GOBIN="${DIST}/.bin/tmp" go install "go.opentelemetry.io/collector/cmd/builder@v${OCB_VERSION}"
  mv "${DIST}/.bin/tmp/builder" "${DIST}/.bin/builder-${OCB_VERSION}"
  rmdir "${DIST}/.bin/tmp"
fi

for platform in "${PLATFORMS[@]}"; do
  os="${platform%/*}"
  arch="${platform#*/}"
  out="${DIST}/_work-${os}-${arch}"
  echo "→ ${os}/${arch}"
  rm -rf "${out}"
  (cd "${HERE}" && CGO_ENABLED=0 GOOS="${os}" GOARCH="${arch}" \
    "${DIST}/.bin/builder-${OCB_VERSION}" --config manifest.yaml --output-path "${out}")
  mv "${out}/host-agent" "${DIST}/host-agent-${os}-${arch}"
  rm -rf "${out}"
done
ls -lh "${DIST}"/host-agent-*
