#!/usr/bin/env bash
# =============================================================================
# Give every PRIVATE jkrumm repo that has GitHub Actions workflows its runner(s) on the VPS.
# Idempotent: runner names already registered on the repo are skipped, missing ones added. Run where `gh` is
# authenticated (the mini or the MacBook), NOT on the VPS:  make gh-runner-sync  [DRY_RUN=1]
#
# Registration only — each repo's workflows still need `runs-on: [self-hosted, vps]` (a commit in
# that repo). Public repos are never touched here, and setup-gh-runner.sh refuses them again on
# the VPS side. Model: docs/gh-runner.md.
# =============================================================================
set -euo pipefail

OWNER="jkrumm"
DRY_RUN="${DRY_RUN:-0}"
# Runners per repo (default one). A repo whose workflows run several jobs per push (weatherorb:
# four CI jobs plus deploys) otherwise serializes them on one runner. Lowering a count does not
# remove instances — that is `make gh-runner-remove N=<n>`. At most 9 (setup-gh-runner.sh's
# limit). A function, not an associative array: macOS ships bash 3.2.
instances() {
  case "$1" in
    weatherorb) echo 3 ;;
    *) echo 1 ;;
  esac
}

command -v gh >/dev/null || { echo "✗ gh not found — run this where gh is authenticated" >&2; exit 1; }

repos="$(gh repo list "${OWNER}" --visibility private --no-archived --limit 500 --json name --jq '.[].name')"
ok=0 added=0 failed=0

# One repo's failure (API hiccup, ssh drop) must not stop the rest: each body runs in a subshell,
# and the tally at the end is the result. `set -e` is off inside `(…) || …`, so every failure
# path below returns explicitly.
sync_repo() {
  local name="$1" repo="${OWNER}/$1" files runners n r added=0 failed=0
  if ! files="$(gh api "repos/${repo}/contents/.github/workflows" --jq '.[].name' 2>&1)"; then
    grep -q 'HTTP 404' <<<"${files}" && return 3
    echo "  ✗ ${repo}: could not list workflows: ${files}" >&2
    return 1
  fi
  grep -qE '\.ya?ml$' <<<"${files}" || return 3
  runners="$(gh api "repos/${repo}/actions/runners" --jq '.runners[] | "\(.name) \(.status)"')" || {
    echo "  ✗ ${repo}: could not list runners" >&2
    return 1
  }
  for n in $(seq 1 "$(instances "${name}")"); do
    r=0
    sync_instance "${repo}" "${name}" "${n}" "${runners}" || r=$?
    if [[ "${r}" -eq 1 ]]; then failed=1; elif [[ "${r}" -eq 2 ]]; then added=1; fi
  done
  [[ "${failed}" -eq 0 ]] || return 1
  [[ "${added}" -eq 0 ]] || return 2
  return 0
}

# 0 = present, 2 = registered (or would be), 1 = failed.
sync_instance() {
  local repo="$1" name="$2" n="$3" runners="$4" runner="vps-$2" status
  # Same naming rule as setup-gh-runner.sh.
  [[ "${n}" == "1" ]] || runner+="-${n}"
  status="$(awk -v r="${runner}" '$1 == r { print $2 }' <<<"${runners}")"
  if [[ -n "${status}" ]]; then
    echo "  ${repo}: ${runner} already registered (${status})"
    [[ "${status}" == "online" ]] || echo "  ! ${repo}: ${runner} is ${status} — see docs/gh-runner.md → Operate" >&2
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  ${repo}: would register ${runner}"
    return 2
  fi
  echo "→ ${repo}: registering ${runner}"
  if ! gh api -X POST "repos/${repo}/actions/runners/registration-token" --jq .token \
    | ssh vps "cd ~/vps && make gh-runner-setup ENV=prod REPO=${repo} N=${n}"; then
    echo "  ✗ ${repo}: registration of ${runner} failed" >&2
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

echo "repos: ${ok} complete, ${added} $([[ "${DRY_RUN}" == "1" ]] && echo "to register" || echo registered), ${failed} failed"
[[ "${failed}" -eq 0 ]]
