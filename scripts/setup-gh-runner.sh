#!/usr/bin/env bash
# =============================================================================
# Self-hosted GitHub Actions runners for jkrumm's PRIVATE repos — one registration per repo.
# Idempotent. Run via make (it sudo's this script), from a machine with an authenticated `gh`:
#
#   R=jkrumm/<repo>
#   gh api -X POST repos/$R/actions/runners/registration-token --jq .token \
#     | ssh vps "cd ~/vps && make gh-runner-setup ENV=prod REPO=$R"
#   gh api -X POST repos/$R/actions/runners/remove-token --jq .token \
#     | ssh vps "cd ~/vps && make gh-runner-remove ENV=prod REPO=$R"
#
# N=<n> (default 1) adds or removes a further instance of the same repo (`vps-<repo>-<n>`), so
# its parallel jobs stop queuing behind each other; gh-runner-sync.sh keeps the per-repo count.
#
# `make gh-runner-sync` (scripts/gh-runner-sync.sh) does the first for every private repo that
# has workflows and no runner yet. The token travels over stdin (never ssh/make argv); only
# config.sh itself takes it as an argument, for the seconds it runs. A personal GitHub account
# has no account-level runners, hence one registration per repo. Model + lifecycle:
# docs/gh-runner.md.
#
# Isolation: the `gh-runner` system user is NOT in the docker or sudo groups. Jobs build images
# against its own ROOTLESS Docker daemon (user namespace, ~gh-runner/.local/share/docker), so a
# job can neither reach the prod daemon (root-equivalent: every container, every env secret) nor
# read /home/<deploy-user> (0750, re-asserted below) where the op-injected apps/*/.env live.
# All of this host's runners share that user and daemon: the repos have one owner, the boundary
# that matters is runner ↔ prod.
# =============================================================================
set -euo pipefail

ACTION="${1:-}"
GH_REPO="${2:-}"
INSTANCE="${3:-1}"
RUNNER_USER="gh-runner"
RUNNER_LABELS="vps"
# Install version — runners self-update after registration (one with updates disabled stops
# receiving jobs ~30 days after the next release), so this pins first install only.
RUNNER_VERSION="2.338.0"
RUNNER_SHA256="af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32"
# Distinct from the deploy user's 100000:65536 block.
SUBID_RANGE="200000-265535"

die() {
  echo "✗ $*" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || die "run as root (sudo)"
# Leading alphanumeric: no `.`/`..` segment can turn RUNNER_DIR (rm -rf'd by remove) into a parent.
[[ "${GH_REPO}" =~ ^jkrumm/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "REPO=jkrumm/<repo> required (got '${GH_REPO}')"
[[ "${INSTANCE}" =~ ^[1-9]$ ]] || die "N=1..9 required (got '${INSTANCE}')"

REPO_NAME="${GH_REPO#*/}"
RUNNER_NAME="vps-${REPO_NAME}"
RUNNER_HOME="/home/${RUNNER_USER}"
RUNNER_DIR="${RUNNER_HOME}/runners/${REPO_NAME}"
# Instance 1 keeps the original name and directory. `@` cannot occur in a repo name, so no
# instance directory collides with another repo's.
if [[ "${INSTANCE}" != "1" ]]; then
  RUNNER_NAME="vps-${REPO_NAME}-${INSTANCE}"
  RUNNER_DIR="${RUNNER_DIR}@${INSTANCE}"
fi
WATCHDOG_SRC="$(dirname "$(readlink -f "$0")")/gh-runner-watchdog.sh"

read_token() {
  local token=""
  [[ -t 0 ]] || IFS= read -r token || true
  [[ -n "${token}" ]] || die "pipe a $1 token on stdin (see the header of $0)"
  printf '%s' "${token}"
}

as_runner() {
  local uid
  uid="$(id -u "${RUNNER_USER}")"
  runuser -u "${RUNNER_USER}" -- env HOME="${RUNNER_HOME}" XDG_RUNTIME_DIR="/run/user/${uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" "$@"
}

service_name() {
  if [[ -f "${RUNNER_DIR}/.service" ]]; then
    cat "${RUNNER_DIR}/.service"
  fi
}

# A runner on a public repo runs any fork PR's code on the prod host. Fails closed: the
# unauthenticated API must answer 404 (how it reports a private repo); a 200 means public, and
# anything else (rate limit, outage) refuses to register. Called before first registration only.
assert_private() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://api.github.com/repos/${GH_REPO}" || true)"
  case "${code}" in
    404) ;;
    200) die "${GH_REPO} is PUBLIC — never register a self-hosted runner on a public repo" ;;
    *) die "could not confirm ${GH_REPO} is private (GitHub API answered '${code}') — retry later" ;;
  esac
}

