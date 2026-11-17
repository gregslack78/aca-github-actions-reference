#!/usr/bin/env bash
# Step 1: deploy infrastructure; bootstrap the app only when it does not already exist.
# Usage: 01-deploy-infra.sh [--what-if]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require SUBSCRIPTION_ID LOCATION RESOURCE_GROUP POC_PREFIX SSH_PUBLIC_KEY_FILE VM_SIZE \
  BUILD_INSTANCE_COUNT DEPLOY_INSTANCE_COUNT ACA_APP
[[ -f "$SSH_PUBLIC_KEY_FILE" ]] || die "$SSH_PUBLIC_KEY_FILE not found"
[[ $# -eq 0 || ( $# -eq 1 && "$1" == "--what-if" ) ]] || die "Usage: $0 [--what-if]"

az account set --subscription "$SUBSCRIPTION_ID"
SSH_PUBLIC_KEY=$(cat "$SSH_PUBLIC_KEY_FILE")
export SSH_PUBLIC_KEY POC_PREFIX VM_SIZE BUILD_INSTANCE_COUNT DEPLOY_INSTANCE_COUNT ACA_APP
# Relative paths keep this working in Git Bash, where Azure CLI cannot read /c/... style paths.
cd "$POC_DIR"

group_exists=$(az group exists --name "$RESOURCE_GROUP")
deploy_app=true
if [[ "$group_exists" == true ]]; then
  app_id=$(az resource list --resource-group "$RESOURCE_GROUP" \
    --resource-type Microsoft.App/containerApps --query "[?name=='$ACA_APP'].id | [0]" -o tsv)
  if [[ -n "$app_id" ]]; then
    deploy_app=false
    log "Existing app $ACA_APP will not be redeployed; its image, settings and traffic are preserved"
  fi
fi

if [[ "${1:-}" == "--what-if" ]]; then
  [[ "$group_exists" == true ]] || die "What-if needs an existing resource group. Create it explicitly first: az group create --name $RESOURCE_GROUP --location $LOCATION"
  log "What-if (no resources or resource group are created)"
  az deployment group what-if --resource-group "$RESOURCE_GROUP" --name poc-infra \
    --parameters infra/main.bicepparam --parameters deployApp="$deploy_app"
  exit 0
fi

log "Resource group $RESOURCE_GROUP in $LOCATION"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" \
  --tags purpose=github-actions-to-aca-poc --output none

log "Deploying infra/main.bicep (typically 10-15 minutes)"
az deployment group create --resource-group "$RESOURCE_GROUP" --name poc-infra \
  --parameters infra/main.bicepparam --parameters deployApp="$deploy_app" --output none

log "Reading deployment outputs"
output() { az deployment group show --resource-group "$RESOURCE_GROUP" --name poc-infra \
  --query "properties.outputs.$1.value" -o tsv; }
save_state ACR_NAME "$(output registryName)"
save_state ACR_LOGIN_SERVER "$(output registryLoginServer)"
save_state ACA_APP_FQDN "$(output acaAppFqdn)"
save_state ACA_DEFAULT_DOMAIN "$(output acaDefaultDomain)"
save_state ACA_BOOTSTRAP_REVISION "$(output acaBootstrapRevision)"
save_state BUILD_VMSS "$(output buildScaleSetName)"
save_state DEPLOY_VMSS "$(output deployScaleSetName)"
save_state NAT_PUBLIC_IP "$(output natPublicIp)"

if [[ "$deploy_app" == true ]]; then
log "Waiting for revision $ACA_BOOTSTRAP_REVISION to become healthy"
healthy=false
for _ in $(seq 1 60); do
  state=$(az containerapp revision show --name "$ACA_APP" --resource-group "$RESOURCE_GROUP" \
    --revision "$ACA_BOOTSTRAP_REVISION" --query properties.healthState -o tsv 2>/dev/null || true)
  if [[ "$state" == Healthy ]]; then healthy=true; break; fi
  sleep 10
done
[[ "$healthy" == true ]] || die "Bootstrap revision is not healthy. Check: az containerapp logs show -n $ACA_APP -g $RESOURCE_GROUP --type system"

# The release script requires one explicit, named revision at 100% (not 'latest').
log "Pinning 100% of traffic to $ACA_BOOTSTRAP_REVISION"
az containerapp ingress traffic set --name "$ACA_APP" --resource-group "$RESOURCE_GROUP" \
  --revision-weight "$ACA_BOOTSTRAP_REVISION=100" --output none
else
  log "Existing app left unchanged; no bootstrap revision or traffic changes"
fi

cat <<EOF

Infrastructure is deployed.
  Registry         $ACR_LOGIN_SERVER (private endpoint, public access disabled)
  App (private)    https://$ACA_APP_FQDN
  Build runners    $BUILD_VMSS ($BUILD_INSTANCE_COUNT VMs, tools installing in the background)
  Deploy runners   $DEPLOY_VMSS ($DEPLOY_INSTANCE_COUNT VM)
  Outbound IP      $NAT_PUBLIC_IP

Next: scripts/02-entra-and-roles.sh
EOF
