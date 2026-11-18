#!/bin/sh
# Writes a build manifest whose otlphttpexporter is a patched copy of the pinned module.
#   agent/patch-exporter.sh <work-dir>   -> <work-dir>/manifest.yaml and <work-dir>/otlphttpexporter/
#
# The stock exporter retries only 429, 502, 503 and 504; every other status is a permanent error and the batch is dropped
# despite retry_on_failure and the disk queue. Cloudflare answers 530 (origin unreachable) while an origin is down, so the
# copy also retries 500-599 except 501 (not implemented, never transient). An agent that exports over a Cloudflare route
# then keeps its queue through an origin outage. POSIX sh: the Dockerfile's golang:alpine stage has no bash.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:?usage: patch-exporter.sh <work-dir>}"
MODULE="go.opentelemetry.io/collector/exporter/otlphttpexporter"
VERSION="$(sed -n "s|.*${MODULE} \(v[0-9.]*\)\$|\1|p" "${HERE}/manifest.yaml")"
[ -n "${VERSION}" ] || { echo "patch-exporter: ${MODULE} is not pinned in manifest.yaml" >&2; exit 1; }

mkdir -p "${WORK}"
WORK="$(cd "${WORK}" && pwd)"
SRC="$(cd "${WORK}" && go mod download -json "${MODULE}@${VERSION}" | sed -n 's|.*"Dir": "\(.*\)",|\1|p')"
[ -d "${SRC}" ] || { echo "patch-exporter: module directory not found for ${MODULE}@${VERSION}" >&2; exit 1; }

rm -rf "${WORK}/otlphttpexporter"
cp -R "${SRC}" "${WORK}/otlphttpexporter"
chmod -R u+w "${WORK}/otlphttpexporter"
awk '{ print } /^func isRetryableStatusCode\(code int\) bool \{$/ { print "\tif code >= 500 && code <= 599 && code != http.StatusNotImplemented {\n\t\treturn true\n\t}" }' \
  "${WORK}/otlphttpexporter/otlp.go" > "${WORK}/otlp.go.new"
mv "${WORK}/otlp.go.new" "${WORK}/otlphttpexporter/otlp.go"
grep -q 'code != http.StatusNotImplemented' "${WORK}/otlphttpexporter/otlp.go" \
  || { echo "patch-exporter: isRetryableStatusCode not found in ${MODULE}@${VERSION}; the exporter changed, re-check the patch" >&2; exit 1; }

{
  cat "${HERE}/manifest.yaml"
  printf '\nreplaces:\n  - %s => %s\n' "${MODULE}" "${WORK}/otlphttpexporter"
} > "${WORK}/manifest.yaml"
