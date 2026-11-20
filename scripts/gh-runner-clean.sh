#!/usr/bin/env bash
# =============================================================================
# Trim what a self-updating Actions runner leaves behind (cron/docker-prune, daily, root).
#
# Each self-update of a runner (it follows GitHub's latest release, docs/gh-runner.md) keeps the
# previous `bin.<ver>` / `externals.<ver>` beside the current ones and leaves the downloaded
# package in `_work/_update`: ~1.3 GB per runner and update, ~8 GB across the six runners on
# 2026-11-17 (measured, issue_2033). Nothing reads them again — the `bin` and `externals`
# symlinks name the live pair, and a runner that updates fetches a fresh package.
#
# Deletes, per runner under $RUNNERS_DIR:
#   - bin.* / externals.* directories the two symlinks do not point at
#   - _work/_update
# only when untouched for a day, so an update in flight (it writes both) is never cut.
#   - the per-toolchain build caches of a toolchain bump (`$CACHE_DIR/<repo>/<runner>/<toolchain>`):
#     every toolchain dir but the newest one per runner, once untouched for a day. weatherorb's
#     cargo target is 7.5 to 8 GB per runner and toolchain, so a bump left 3 x 1.3 GB behind
#     (measured 2026-11-20, issue_2627); the bumped toolchain never reads the old target again.
# Job work directories and the live toolchain's cache are left alone: they are bounded
# by one checkout per runner and repo (actions/checkout replaces it) and warm caches pay off.
#
# Usage: gh-runner-clean.sh   (root, or the gh-runner user)
# =============================================================================
set -euo pipefail

RUNNERS_DIR="${RUNNERS_DIR:-/home/gh-runner/runners}"
CACHE_DIR="${CACHE_DIR:-/home/gh-runner/cache}"
freed=0

remove() {
  local dir="$1" kb
  kb=$(du -sk "$dir" | cut -f1)
  rm -rf "$dir"
  freed=$((freed + kb))
  echo "removed ${dir} ($((kb / 1024)) MB)"
}

shopt -s nullglob
for runner in "$RUNNERS_DIR"/*/; do
  runner="${runner%/}"
  live_bin=$(readlink -f "$runner/bin" 2>/dev/null || true)
  live_ext=$(readlink -f "$runner/externals" 2>/dev/null || true)
  # No symlink = not a layout this script understands: leave the runner alone.
  [[ -n "$live_bin" && -n "$live_ext" ]] || continue

  for dir in "$runner"/bin.* "$runner"/externals.*; do
    [[ -d "$dir" ]] || continue
    [[ "$(readlink -f "$dir")" == "$live_bin" || "$(readlink -f "$dir")" == "$live_ext" ]] && continue
    [[ -z "$(find "$dir" -maxdepth 0 -mtime -1)" ]] || continue
    remove "$dir"
  done

  update="$runner/_work/_update"
  if [[ -d "$update" && -z "$(find "$update" -maxdepth 0 -mtime -1)" ]]; then
    remove "$update"
  fi
done

# Per-toolchain caches: <repo>/<runner>/<toolchain>. The newest dir by mtime is the live toolchain.
for runner_cache in "$CACHE_DIR"/*/*/; do
  runner_cache="${runner_cache%/}"
  newest=""
  for dir in "$runner_cache"/*/; do
    dir="${dir%/}"
    [[ -z "$newest" || "$dir" -nt "$newest" ]] && newest="$dir"
  done
  [[ -n "$newest" ]] || continue
  for dir in "$runner_cache"/*/; do
    dir="${dir%/}"
    [[ "$dir" != "$newest" ]] || continue
    [[ -z "$(find "$dir" -maxdepth 0 -mtime -1)" ]] || continue
    remove "$dir"
  done
done

echo "freed $((freed / 1024)) MB"
