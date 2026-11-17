#!/usr/bin/env bash
# Step 4: register every runner VM with GitHub. Runs inside the VMs through 'az vmss run-command',
# so this works from any machine (including Cloud Shell): no VNet access or SSH is needed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require SUBSCRIPTION_ID RESOURCE_GROUP GH_OWNER GH_REPO BUILD_VMSS DEPLOY_VMSS

az account set --subscription "$SUBSCRIPTION_ID"
repo="$GH_OWNER/$GH_REPO"

log "Latest GitHub runner release and its published SHA-256"
version=$(gh api repos/actions/runner/releases/latest --jq '.tag_name' | sed 's/^v//')
body=$(gh api repos/actions/runner/releases/latest --jq '.body')
sha=$(printf '%s' "$body" | sed -n 's/.*actions-runner-linux-x64-[0-9.]*\.tar\.gz <!-- BEGIN SHA linux-x64 -->\([0-9a-f]\{64\}\)<!-- END SHA linux-x64 -->.*/\1/p' | head -n 1)
[[ -n "$version" && "$sha" =~ ^[0-9a-f]{64}$ ]] || die "Could not read the runner version and checksum from the release notes. Look them up on https://github.com/actions/runner/releases and set RUNNER_VERSION and RUNNER_SHA256 (see POC.md troubleshooting)."
echo "  runner $version, sha256 $sha"

# register_pool VMSS LABEL
register_pool() {
  local vmss=$1 label=$2 id token output
  for id in $(az vmss list-instances --resource-group "$RESOURCE_GROUP" --name "$vmss" --query '[].instanceId' -o tsv); do
    log "Registering $vmss instance $id as label $label"
    # One-hour registration token. It appears in the run-command request, so treat it as short-lived.
    token=$(gh api --method POST "repos/$repo/actions/runners/registration-token" --jq .token)
    output=$(cd "$SCRIPTS_DIR" && az vmss run-command invoke --resource-group "$RESOURCE_GROUP" --name "$vmss" \
      --instance-id "$id" --command-id RunShellScript --scripts @runner-register.remote.sh \
      --parameters "$GH_OWNER" "$GH_REPO" "$label" "$version" "$sha" "$token" \
      --query 'value[0].message' -o tsv)
    printf '%s\n' "$output" | sed '/--token/d' | tail -n 12
    grep -q REGISTER_OK <<< "$output" || die "Registration failed on $vmss instance $id. See the output above."
  done
}

register_pool "$BUILD_VMSS" aca-build-vmss
register_pool "$DEPLOY_VMSS" aca-deploy-vmss

log "Runners as GitHub sees them"
gh api "repos/$repo/actions/runners" --jq '.runners[] | "\(.name)\t\(.status)\t\([.labels[].name] | join(","))"'

cat <<EOF

Runners are registered. Each should show 'online'.
Next: scripts/05-publish-pipeline.sh
EOF
