#!/usr/bin/env bash
# =============================================================================
# Factory leads' scratch on the VPS: ~/exp<issue> and ~/agw<issue> (cron/docker-prune 04:45, root).
#
# A lead's experiment dir outlives its Issue: nothing else removes it, and a container leaves
# root-owned files in it that the lead's own user cannot (measured 2026-11-20 and 2026-11-21:
# 24 GB across 8 dirs, 6.5 GB of closed Issues removed by hand). Per dir, the Issue decides:
#   - closed (named by --closed, or `factory issue show issue_<n>` says so)  -> removed, any age
#   - the factory answers and the Issue is not closed                         -> kept, any age
#   - the factory cannot say (no CLI on this host, an error)                  -> removed once no file
#     in it changed for EXP_DAYS days; the newest file decides, not the dir's mtime
# The VPS has no factory CLI today, so the third rule is what runs here; the software-factory host trim
# can pass the closed Issue ids it knows: exp-sweep.sh --closed 2858 2860
#
# Only directories named exp<digits> or agw<digits> under EXP_ROOT are touched; a symlink is skipped.
# Root removes what a container wrote. One line per dir, then a total.
#
# Usage: exp-sweep.sh [--closed <issue-number>...]
# Env: EXP_ROOT (/home/jkrumm), EXP_DAYS (2), EXP_SWEEP_FACTORY (factory), EXP_SWEEP_DRY=1 (decide, remove nothing)
# =============================================================================
set -euo pipefail

EXP_ROOT="${EXP_ROOT:-/home/jkrumm}"
EXP_DAYS="${EXP_DAYS:-2}"
FACTORY="${EXP_SWEEP_FACTORY:-factory}"
closed_ids=" "

if [[ "${1:-}" == "--closed" ]]; then
  shift
  for id in "$@"; do closed_ids+="${id#issue_} "; done
elif [[ $# -gt 0 ]]; then
  echo "usage: exp-sweep.sh [--closed <issue-number>...]" >&2
  exit 2
fi

with_timeout() { # seconds, command...; no timeout binary (macOS) = no limit
  if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi
}

state_of() { # closed | open | unknown
  local id="$1" state=""
  if [[ "$closed_ids" == *" $id "* ]]; then echo closed; return; fi
  if command -v "$FACTORY" >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    state=$(with_timeout 30 "$FACTORY" issue show "issue_$id" 2>/dev/null | with_timeout 10 jq -r '.state // empty' 2>/dev/null) || state=""
  fi
  if [[ "$state" == closed ]]; then echo closed; elif [[ -n "$state" ]]; then echo open; else echo unknown; fi
}

removed=0 kept=0 failed=0 freed_kb=0
shopt -s nullglob
for dir in "$EXP_ROOT"/exp[0-9]* "$EXP_ROOT"/agw[0-9]*; do
  name="${dir##*/}"
  [[ -d "$dir" && ! -L "$dir" ]] || continue
  id="${name#exp}"; id="${id#agw}"
  [[ "$id" =~ ^[0-9]+$ ]] || continue

  state=$(state_of "$id")
  case "$state" in
    open) echo "kept $name: Issue $id is not closed"; kept=$((kept + 1)); continue ;;
    unknown)
      if [[ -n "$(find "$dir" -mtime "-$EXP_DAYS" -print -quit)" ]]; then
        echo "kept $name: Issue $id unknown to the factory, a file changed within $EXP_DAYS days"; kept=$((kept + 1)); continue
      fi
      reason="Issue $id unknown to the factory, idle $EXP_DAYS days" ;;
    closed) reason="Issue $id closed" ;;
  esac

  kb=$(du -sk "$dir" | cut -f1)
  if [[ "${EXP_SWEEP_DRY:-}" == "1" ]]; then
    echo "would remove $name ($((kb / 1024)) MB): $reason"; removed=$((removed + 1)); continue
  fi
  rm -rf "$dir" 2>/dev/null || true
  if [[ -e "$dir" ]]; then
    echo "FAILED $name: could not remove all of it ($reason); root needed for container-written files"; failed=$((failed + 1))
  else
    echo "removed $name ($((kb / 1024)) MB): $reason"; removed=$((removed + 1)); freed_kb=$((freed_kb + kb))
  fi
done

echo "exp-sweep: $removed removed, $kept kept, $failed failed, freed $((freed_kb / 1024)) MB"
[[ "$failed" -eq 0 ]]
