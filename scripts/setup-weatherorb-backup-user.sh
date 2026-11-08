#!/usr/bin/env bash
# =============================================================================
# weatherorb accounts backup — the `wo-backup` system user + its directory.
# Idempotent. Run with sudo:  make weatherorb-backup-user
#
# wo-backup exists so the homelab can pull the hourly dumps over Tailscale SSH (a tailnet grant
# for exactly that user is committed elsewhere). It has no password, is NOT in the docker or
# sudo groups, and can only read /var/backups/weatherorb-accounts (root:wo-backup 0750, dumps
# 0640). The home dir is what lets a Tailscale SSH session land. Its login shell is
# scripts/wo-backup-shell, installed root-owned: Tailscale SSH ignores authorized_keys, so the
# shell is the forced command — a session can only run a read-only rsync (rrsync -ro) on the dump
# directory, never an interactive shell or another command.
# =============================================================================
set -euo pipefail

USER_NAME="wo-backup"
BACKUP_DIR="/var/backups/weatherorb-accounts"
SHELL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wo-backup-shell"
SHELL_BIN="/usr/local/bin/wo-backup-shell"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "✗ run as root (sudo)" >&2
  exit 1
fi

if [[ ! -x /usr/bin/rrsync ]]; then
  echo "✗ /usr/bin/rrsync missing (apt install rsync; wo-backup-shell execs that path)" >&2
  exit 1
fi
# Installed before the user is created or its shell switched, so there is never a moment when the
# shell points at a missing file. Root-owned: wo-backup cannot edit its own shell.
install -o root -g root -m 0755 "${SHELL_SRC}" "${SHELL_BIN}"
grep -qxF "${SHELL_BIN}" /etc/shells || echo "${SHELL_BIN}" >> /etc/shells

if id "${USER_NAME}" >/dev/null 2>&1; then
  echo "  ${USER_NAME} already exists"
else
  adduser --system --group --disabled-password --shell "${SHELL_BIN}" \
    --home "/home/${USER_NAME}" --gecos "weatherorb accounts backup pull" "${USER_NAME}"
  echo "  ✓ created ${USER_NAME}"
fi

# Re-assert the no-privilege invariants on every run (drift from a manual edit).
for grp in docker sudo; do
  if id -nG "${USER_NAME}" | tr ' ' '\n' | grep -qx "${grp}"; then
    gpasswd -d "${USER_NAME}" "${grp}"
  fi
done
usermod --shell "${SHELL_BIN}" "${USER_NAME}"

install -d -o root -g "${USER_NAME}" -m 0750 "${BACKUP_DIR}"

# wo-backup is a login-capable local user, so the deploying user's home must not be
# world-traversable: every apps/*/.env under it holds op-injected secrets (mode 644 for
# RollHook). Without this, a wo-backup session reads them all.
DEPLOY_USER="${SUDO_USER:-jkrumm}"
DEPLOY_HOME="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
chmod o-rwx "${DEPLOY_HOME}"
echo "  ✓ ${DEPLOY_HOME} not world-traversable"
echo "  ✓ ${BACKUP_DIR} root:${USER_NAME} 0750"
echo "  ✓ shell ${SHELL_BIN} (rsync -ro on ${BACKUP_DIR} only)"
