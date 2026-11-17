#!/usr/bin/env bash
# Add the optional browser demo without redeploying the private application or runners.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[[ $# -ge 1 && $# -le 2 && ( $# -eq 1 || "$2" == "--what-if" ) ]] ||
  die "Usage: $0 <browser-ipv4/32|--public> [--what-if]"
browser_cidr=$1
public_access=false
validate_host_cidr() {
  local cidr=$1 octet
  local -a octets
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/32$ ]] ||
    die "Use one explicit IPv4 /32 address, never a broad network: $cidr"
  IFS=. read -r -a octets <<< "${cidr%/32}"
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ && "$octet" -le 255 ]] ||
      die "Invalid IPv4 address: $cidr"
  done
}
if [[ "$browser_cidr" == "--public" ]]; then
  public_access=true
  browser_cidr="0.0.0.0/0"
else
  validate_host_cidr "$browser_cidr"
fi
require SUBSCRIPTION_ID LOCATION RESOURCE_GROUP POC_PREFIX ACA_APP ACR_LOGIN_SERVER \
  DEPLOY_CLIENT_ID GH_OWNER GH_REPO
DEMO_ACA_APP=${DEMO_ACA_APP:-"$ACA_APP-demo"}
[[ "$DEMO_ACA_APP" != "$ACA_APP" ]] || die "Demo and private application names must differ"
az account set --subscription "$SUBSCRIPTION_ID"
cd "$POC_DIR"

runner_ip=$(az network public-ip show --resource-group "$RESOURCE_GROUP" \
  --name "pip-natgw-$POC_PREFIX" --query ipAddress -o tsv)
validate_host_cidr "$runner_ip/32"
image=$(az containerapp show --resource-group "$RESOURCE_GROUP" --name "$ACA_APP" \
  --query 'properties.template.containers[0].image' -o tsv)
[[ "$image" == "$ACR_LOGIN_SERVER/"* && "$image" =~ @sha256:[0-9a-f]{64}$ ]] ||
  die "The private app must already run a digest-pinned image from the private registry"
deploy_app=true
deploy_subnet=true
subnet=$(az network vnet subnet list --resource-group "$RESOURCE_GROUP" --vnet-name "vnet-$POC_PREFIX" \
  --query "[?name=='snet-aca-demo'].id | [0]" -o tsv)
if [[ -n "$subnet" ]]; then deploy_subnet=false; fi
existing=$(az resource list --resource-group "$RESOURCE_GROUP" \
  --resource-type Microsoft.App/containerApps --query "[?name=='$DEMO_ACA_APP'].id | [0]" -o tsv)
if [[ -n "$existing" ]]; then
  deploy_app=false
  expected_environment="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.App/managedEnvironments/cae-$POC_PREFIX-demo"
  actual_environment=$(az containerapp show --resource-group "$RESOURCE_GROUP" --name "$DEMO_ACA_APP" \
    --query properties.managedEnvironmentId -o tsv)
  [[ "${actual_environment,,}" == "${expected_environment,,}" ]] ||
    die "Existing demo app belongs to another environment; refusing to modify it"
  rules=$(az containerapp ingress access-restriction list --resource-group "$RESOURCE_GROUP" --name "$DEMO_ACA_APP")
  jq -e 'length == 0 or (length == 2 and all(.[]; .action == "Allow" and
    (.name == "allowed-0" or .name == "allowed-1")))' <<< "$rules" >/dev/null ||
    die "Unexpected demo access rules; review them manually before changing the allow list"
fi

