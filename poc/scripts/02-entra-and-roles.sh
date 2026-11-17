#!/usr/bin/env bash
# Step 2: create the two Entra app registrations, their GitHub federated credentials, and the
# least-privilege Azure roles (guide section 6). No client secret is created.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require SUBSCRIPTION_ID RESOURCE_GROUP GH_OWNER GH_REPO BUILD_APP_NAME DEPLOY_APP_NAME ACA_APP ACR_NAME TENANT_ID

oidc_policy=$(gh api "repos/$GH_OWNER/$GH_REPO/actions/oidc/customization/sub")
subject_prefix=$(jq -er 'select(.use_default == true) | .sub_claim_prefix | select(type == "string" and length > 0)' \
  <<< "$oidc_policy") ||
  die "Cannot determine the default OIDC subject prefix. Check repository access and OIDC customization; custom subjects require the guide's manual setup."

az account set --subscription "$SUBSCRIPTION_ID"
ACR_ID=$(az acr show --name "$ACR_NAME" --query id -o tsv)
ACA_ID=$(az containerapp show --name "$ACA_APP" --resource-group "$RESOURCE_GROUP" --query id -o tsv)

# ensure_app NAME SAVED_ID: reuse the recorded identity, or reject ambiguous display names.
ensure_app() {
  local name=$1 client_id=${2:-} matches
  if [[ -n "$client_id" ]]; then
    [[ "$(az ad app show --id "$client_id" --query displayName -o tsv)" == "$name" ]] ||
      die "Saved identity $client_id does not match $name. Check .state/outputs.env."
  else
    matches=$(az ad app list --display-name "$name" -o json)
    [[ $(jq length <<< "$matches") -le 1 ]] || die "Multiple registrations are named $name. Record the intended client ID in .state/outputs.env."
    client_id=$(jq -r '.[0].appId // empty' <<< "$matches")
  fi
  if [[ -z "$client_id" ]]; then
    client_id=$(az ad app create --display-name "$name" --sign-in-audience AzureADMyOrg --query appId -o tsv)
  fi
  if [[ -z "$(az ad sp list --filter "appId eq '$client_id'" --query "[0].id" -o tsv)" ]]; then
    az ad sp create --id "$client_id" --output none
  fi
  printf '%s' "$client_id"
}

# ensure_federation CLIENT_ID CREDENTIAL_NAME ENVIRONMENT: trust one exact GitHub subject.
ensure_federation() {
  local client_id=$1 name=$2 environment=$3 existing subject
  subject="$subject_prefix:environment:$environment"
  existing=$(az ad app federated-credential list --id "$client_id" --query "[?name=='$name'] | [0]" -o json)
  if [[ "$existing" != null ]]; then
    jq -e --arg subject "$subject" \
      '.issuer == "https://token.actions.githubusercontent.com" and .subject == $subject and .audiences == ["api://AzureADTokenExchange"]' \
      <<< "$existing" >/dev/null ||
      die "Federation $name trusts different claims. Review it in Entra before changing access; expected subject: $subject"
    echo "  federated credential $name matches"
    return
  fi
  cat > "$STATE_DIR/$name.json" <<EOF
{
  "name": "$name",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "$subject",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
  (cd "$STATE_DIR" && az ad app federated-credential create --id "$client_id" --parameters "@$name.json" --output none)
  echo "  created federated credential $name -> $subject"
}

# ensure_role CLIENT_ID ROLE SCOPE
ensure_role() {
  local client_id=$1 role=$2 scope=$3 object_id
  object_id=$(az ad sp show --id "$client_id" --query id -o tsv)
  if [[ "$(az role assignment list --assignee "$object_id" --role "$role" --scope "$scope" --query 'length(@)' -o tsv)" == 0 ]]; then
    az role assignment create --assignee-object-id "$object_id" --assignee-principal-type ServicePrincipal \
      --role "$role" --scope "$scope" --output none
    echo "  assigned $role"
  else
    echo "  $role already assigned"
  fi
}

log "Build identity: $BUILD_APP_NAME"
BUILD_CLIENT_ID=$(ensure_app "$BUILD_APP_NAME" "${BUILD_CLIENT_ID:-}")
save_state BUILD_CLIENT_ID "$BUILD_CLIENT_ID"
ensure_federation "$BUILD_CLIENT_ID" github-build build
ensure_role "$BUILD_CLIENT_ID" Reader "$ACR_ID"
ensure_role "$BUILD_CLIENT_ID" AcrPush "$ACR_ID"

log "Deploy identity: $DEPLOY_APP_NAME"
DEPLOY_CLIENT_ID=$(ensure_app "$DEPLOY_APP_NAME" "${DEPLOY_CLIENT_ID:-}")
save_state DEPLOY_CLIENT_ID "$DEPLOY_CLIENT_ID"
ensure_federation "$DEPLOY_CLIENT_ID" github-production production
ensure_role "$DEPLOY_CLIENT_ID" "Container Apps Contributor" "$ACA_ID"

save_state BUILD_CLIENT_ID "$BUILD_CLIENT_ID"
save_state DEPLOY_CLIENT_ID "$DEPLOY_CLIENT_ID"

cat <<EOF

Entra setup is done.
  Build client ID   $BUILD_CLIENT_ID   (registry: Reader + AcrPush)
  Deploy client ID  $DEPLOY_CLIENT_ID   (that one Container App only: Container Apps Contributor)
Role assignments can take a few minutes to propagate.

Next: scripts/03-configure-github.sh
EOF
