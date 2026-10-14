#!/usr/bin/env bash
# =============================================================================
# Restart self-hosted Actions runners stuck in the listener's reconnect back-off.
#
# After a network outage the listener backs off up to ~3 h between broker retries and stays
# offline long after the network is back (2026-10-14: a 30 min peering fault, runners offline
# until restarted by hand). A unit counts as stuck when the last state line it logged is a
# `Runner connect error` older than STUCK_AFTER_S, the broker answers again, and no job is
# running. A restart logs `Listening for Jobs`, so a false positive restarts an idle runner once.
#
# Installed by scripts/setup-gh-runner.sh as /usr/local/sbin/gh-runner-watchdog plus a systemd
# timer (gh-runner-watchdog.timer, every 5 min); its output is in `journalctl -u
# gh-runner-watchdog`. Model: docs/gh-runner.md.
# =============================================================================
set -euo pipefail

STUCK_AFTER_S="${STUCK_AFTER_S:-600}"
BROKER="https://broker.actions.githubusercontent.com/health"
# The listener's own state lines (runner 2.338 wording). If a release rewords them, detection
# stops matching — the per-run summary's `0 in back-off` after an outage is the tell.
STATE_LINES='Runner connect error|Listening for Jobs|Running job|completed with result|reconnected'
STUCK_LINE='Runner connect error'

# A job in flight means the listener is connected; never kill it. Fails closed: an unreadable
# cgroup counts as busy.
job_running() {
  local procs
  procs="$(systemd-cgls --no-pager -u "$1" 2>&1)" || return 0
  grep -q 'Runner.Worker' <<<"${procs}"
}

units="$(systemctl list-units 'actions.runner.*' --type=service --state=active --no-legend --plain | awk '{print $1}')"
[[ -n "${units}" ]] || exit 0

broker_up=""
now="$(date +%s)"
checked=0 stuck=0 restarted=0

while IFS= read -r unit; do
  checked=$((checked + 1))
  last="$(journalctl -u "${unit}" -n 300 -o short-unix --no-pager | grep -E "${STATE_LINES}" | tail -1 || true)"
  [[ "${last}" == *"${STUCK_LINE}"* ]] || continue
  age=$((now - ${last%%.*}))
  ((age >= STUCK_AFTER_S)) || continue
  stuck=$((stuck + 1))
  job_running "${unit}" && continue

  if [[ -z "${broker_up}" ]]; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "${BROKER}" || true)"
    broker_up="$([[ "${code}" == "200" ]] && echo yes || echo no)"
  fi
  if [[ "${broker_up}" != "yes" ]]; then
    echo "${unit}: in reconnect back-off for ${age}s, broker still unreachable — waiting"
    continue
  fi

  # Re-check right before the restart: the broker may just have handed the listener a job.
  job_running "${unit}" && continue
  echo "${unit}: in reconnect back-off for ${age}s with the broker reachable — restarting"
  if systemctl restart "${unit}"; then
    restarted=$((restarted + 1))
  else
    echo "${unit}: restart failed" >&2
  fi
done <<<"${units}"

echo "checked ${checked} runner(s): ${stuck} in back-off, ${restarted} restarted"
