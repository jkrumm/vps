#!/usr/bin/env bash
# =============================================================================
# weatherorb accounts backup — the `wo-backup` system user + its directory.
# Idempotent. Run with sudo:  make weatherorb-backup-user
#
# wo-backup exists so the homelab can pull the hourly dumps over Tailscale SSH (a tailnet grant
# for exactly that user is committed elsewhere). It has no password, is NOT in the docker or
# sudo groups, and can only read /var/backups/weatherorb-accounts (root:wo-backup 0750, dumps
# 0640). The home dir is what lets a Tailscale SSH session land.
# =============================================================================
set -euo pipefail

USER_NAME="wo-backup"
BACKUP_DIR="/var/backups/weatherorb-accounts"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "✗ run as root (sudo)" >&2
  exit 1
fi

if id "${USER_NAME}" >/dev/null 2>&1; then
  echo "  ${USER_NAME} already exists"
else
  adduser --system --group --disabled-password --shell /bin/sh \
    --home "/home/${USER_NAME}" --gecos "weatherorb accounts backup pull" "${USER_NAME}"
  echo "  ✓ created ${USER_NAME}"
fi

# Re-assert the no-privilege invariants on every run (drift from a manual edit).
for grp in docker sudo; do
  if id -nG "${USER_NAME}" | tr ' ' '\n' | grep -qx "${grp}"; then
    gpasswd -d "${USER_NAME}" "${grp}"
  fi
done
usermod --shell /bin/sh "${USER_NAME}"

install -d -o root -g "${USER_NAME}" -m 0750 "${BACKUP_DIR}"
echo "  ✓ ${BACKUP_DIR} root:${USER_NAME} 0750"
