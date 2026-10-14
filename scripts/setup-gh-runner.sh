#!/usr/bin/env bash
# =============================================================================
# Self-hosted GitHub Actions runner for jkrumm/shutterflow — install or remove.
# Idempotent. Run via make (it sudo's this script):
#
#   gh api -X POST repos/jkrumm/shutterflow/actions/runners/registration-token --jq .token \
#     | ssh vps 'cd ~/vps && make gh-runner-setup ENV=prod'
#   gh api -X POST repos/jkrumm/shutterflow/actions/runners/remove-token --jq .token \
#     | ssh vps 'cd ~/vps && make gh-runner-remove ENV=prod'
#
# The token arrives on stdin (never argv, never a file) and is only needed to register or
# remove; re-running setup on a registered runner ignores it. Why the runner exists, the
# security model and the full lifecycle: docs/gh-runner.md.
#
# Isolation: the `gh-runner` system user is NOT in the docker or sudo groups. Jobs build images
# against its own ROOTLESS Docker daemon (user namespace, ~gh-runner/.local/share/docker), so a
# job can neither reach the prod daemon (root-equivalent: every container, every env secret) nor
# read /home/<deploy-user> (0750, re-asserted below) where the op-injected apps/*/.env live.
# =============================================================================
set -euo pipefail

ACTION="${1:-}"
GH_REPO="jkrumm/shutterflow"
RUNNER_USER="gh-runner"
RUNNER_NAME="vps-shutterflow"
RUNNER_LABELS="vps"
# Install version — the runner self-updates after registration (a runner with updates disabled
# stops receiving jobs ~30 days after the next release), so this pins first install only.
RUNNER_VERSION="2.338.0"
RUNNER_SHA256="af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32"
# Distinct from the deploy user's 100000:65536 block.
SUBID_RANGE="200000-265535"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "✗ run as root (sudo)" >&2
  exit 1
fi

RUNNER_HOME="/home/${RUNNER_USER}"
RUNNER_DIR="${RUNNER_HOME}/actions-runner"

read_token() {
  local token=""
  [[ -t 0 ]] || IFS= read -r token || true
  if [[ -z "${token}" ]]; then
    echo "✗ pipe a $1 token on stdin (see the header of $0)" >&2
    exit 1
  fi
  printf '%s' "${token}"
}

as_runner() {
  local uid
  uid="$(id -u "${RUNNER_USER}")"
  runuser -u "${RUNNER_USER}" -- env HOME="${RUNNER_HOME}" XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" "$@"
}

service_name() {
  [[ -f "${RUNNER_DIR}/.service" ]] && cat "${RUNNER_DIR}/.service"
}

remove() {
  if [[ ! -f "${RUNNER_DIR}/.runner" ]]; then
    echo "  ${RUNNER_NAME} is not registered — nothing to remove"
    return
  fi
  local token
  token="$(read_token remove)"
  if [[ -n "$(service_name)" ]]; then
    (cd "${RUNNER_DIR}" && ./svc.sh stop && ./svc.sh uninstall)
  fi
  (cd "${RUNNER_DIR}" && as_runner ./config.sh remove --token "${token}")
  echo "  ✓ ${RUNNER_NAME} unregistered and its service removed (user + rootless Docker kept)"
}

