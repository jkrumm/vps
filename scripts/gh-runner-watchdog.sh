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

units="$(systemctl list-units 'actions.runner.*' --type=service --state=active --no-legend --plain | awk '{print $1}')"
[[ -n "${units}" ]] || exit 0

broker_up=""
now="$(date +%s)"
restarted=0

while IFS= read -r unit; do
  last="$(journalctl -u "${unit}" -n 300 -o short-unix --no-pager \
    | grep -E 'Runner connect error|Listening for Jobs|Running job|completed with result|reconnected' \
    | tail -1 || true)"
  [[ "${last}" == *"Runner connect error"* ]] || continue
  age=$((now - ${last%%.*}))
  ((age >= STUCK_AFTER_S)) || continue

  # A job in flight means the listener is connected; never kill it.
  systemd-cgls --no-pager -u "${unit}" 2>/dev/null | grep -q 'Runner.Worker' && continue

  if [[ -z "${broker_up}" ]]; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "${BROKER}" || true)"
    broker_up="$([[ "${code}" == "200" ]] && echo yes || echo no)"
  fi
  if [[ "${broker_up}" != "yes" ]]; then
    echo "${unit}: in reconnect back-off for ${age}s, broker still unreachable — waiting"
    continue
  fi

  echo "${unit}: in reconnect back-off for ${age}s with the broker reachable — restarting"
  systemctl restart "${unit}"
  restarted=$((restarted + 1))
done <<<"${units}"

((restarted == 0)) || echo "restarted ${restarted} runner(s)"