jq -n --arg location "$LOCATION" --arg prefix "$POC_PREFIX" --arg app "$DEMO_ACA_APP" \
  --arg image "$image" --arg registry "$ACR_LOGIN_SERVER" --arg browser "$browser_cidr" \
  --arg runner "$runner_ip/32" --argjson create "$deploy_app" --argjson subnet "$deploy_subnet" \
  --argjson public "$public_access" \
  '{location:{value:$location},prefix:{value:$prefix},appName:{value:$app},
    image:{value:$image},registryLoginServer:{value:$registry},browserCidr:{value:$browser},
    runnerCidr:{value:$runner},deployApp:{value:$create},
    deploySubnet:{value:$subnet},publicAccess:{value:$public}}' > .state/demo.parameters.json

if [[ "${2:-}" == "--what-if" ]]; then
  log "Preview the dedicated subnet and separate demo; no Azure or GitHub changes"
  az deployment group what-if --resource-group "$RESOURCE_GROUP" --name browser-demo \
    --template-file infra/public-demo.bicep --parameters @.state/demo.parameters.json
  exit 0
fi

log "Provision only the new subnet, separate environment and Consumption demo"
az deployment group create --resource-group "$RESOURCE_GROUP" --name browser-demo \
  --template-file infra/public-demo.bicep --parameters @.state/demo.parameters.json --output none

if [[ "$deploy_app" == true ]]; then
  az containerapp ingress traffic set --resource-group "$RESOURCE_GROUP" --name "$DEMO_ACA_APP" \
    --revision-weight "$DEMO_ACA_APP--bootstrap=100" --output none
else
  log "Preserve the existing demo image and traffic; update only its access rules"
  if [[ "$public_access" == true ]]; then
    while IFS= read -r rule; do
      az containerapp ingress access-restriction remove --resource-group "$RESOURCE_GROUP" --name "$DEMO_ACA_APP" \
        --rule-name "$rule" --output none
    done < <(jq -r '.[].name' <<< "$rules")
  else
    for entry in "allowed-0=$browser_cidr" "allowed-1=$runner_ip/32"; do
      az containerapp ingress access-restriction set --resource-group "$RESOURCE_GROUP" --name "$DEMO_ACA_APP" \
        --rule-name "${entry%%=*}" --ip-address "${entry#*=}" --action Allow --output none
    done
  fi
fi
app_id="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.App/containerApps/$DEMO_ACA_APP"
assignments=$(az role assignment list --assignee "$DEPLOY_CLIENT_ID" --scope "$app_id" \
  --role "Container Apps Contributor" --query 'length(@)' -o tsv)
if [[ "$assignments" == 0 ]]; then
  principal=$(az ad sp show --id "$DEPLOY_CLIENT_ID" --query id -o tsv)
  az role assignment create --assignee-object-id "$principal" --assignee-principal-type ServicePrincipal \
    --role "Container Apps Contributor" --scope "$app_id" --output none
fi
fqdn=$(az containerapp show --resource-group "$RESOURCE_GROUP" --name "$DEMO_ACA_APP" \
  --query properties.configuration.ingress.fqdn -o tsv)
save_state DEMO_ACA_APP "$DEMO_ACA_APP"
save_state DEMO_APP_FQDN "$fqdn"
save_state DEMO_ALLOWED_CIDR "$browser_cidr"
save_state DEMO_PUBLIC_ACCESS "$public_access"
gh variable set DEMO_ACA_APP --repo "$GH_OWNER/$GH_REPO" --body "$DEMO_ACA_APP"
gh variable set DEMO_APP_FQDN --repo "$GH_OWNER/$GH_REPO" --body "$fqdn"
gh variable set DEMO_PUBLIC_ACCESS --repo "$GH_OWNER/$GH_REPO" --body "$public_access"
gh variable set DEMO_DEPLOYMENT_ENABLED --repo "$GH_OWNER/$GH_REPO" --body true
if [[ "$public_access" == true ]]; then
  log "Demo: https://$fqdn (PUBLIC HTTPS: no login or IP restrictions; hello-world content only)"
else
  log "Demo: https://$fqdn (browser $browser_cidr; runner $runner_ip/32)"
fi
log "The next approved release updates both apps. The registry and original app remain private."
