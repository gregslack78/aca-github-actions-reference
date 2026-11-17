#!/usr/bin/env bash
# Step 6: apply the repository protection the guide recommends (section 4.1): a ruleset on main,
# an Actions allow-list with pinned SHAs, fork-PR approval, and secret scanning. Run after step 5,
# because the ruleset blocks direct pushes to main.
# Settings that your GitHub plan does not support are reported and skipped, not silently ignored.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require GH_OWNER GH_REPO

repo="$GH_OWNER/$GH_REPO"
approvals=${GH_REQUIRED_APPROVALS:-0}
codeowners=${GH_REQUIRE_CODE_OWNERS:-false}

# try_api LABEL ARGS...: run a gh api call; report instead of aborting if the plan/permissions refuse it.
try_api() {
  local label=$1 out
  shift
  if out=$("$@" 2>&1 >/dev/null); then
    echo "  [ ok ] $label"
  else
    echo "  [skip] $label: $(printf '%s' "$out" | head -n 1)"
  fi
}

# send_json METHOD ENDPOINT JSON: call the GitHub API with a JSON body.
send_json() {
  printf '%s' "$3" | gh api --method "$1" "$2" --input -
}

log "Ruleset on the default branch: pull request required, no force push, no deletion"
existing=$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name=="protect-main") | .id' 2>/dev/null || true)
if [[ -n "$existing" ]]; then
  echo "  [ ok ] ruleset protect-main already exists (id $existing)"
else
  ruleset=$(cat <<EOF
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": $approvals,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": $codeowners,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false } }
  ]
}
EOF
)
  try_api "ruleset protect-main (approvals: $approvals, code owner review: $codeowners)" \
    send_json POST "repos/$repo/rulesets" "$ruleset"
fi

log "Actions policy: approved actions only, full-SHA pinning, approval for outside contributors"
try_api "allow only selected actions, require SHA pinning" \
  send_json PUT "repos/$repo/actions/permissions" '{"enabled":true,"allowed_actions":"selected","sha_pinning_required":true}'
try_api "allow GitHub-owned actions plus azure/login" \
  send_json PUT "repos/$repo/actions/permissions/selected-actions" \
  '{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":["azure/login@*"]}'
try_api "require approval for all outside contributors' workflow runs" \
  send_json PUT "repos/$repo/actions/permissions/fork-pr-contributor-approval" '{"approval_policy":"all_external_contributors"}'

log "Secret scanning and push protection"
try_api "secret scanning + push protection" \
  send_json PATCH "repos/$repo" \
  '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'

cat <<EOF

Review the result in the repository settings:
  https://github.com/$repo/settings/rules
  https://github.com/$repo/settings/actions
Changes to main now go through pull requests (see the test scenarios in POC.md).
EOF