remove() {
  if [[ ! -d "${RUNNER_DIR}" ]]; then
    echo "  ${RUNNER_DIR} does not exist — nothing to remove"
    return
  fi
  # Tolerates a half-installed or half-removed runner: every step is skipped once done.
  local token="" svc
  [[ -f "${RUNNER_DIR}/.runner" ]] && token="$(read_token remove)"
  svc="$(service_name)"
  if [[ -n "${svc}" ]]; then
    if [[ -f "/etc/systemd/system/${svc}" ]]; then
      (cd "${RUNNER_DIR}" && { ./svc.sh stop || true; } && ./svc.sh uninstall)
    fi
    rm -rf "/etc/systemd/system/${svc}.d"
    systemctl daemon-reload
  fi
  if [[ -n "${token}" ]]; then
    (cd "${RUNNER_DIR}" && as_runner ./config.sh remove --token "${token}")
  fi
  rm -rf "${RUNNER_DIR}"
  echo "  ✓ ${RUNNER_NAME} unregistered, its service and directory removed (user + rootless Docker kept)"
}

# Auto-recovery from the listener's multi-hour reconnect back-off (scripts/gh-runner-watchdog.sh).
# Root runs a root-owned copy, never the deploy user's checkout.
ensure_watchdog() {
  install -o root -g root -m 0755 "${WATCHDOG_SRC}" /usr/local/sbin/gh-runner-watchdog
  local unit=/etc/systemd/system/gh-runner-watchdog
  local svc_body timer_body
  svc_body="$(printf '[Unit]\nDescription=Restart GitHub Actions runners stuck in reconnect back-off\n\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/gh-runner-watchdog')"
  timer_body="$(printf '[Unit]\nDescription=Check GitHub Actions runners every 5 minutes\n\n[Timer]\nOnBootSec=5min\nOnUnitActiveSec=5min\n\n[Install]\nWantedBy=timers.target')"
  if [[ "$(cat "${unit}.service" 2>/dev/null)" != "${svc_body}" || "$(cat "${unit}.timer" 2>/dev/null)" != "${timer_body}" ]]; then
    printf '%s\n' "${svc_body}" >"${unit}.service"
    printf '%s\n' "${timer_body}" >"${unit}.timer"
    systemctl daemon-reload
  fi
  systemctl enable --now --quiet gh-runner-watchdog.timer
  echo "  ✓ gh-runner-watchdog.timer active"
}

ensure_user_and_docker() {
  # NEVER let this upgrade the prod Docker packages: an unpinned `apt-get install
  # docker-ce-rootless-extras` drags docker-ce to the latest release and restarts dockerd, and
  # with live-restore every socket-proxy keeps a stale docker.sock mount (RollHook, Traefik's
  # Docker provider and Watchtower all go blind — 2026-10-14). Install only what is missing,
  # rootless-extras pinned to the docker-ce version already running.
  local pkgs=(--no-upgrade uidmap slirp4netns)
  if ! dpkg-query -W -f '${Status}' docker-ce-rootless-extras 2>/dev/null | grep -q 'install ok installed'; then
    pkgs+=("docker-ce-rootless-extras=$(dpkg-query -W -f '${Version}' docker-ce)")
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" </dev/null >/dev/null

  if id "${RUNNER_USER}" >/dev/null 2>&1; then
    echo "  ${RUNNER_USER} already exists"
  else
    adduser --system --group --disabled-password --shell /bin/bash \
      --home "${RUNNER_HOME}" --gecos "GitHub Actions runners (private repos)" "${RUNNER_USER}"
    echo "  ✓ created ${RUNNER_USER}"
  fi

  # Re-assert the no-privilege invariants on every run (drift from a manual edit).
  for grp in docker sudo; do
    if id -nG "${RUNNER_USER}" | tr ' ' '\n' | grep -qx "${grp}"; then
      gpasswd -d "${RUNNER_USER}" "${grp}"
    fi
  done
  chmod 0750 "${RUNNER_HOME}"
  local deploy_user deploy_home
  deploy_user="${SUDO_USER:-jkrumm}"
  deploy_home="$(getent passwd "${deploy_user}" | cut -d: -f6)"
  chmod o-rwx "${deploy_home}"
  echo "  ✓ ${deploy_home} not world-traversable"

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
  [[ -S "/run/user/${uid}/bus" ]] || die "${RUNNER_USER}'s systemd instance never came up (check user@${uid}.service)"

  if [[ ! -f "${RUNNER_HOME}/.config/systemd/user/docker.service" ]]; then
    as_runner dockerd-rootless-setuptool.sh install
  fi
  as_runner systemctl --user enable --now docker.service >/dev/null
  as_runner env DOCKER_HOST="unix:///run/user/${uid}/docker.sock" \
    docker info --format '  ✓ rootless Docker {{.ServerVersion}} ({{.SecurityOptions}})'
}

