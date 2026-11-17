#!/usr/bin/env bash
# Step 7 (repeatable): check the pieces the pipeline depends on, from the Azure side and from inside the VNet.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require SUBSCRIPTION_ID RESOURCE_GROUP GH_OWNER GH_REPO ACR_NAME ACR_LOGIN_SERVER ACA_APP ACA_APP_FQDN BUILD_VMSS DEPLOY_VMSS

az account set --subscription "$SUBSCRIPTION_ID"

log "Registry network exposure (expect: Disabled)"
az acr show --name "$ACR_NAME" --query '{publicNetworkAccess:publicNetworkAccess,adminUserEnabled:adminUserEnabled,roleAssignmentMode:roleAssignmentMode}' -o table

log "Container App ingress and revisions (expect: Multiple mode, one revision at 100%)"
az containerapp show --name "$ACA_APP" --resource-group "$RESOURCE_GROUP" \
  --query '{mode:properties.configuration.activeRevisionsMode,fqdn:properties.configuration.ingress.fqdn,traffic:properties.configuration.ingress.traffic}' -o json
az containerapp revision list --name "$ACA_APP" --resource-group "$RESOURCE_GROUP" \
  --query '[].{revision:name,traffic:properties.trafficWeight,active:properties.active,health:properties.healthState,image:properties.template.containers[0].image}' -o table

log "From this machine the private app must NOT be reachable (expect: failure)"
if curl --silent --max-time 10 -o /dev/null "https://$ACA_APP_FQDN/" 2>/dev/null; then
  warn "The app answered from outside the VNet. Check the environment is internal."
else
  echo "  not reachable from here: as intended"
fi

log "Runners registered in GitHub"
gh api "repos/$GH_OWNER/$GH_REPO/actions/runners" --jq '.runners[] | "\(.name)\t\(.status)\t\([.labels[].name] | join(","))"' || true

check_vm() {
  local vmss=$1 id output
  shift
  local extra=("$@")
  id=$(az vmss list-instances --resource-group "$RESOURCE_GROUP" --name "$vmss" --query '[0].instanceId' -o tsv)
  log "Inside the VNet: $vmss instance $id"
  output=$(cd "$SCRIPTS_DIR" && az vmss run-command invoke --resource-group "$RESOURCE_GROUP" --name "$vmss" \
    --instance-id "$id" --command-id RunShellScript --scripts @runner-check.remote.sh \
    --parameters "$ACR_LOGIN_SERVER" "$ACA_APP_FQDN" "${extra[@]}" --query 'value[0].message' -o tsv)
  printf '%s\n' "$output"
  grep -q '^CHECK_OK$' <<< "$output" || die "Runner checks failed on $vmss instance $id."
}
check_vm "$BUILD_VMSS" docker
check_vm "$DEPLOY_VMSS"
