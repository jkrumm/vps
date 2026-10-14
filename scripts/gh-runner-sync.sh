#!/usr/bin/env bash
# =============================================================================
# Give every PRIVATE jkrumm repo that has GitHub Actions workflows its own runner on the VPS.
# Idempotent: repos that already have `vps-<repo>` registered are skipped. Run where `gh` is
# authenticated (the mini or the MacBook), NOT on the VPS:  make gh-runner-sync  [DRY_RUN=1]
#
# Registration only — each repo's workflows still need `runs-on: [self-hosted, vps]` (a commit in
# that repo). Public repos are never touched here, and setup-gh-runner.sh refuses them again on
# the VPS side. Model: docs/gh-runner.md.
# =============================================================================
set -euo pipefail

OWNER="jkrumm"
DRY_RUN="${DRY_RUN:-0}"

command -v gh >/dev/null || { echo "✗ gh not found — run this where gh is authenticated" >&2; exit 1; }

repos="$(gh repo list "${OWNER}" --visibility private --no-archived --limit 500 --json name --jq '.[].name')"
ok=0 added=0 failed=0

# One repo's failure (API hiccup, ssh drop) must not stop the rest: each body runs in a subshell,
# and the tally at the end is the result. `set -e` is off inside `(…) || …`, so every failure
# path below returns explicitly.
sync_repo() {
  local name="$1" repo="${OWNER}/$1" files runner
  if ! files="$(gh api "repos/${repo}/contents/.github/workflows" --jq '.[].name' 2>&1)"; then
    grep -q 'HTTP 404' <<<"${files}" && return 3
    echo "  ✗ ${repo}: could not list workflows: ${files}" >&2
    return 1
  fi
  grep -qE '\.ya?ml$' <<<"${files}" || return 3
  runner="$(gh api "repos/${repo}/actions/runners" \
    --jq ".runners[] | select(.name == \"vps-${name}\") | .status")" || {
    echo "  ✗ ${repo}: could not list runners" >&2
    return 1
  }
  if [[ -n "${runner}" ]]; then
    echo "  ${repo}: vps-${name} already registered (${runner})"
    [[ "${runner}" == "online" ]] || echo "  ! ${repo}: vps-${name} is ${runner} — see docs/gh-runner.md → Operate" >&2
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  ${repo}: would register vps-${name}"
    return 2
  fi
  echo "→ ${repo}: registering vps-${name}"
  if ! gh api -X POST "repos/${repo}/actions/runners/registration-token" --jq .token \
    | ssh vps "cd ~/vps && make gh-runner-setup ENV=prod REPO=${repo}"; then
    echo "  ✗ ${repo}: registration failed" >&2
    return 1
  fi
  return 2
}

while IFS= read -r name; do
  [[ -n "${name}" ]] || continue
  rc=0
  (sync_repo "${name}") || rc=$?
  case "${rc}" in
    0) ok=$((ok + 1)) ;;
    2) added=$((added + 1)) ;;
    3) ;;
    *) failed=$((failed + 1)) ;;
  esac
done <<<"${repos}"

echo "runners: ${ok} present, ${added} $([[ "${DRY_RUN}" == "1" ]] && echo "to register" || echo registered), ${failed} failed"
[[ "${failed}" -eq 0 ]]
