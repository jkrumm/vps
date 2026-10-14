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

for name in ${repos}; do
  repo="${OWNER}/${name}"
  if ! gh api "repos/${repo}/contents/.github/workflows" --jq 'length' >/dev/null 2>&1; then
    continue
  fi
  registered="$(gh api "repos/${repo}/actions/runners" \
    --jq "[.runners[] | select(.name == \"vps-${name}\")] | length")"
  if [[ "${registered}" != "0" ]]; then
    echo "  ${repo}: vps-${name} already registered"
    continue
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  ${repo}: would register vps-${name}"
    continue
  fi
  echo "→ ${repo}: registering vps-${name}"
  gh api -X POST "repos/${repo}/actions/runners/registration-token" --jq .token \
    | ssh vps "cd ~/vps && make gh-runner-setup ENV=prod REPO=${repo}"
done
