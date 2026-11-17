#!/usr/bin/env bash
# =============================================================================
# Root-disk alert — ntfy topic `alerts` when / is at or above DISK_WARN_PCT (default 80),
# i.e. before the 85 % the owner wants to hear about (issue_2033: 86 % one day after the
# 90 % incident issue_1842, with no alert in between). Runs from cron/disk-watch every 15 min.
#
# Repeats at most every REPEAT_SECS (6 h) while the disk stays above the line, so a slow
# cleanup is not a stream of pushes; a disk that fell back under it resets the state and the
# next crossing alerts at once. The message names the places that grew last time
# (docs/disk.md has the per-directory bounds).
#
# Required env (sourced from /etc/vps/disk-watch.env — see cron/disk-watch):
#   DOMAIN      — apex; ntfy lives at https://ntfy.<DOMAIN>
#   NTFY_TOKEN  — op://common/ntfy/TOKEN
# Optional: DISK_WARN_PCT, DISK_WATCH_STATE (default /var/tmp/disk-watch.state),
#           DISK_WATCH_DRY=1 (print the message, send nothing)
# =============================================================================
set -euo pipefail

WARN_PCT="${DISK_WARN_PCT:-80}"
STATE="${DISK_WATCH_STATE:-/var/tmp/disk-watch.state}"
REPEAT_SECS="${DISK_WATCH_REPEAT_SECS:-21600}"

used_pct=$(df --output=pcent / | tail -n 1 | tr -dc '0-9')
now=$(date +%s)

if (( used_pct < WARN_PCT )); then
  rm -f "$STATE"
  exit 0
fi

last=0
[[ -f "$STATE" ]] && last=$(cat "$STATE" 2>/dev/null || echo 0)
(( now - last >= REPEAT_SECS )) || exit 0

read -r size used avail < <(df -h --output=size,used,avail / | tail -n 1)
msg="/ is ${used_pct}% full (${used} of ${size}, ${avail} free). Prune logs: ~/docker-prune.log and the gh-runner home's docker-prune.log. Bounds: docs/disk.md in the vps repo."

if [[ "${DISK_WATCH_DRY:-}" == "1" ]]; then
  echo "$msg"
  exit 0
fi

# --max-time: an unreachable ntfy must not pile up overlapping cron runs. The state is written
# only after a delivered push, so a failed one is retried at the next run.
curl -fsS --max-time 15 \
  -H "Authorization: Bearer ${NTFY_TOKEN}" \
  -H "Title: VPS disk ${used_pct}%" \
  -H "Priority: high" \
  -H "Tags: floppy_disk,warning" \
  -d "$msg" \
  "https://ntfy.${DOMAIN}/alerts" >/dev/null
echo "$now" > "$STATE"
