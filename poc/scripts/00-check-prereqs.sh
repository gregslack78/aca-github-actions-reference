#!/usr/bin/env bash
# Step 0: check prerequisites; installs CLI components and registers providers when needed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require SUBSCRIPTION_ID LOCATION RESOURCE_GROUP POC_PREFIX SSH_PUBLIC_KEY_FILE GH_OWNER GH_REPO GH_REVIEWER \
  VM_SIZE BUILD_INSTANCE_COUNT DEPLOY_INSTANCE_COUNT

failed=0
fail() { printf '  [FAIL] %s\n' "$*"; failed=1; }
ok() { printf '  [ ok ] %s\n' "$*"; }

log "Tools"
for tool in az gh git curl jq; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool found"; else fail "$tool not found on PATH"; fi
done
[[ $failed -eq 0 ]] || die "Install the missing tools (see POC.md, section 'Before you start')."

log "Azure sign-in and subscription"
az account show >/dev/null 2>&1 || die "Not signed in to Azure. Run: az login"
az account set --subscription "$SUBSCRIPTION_ID"
tenant=$(az account show --query tenantId -o tsv)
ok "subscription $SUBSCRIPTION_ID, tenant $tenant"
save_state TENANT_ID "$tenant"
if ! az bicep version >/dev/null 2>&1; then
  az bicep install
fi
ok "Bicep $(az bicep version 2>/dev/null | head -n 1)"
az extension add --name containerapp --upgrade --only-show-errors >/dev/null
ok "Azure CLI containerapp extension installed"

log "Resource providers"
for provider in Microsoft.App Microsoft.ContainerRegistry Microsoft.Compute Microsoft.Network \
  Microsoft.OperationalInsights Microsoft.ManagedIdentity Microsoft.Authorization; do
  state=$(az provider show --namespace "$provider" --query registrationState -o tsv)
  if [[ "$state" != Registered ]]; then
    az provider register --namespace "$provider" --wait >/dev/null
    ok "$provider registered (was $state)"
  else
    ok "$provider already registered"
  fi
done

log "Region, VM size and vCPU quota ($LOCATION, $VM_SIZE)"
# 'az vm list-skus' is slow and hides restricted sizes, so ask the SKU API directly.
sku_url="https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Compute/skus?api-version=2021-07-01"
sku=$(az rest --method get --url "$sku_url" --url-parameters "\$filter=location eq '$LOCATION'" \
  --query "value[?resourceType=='virtualMachines' && name=='$VM_SIZE'] | [0]" -o json)
family=$(jq -r '.family // empty' <<< "$sku")
restricted=$(jq '[.restrictions[]? | select(.type == "Location")] | length' <<< "$sku")
cores=$(jq -r '[.capabilities[]? | select(.name == "vCPUs") | .value][0] // empty' <<< "$sku")
if [[ -z "$family" ]]; then
  fail "$VM_SIZE is not offered in $LOCATION. Choose another VM_SIZE or LOCATION."
elif [[ "$restricted" != 0 ]]; then
  fail "$VM_SIZE is restricted for this subscription in $LOCATION (NotAvailableForSubscription). Choose another LOCATION or VM_SIZE, or request access."
else
  ok "$VM_SIZE is available in $LOCATION"
  [[ "$cores" =~ ^[1-9][0-9]*$ ]] || die "Could not determine vCPUs for $VM_SIZE; quota has not been verified."
  needed=$(( (BUILD_INSTANCE_COUNT + DEPLOY_INSTANCE_COUNT) * cores ))
  usage=$(az vm list-usage --location "$LOCATION" -o json)
  for quota in "$family" cores; do
    limit=$(jq -r --arg quota "$quota" '[.[] | select(.name.value == $quota)][0].limit // empty' <<< "$usage")
    used=$(jq -r --arg quota "$quota" '[.[] | select(.name.value == $quota)][0].currentValue // empty' <<< "$usage")
    if [[ ! "$limit" =~ ^[0-9]+$ || ! "$used" =~ ^[0-9]+$ ]]; then
      fail "Could not read quota $quota; capacity has not been verified."
    elif (( limit - used < needed )); then
      fail "Need $needed vCPUs for $quota but only $((limit - used)) are free. Request quota or reduce instance counts."
    else
      ok "vCPU quota $quota ($((limit - used)) free, $needed needed)"
    fi
  done
fi

log "SSH public key"
[[ -f "$SSH_PUBLIC_KEY_FILE" ]] || fail "$SSH_PUBLIC_KEY_FILE not found. Create one with: ssh-keygen -t ed25519"
[[ ! -f "$SSH_PUBLIC_KEY_FILE" ]] || ok "$SSH_PUBLIC_KEY_FILE"

log "Entra permissions"
if az ad app list --display-name "poc-permission-probe-does-not-exist" --query '[0].appId' -o tsv >/dev/null 2>&1; then
  ok "can read app registrations (creating them also needs the Application Developer role or similar)"
else
  fail "cannot query Entra app registrations. You need permission to create app registrations."
fi

log "GitHub"
gh auth status >/dev/null 2>&1 || die "Not signed in to GitHub. Run: gh auth login"
login=$(gh api user --jq .login)
ok "signed in as $login"
if gh api "users/$GH_REVIEWER" --jq .login >/dev/null 2>&1; then ok "reviewer $GH_REVIEWER exists"; else fail "GitHub user $GH_REVIEWER not found"; fi
if [[ "$login" != "$GH_OWNER" ]]; then
  if gh api "orgs/$GH_OWNER" --jq .login >/dev/null 2>&1; then
    ok "$GH_OWNER is an organization; you need permission to create repositories in it"
  else
    fail "GH_OWNER=$GH_OWNER is neither your login nor an organization you can see"
  fi
fi

[[ $failed -eq 0 ]] || die "Fix the items marked [FAIL] and run this script again."
printf '\nAll checks passed. Next: scripts/01-deploy-infra.sh\n'