setup() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq uidmap slirp4netns >/dev/null

  if id "${RUNNER_USER}" >/dev/null 2>&1; then
    echo "  ${RUNNER_USER} already exists"
  else
    adduser --system --group --disabled-password --shell /bin/bash \
      --home "${RUNNER_HOME}" --gecos "GitHub Actions runner (${GH_REPO})" "${RUNNER_USER}"
    echo "  ✓ created ${RUNNER_USER}"
  fi

  # Re-assert the no-privilege invariants on every run (drift from a manual edit).
  for grp in docker sudo; do
    if id -nG "${RUNNER_USER}" | tr ' ' '\n' | grep -qx "${grp}"; then
      gpasswd -d "${RUNNER_USER}" "${grp}"
    fi
  done
  chmod 0750 "${RUNNER_HOME}"
  DEPLOY_USER="${SUDO_USER:-jkrumm}"
  DEPLOY_HOME="$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)"
  chmod o-rwx "${DEPLOY_HOME}"
  echo "  ✓ ${DEPLOY_HOME} not world-traversable"

  grep -q "^${RUNNER_USER}:" /etc/subuid || usermod --add-subuids "${SUBID_RANGE}" "${RUNNER_USER}"
  grep -q "^${RUNNER_USER}:" /etc/subgid || usermod --add-subgids "${SUBID_RANGE}" "${RUNNER_USER}"

  # Lingering keeps the user's systemd instance — and with it the rootless daemon — up without
  # a login session.
  local uid
  uid="$(id -u "${RUNNER_USER}")"
  loginctl enable-linger "${RUNNER_USER}"
  for _ in $(seq 1 30); do
    [[ -S "/run/user/${uid}/bus" ]] && break
    sleep 1
  done

  if [[ ! -f "${RUNNER_HOME}/.config/systemd/user/docker.service" ]]; then
    as_runner dockerd-rootless-setuptool.sh install
  fi
  as_runner systemctl --user enable --now docker.service >/dev/null
  as_runner env DOCKER_HOST="unix:///run/user/${uid}/docker.sock" docker info --format '  ✓ rootless Docker {{.ServerVersion}} ({{.SecurityOptions}})'

  if [[ ! -x "${RUNNER_DIR}/config.sh" ]]; then
    local tarball
    tarball="$(mktemp)"
    curl -fsSL -o "${tarball}" \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
    echo "${RUNNER_SHA256}  ${tarball}" | sha256sum -c --quiet
    install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" -m 0750 "${RUNNER_DIR}"
    runuser -u "${RUNNER_USER}" -- tar -xzf "${tarball}" -C "${RUNNER_DIR}"
    rm -f "${tarball}"
    "${RUNNER_DIR}/bin/installdependencies.sh" >/dev/null
    echo "  ✓ runner ${RUNNER_VERSION} unpacked (sha256 verified)"
  fi

  if [[ -f "${RUNNER_DIR}/.runner" ]]; then
    echo "  ${RUNNER_NAME} already registered"
  else
    local token
    token="$(read_token registration)"
    (cd "${RUNNER_DIR}" && as_runner ./config.sh --unattended --replace \
      --url "https://github.com/${GH_REPO}" --token "${token}" \
      --name "${RUNNER_NAME}" --labels "${RUNNER_LABELS}" --work _work)
    echo "  ✓ registered ${RUNNER_NAME} on ${GH_REPO} (labels: self-hosted, Linux, X64, ${RUNNER_LABELS})"
  fi

  # The runner reads .env into every job's environment: point `docker` at the rootless socket.
  local env_file="${RUNNER_DIR}/.env"
  touch "${env_file}"
  sed -i '/^DOCKER_HOST=/d' "${env_file}"
  echo "DOCKER_HOST=unix:///run/user/${uid}/docker.sock" >>"${env_file}"
  chown "${RUNNER_USER}:${RUNNER_USER}" "${env_file}"

  if [[ -z "$(service_name)" ]]; then
    (cd "${RUNNER_DIR}" && ./svc.sh install "${RUNNER_USER}" >/dev/null)
  fi
  local svc
  svc="$(service_name)"
  # Jobs need the rootless daemon, which lives in the user's systemd instance.
  install -d "/etc/systemd/system/${svc}.d"
  cat >"/etc/systemd/system/${svc}.d/rootless-docker.conf" <<EOF
[Unit]
Wants=user@${uid}.service
After=user@${uid}.service
EOF
  systemctl daemon-reload
  systemctl enable --now "${svc}" >/dev/null
  systemctl restart "${svc}"
  echo "  ✓ ${svc} $(systemctl is-active "${svc}")"
}

case "${ACTION}" in
  setup) setup ;;
  remove) remove ;;
  *)
    echo "usage: $0 setup|remove  (token on stdin)" >&2
    exit 1
    ;;
esac
