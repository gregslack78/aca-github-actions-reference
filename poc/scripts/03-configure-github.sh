#!/usr/bin/env bash
# Step 3: configure GitHub for the pipeline: repository (if missing), Actions token default,
# the build and production environments, and every variable the workflows read. No secrets are set.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require GH_OWNER GH_REPO GH_REPO_VISIBILITY GH_REVIEWER SUBSCRIPTION_ID TENANT_ID RESOURCE_GROUP \
  ACR_NAME ACR_LOGIN_SERVER IMAGE_REPOSITORY ACA_APP BUILD_CLIENT_ID DEPLOY_CLIENT_ID

repo="$GH_OWNER/$GH_REPO"
prevent_self_review=${GH_PREVENT_SELF_REVIEW:-false}

log "Repository $repo"
if gh repo view "$repo" >/dev/null 2>&1; then
  echo "  already exists"
else
  gh repo create "$repo" "--$GH_REPO_VISIBILITY" --description "POC: GitHub Actions to private Azure Container Apps"
fi

log "Actions defaults: read-only GITHUB_TOKEN, Actions cannot approve pull requests"
gh api --method PUT "repos/$repo/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false >/dev/null

# create_environment NAME [REVIEWER_ID]: restrict deployments to main; add required reviewers if given.
create_environment() {
  local name=$1 reviewer_id=${2:-} body
  if [[ -n "$reviewer_id" ]]; then
    body=$(printf '{"prevent_self_review":%s,"reviewers":[{"type":"User","id":%s}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' \
      "$prevent_self_review" "$reviewer_id")
  else
    body='{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
  fi
  if ! printf '%s' "$body" | gh api --method PUT "repos/$repo/environments/$name" --input - >/dev/null; then
    die "Could not configure environment '$name'. Check repository admin rights and required-reviewer availability for your plan/visibility. Do not remove the production gate or delete the repository. See https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments"
  fi
  if [[ -z "$(gh api "repos/$repo/environments/$name/deployment-branch-policies" --jq '.branch_policies[] | select(.name=="main") | .name')" ]]; then
    gh api --method POST "repos/$repo/environments/$name/deployment-branch-policies" -f name=main -f type=branch >/dev/null
  fi
  echo "  environment $name: branch main only"
}

log "Environments"
reviewer_id=$(gh api "users/$GH_REVIEWER" --jq .id)
create_environment build
create_environment production "$reviewer_id"
echo "  production reviewer: $GH_REVIEWER (prevent self-review: $prevent_self_review)"

# set_var SCOPE NAME VALUE: SCOPE is an environment name, or "repo" for a repository variable.
set_var() {
  local scope=$1 name=$2 value=$3
  if [[ "$scope" == repo ]]; then
    gh variable set "$name" --repo "$repo" --body "$value"
  else
    gh variable set "$name" --repo "$repo" --env "$scope" --body "$value"
  fi
}

log "Variables: build environment"
set_var build AZURE_CLIENT_ID "$BUILD_CLIENT_ID"
set_var build AZURE_TENANT_ID "$TENANT_ID"
set_var build AZURE_SUBSCRIPTION_ID "$SUBSCRIPTION_ID"
set_var build ACR_NAME "$ACR_NAME"
set_var build ACR_LOGIN_SERVER "$ACR_LOGIN_SERVER"
set_var build IMAGE_REPOSITORY "$IMAGE_REPOSITORY"
set_var build BUILD_MODE vmss

log "Variables: production environment"
set_var production AZURE_CLIENT_ID "$DEPLOY_CLIENT_ID"
set_var production AZURE_TENANT_ID "$TENANT_ID"
set_var production AZURE_SUBSCRIPTION_ID "$SUBSCRIPTION_ID"
set_var production ACR_LOGIN_SERVER "$ACR_LOGIN_SERVER"
set_var production IMAGE_REPOSITORY "$IMAGE_REPOSITORY"
set_var production ACA_APP "$ACA_APP"
set_var production ACA_RESOURCE_GROUP "$RESOURCE_GROUP"

log "Variables: repository (runner labels must be repository-level)"
set_var repo BUILD_RUNNER_LABELS '["self-hosted","linux","x64","aca-build-vmss"]'
set_var repo DEPLOY_RUNNER_LABELS '["self-hosted","linux","x64","aca-deploy-vmss"]'

cat <<EOF

GitHub is configured: https://github.com/$repo/settings/environments
Next: scripts/04-register-runners.sh
EOF
