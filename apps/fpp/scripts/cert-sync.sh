#!/usr/bin/env bash
# =============================================================================
# Sync wildcard *.free-planning-poker.com certificate from Traefik's acme.json
# to apps/fpp/certs/{cert.pem,key.pem} so MariaDB can serve TLS to Vercel.
# On change: FLUSH SSL inside the running mariadb container (no restart needed).
#
# Public DB hostname is db.free-planning-poker.com — Vercel connects with strict
# rejectUnauthorized:true so the served cert MUST cover that hostname. Internal
# updater uses DB_SSL_VERIFY=false and doesn't care which wildcard we serve.
#
# Idempotent — exits cleanly if certificate is unchanged. Run via cron every 6h.
#
# Required env vars: MARIADB_ROOT_PASSWORD
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
ACME_JSON="${REPO_DIR}/traefik/acme.json"
CERTS_DIR="${REPO_DIR}/apps/fpp/certs"
CERT_DOMAIN="free-planning-poker.com"

mkdir -p "${CERTS_DIR}"

if [[ ! -s "${ACME_JSON}" ]]; then
  echo "ERROR: ${ACME_JSON} missing or empty — Traefik hasn't issued certs yet." >&2
  echo "Run 'make networking-up' first and wait for cert provisioning." >&2
  exit 1
fi

# Traefik can store the wildcard cert as either the main domain or as a SAN
# under another cert (e.g. main=free-planning-poker.com, sans=["*.free-planning-poker.com"]).
# Match both.
JQ_SELECT='.letsencrypt.Certificates[] | select(([.domain.main] + (.domain.sans // [])) | index($d))'
cert_b64=$(jq -r --arg d "*.${CERT_DOMAIN}" "${JQ_SELECT} | .certificate" "${ACME_JSON}")
key_b64=$(jq -r --arg d "*.${CERT_DOMAIN}" "${JQ_SELECT} | .key"         "${ACME_JSON}")

if [[ -z "${cert_b64}" || "${cert_b64}" == "null" ]]; then
  echo "ERROR: wildcard certificate for *.${CERT_DOMAIN} not found in ${ACME_JSON}." >&2
  echo "Check Traefik logs and ensure the wildcard router has TLS enabled." >&2
  exit 1
fi

new_cert=$(echo "${cert_b64}" | base64 -d)
new_key=$(echo "${key_b64}"  | base64 -d)

old_cert=""
[[ -f "${CERTS_DIR}/cert.pem" ]] && old_cert=$(cat "${CERTS_DIR}/cert.pem")

if [[ "${new_cert}" == "${old_cert}" ]]; then
  echo "Certificate unchanged — nothing to do."
  exit 0
fi

echo "Certificate changed — writing cert.pem and key.pem..."
umask 022
printf '%s\n' "${new_cert}" > "${CERTS_DIR}/cert.pem"
printf '%s\n' "${new_key}"  > "${CERTS_DIR}/key.pem"
# The mariadb container's mysql user (uid/gid 999) must read both via the bind mount.
# key.pem goes to 0640 owner:999 (the weatherorb .env pattern) — the host has other
# local service accounts. The redirects above rewrite in place, so once
# tightened the mode/group survive every renewal and cron (no sudo) never touches them.
# Without non-interactive sudo, a key that is not yet group 999 stays 0644 (readable,
# as before) and a warning says how to tighten it.
chmod 644 "${CERTS_DIR}/cert.pem"
if [[ "$(stat -c %g "${CERTS_DIR}/key.pem")" == "999" ]] || sudo -n chgrp 999 "${CERTS_DIR}/key.pem" 2>/dev/null; then
  chmod 640 "${CERTS_DIR}/key.pem"
else
  echo "WARNING: key.pem left world-readable — run: sudo chgrp 999 ${CERTS_DIR}/key.pem && chmod 640 ${CERTS_DIR}/key.pem" >&2
fi

if docker ps --format '{{.Names}}' | grep -q '^mariadb$'; then
  echo "Reloading TLS in running mariadb container (FLUSH SSL)..."
  docker exec -i \
    -e MYSQL_PWD="${MARIADB_ROOT_PASSWORD:-}" \
    mariadb mariadb -u root -e 'FLUSH SSL;'
  echo "TLS reloaded."
else
  echo "MariaDB container not running — certs written, will be picked up on next start."
fi