setup() {
  # Read the token before anything else touches stdin (apt and installdependencies.sh would eat it).
  local token=""
  if [[ ! -f "${RUNNER_DIR}/.runner" ]]; then
    token="$(read_token registration)"
    assert_private
  fi
  ensure_user_and_docker
  ensure_watchdog

  local uid
  uid="$(id -u "${RUNNER_USER}")"

  if [[ ! -x "${RUNNER_DIR}/config.sh" ]]; then
    local tarball log
    tarball="$(mktemp)"
    log="$(mktemp)"
    curl -fsSL --connect-timeout 20 --max-time 600 -o "${tarball}" \
      "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
    echo "${RUNNER_SHA256}  ${tarball}" | sha256sum -c --quiet
    install -d -o "${RUNNER_USER}" -g "${RUNNER_USER}" -m 0750 "${RUNNER_HOME}/runners" "${RUNNER_DIR}"
    runuser -u "${RUNNER_USER}" -- tar -xzf - -C "${RUNNER_DIR}" <"${tarball}"
    rm -f "${tarball}"
    if ! DEBIAN_FRONTEND=noninteractive "${RUNNER_DIR}/bin/installdependencies.sh" </dev/null >"${log}" 2>&1; then
      cat "${log}" >&2
      rm -f "${log}"
      die "installdependencies.sh failed"
    fi
    rm -f "${log}"
    echo "  ✓ runner ${RUNNER_VERSION} unpacked into ${RUNNER_DIR} (sha256 verified)"
  fi

  local registered_now=0
  if [[ -f "${RUNNER_DIR}/.runner" ]]; then
    echo "  ${RUNNER_NAME} already registered"
  else
    registered_now=1
    (cd "${RUNNER_DIR}" && as_runner ./config.sh --unattended --replace \
      --url "https://github.com/${GH_REPO}" --token "${token}" \
      --name "${RUNNER_NAME}" --labels "${RUNNER_LABELS}" --work _work)
    echo "  ✓ registered ${RUNNER_NAME} on ${GH_REPO} (labels: self-hosted, Linux, X64, ${RUNNER_LABELS})"
  fi

  # The runner loads its install dir's .env into every job: point `docker` at the rootless socket.
  # Track whether anything the running service reads changed, so a re-run does not restart it
  # (and kill an in-flight job) for nothing.
  local changed="${registered_now}" env_file="${RUNNER_DIR}/.env" want
  want="DOCKER_HOST=unix:///run/user/${uid}/docker.sock"
  touch "${env_file}"
  if ! grep -qx "${want}" "${env_file}"; then
    sed -i '/^DOCKER_HOST=/d' "${env_file}"
    echo "${want}" >>"${env_file}"
    changed=1
  fi
  chown "${RUNNER_USER}:${RUNNER_USER}" "${env_file}"

  if [[ -z "$(service_name)" ]]; then
    (cd "${RUNNER_DIR}" && ./svc.sh install "${RUNNER_USER}" >/dev/null)
    changed=1
  fi
  local svc
  svc="$(service_name)"
  [[ -n "${svc}" ]] || die "svc.sh did not record a systemd unit for ${RUNNER_NAME}"

  # Jobs need the rootless daemon, which lives in the user's systemd instance.
  local dropin="/etc/systemd/system/${svc}.d/rootless-docker.conf" dropin_body
  dropin_body="$(printf '[Unit]\nWants=user@%s.service\nAfter=user@%s.service' "${uid}" "${uid}")"
  if [[ "$(cat "${dropin}" 2>/dev/null)" != "${dropin_body}" ]]; then
    install -d "$(dirname "${dropin}")"
    printf '%s\n' "${dropin_body}" >"${dropin}"
    systemctl daemon-reload
    changed=1
  fi

  systemctl enable --quiet "${svc}"
  if [[ "${changed}" -eq 1 ]]; then
    systemctl restart "${svc}"
  elif ! systemctl is-active --quiet "${svc}"; then
    systemctl start "${svc}"
  fi
  systemctl is-active --quiet "${svc}" || die "${svc} is not active — journalctl -u ${svc} -n 50"
  echo "  ✓ ${svc} active"
}

case "${ACTION}" in
  setup) setup ;;
  remove) remove ;;
  *) die "usage: $0 setup|remove jkrumm/<repo> [instance]  (token on stdin)" ;;
esac
