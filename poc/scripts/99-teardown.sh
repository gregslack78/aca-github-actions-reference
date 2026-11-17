#!/usr/bin/env bash
# Teardown: delete everything the POC created in Azure and Entra. The GitHub repository is left alone.
# Usage: 99-teardown.sh [--yes]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require SUBSCRIPTION_ID RESOURCE_GROUP BUILD_APP_NAME DEPLOY_APP_NAME GH_OWNER GH_REPO \
  BUILD_CLIENT_ID DEPLOY_CLIENT_ID

if [[ "${1:-}" != "--yes" ]]; then
  cat <<EOF
This will delete:
  - resource group $RESOURCE_GROUP and everything in it (VMs, registry, Container Apps environment, network)
  - Entra app registration $BUILD_APP_NAME ($BUILD_CLIENT_ID)
  - Entra app registration $DEPLOY_APP_NAME ($DEPLOY_CLIENT_ID)
It will NOT delete the GitHub repository $GH_OWNER/$GH_REPO or its runners entries.
EOF
  read -r -p "Type the resource group name to confirm: " answer
  [[ "$answer" == "$RESOURCE_GROUP" ]] || die "Confirmation did not match. Nothing was deleted."
fi

az account set --subscription "$SUBSCRIPTION_ID"

log "Deleting Entra app registrations"
for client_id in "$BUILD_CLIENT_ID" "$DEPLOY_CLIENT_ID"; do
  az ad app show --id "$client_id" --output none
done
for client_id in "$BUILD_CLIENT_ID" "$DEPLOY_CLIENT_ID"; do
  az ad app delete --id "$client_id"
  echo "  deleted recorded identity $client_id"
done

log "Deleting resource group $RESOURCE_GROUP (continues in the background)"
az group delete --name "$RESOURCE_GROUP" --yes --no-wait
rm -f "$STATE_FILE"

cat <<EOF

Deletion started. Check with: az group exists --name $RESOURCE_GROUP
In GitHub, remove the offline runners and, if you no longer need it, the repository:
  gh repo delete $GH_OWNER/$GH_REPO --yes     (needs the delete_repo scope: gh auth refresh -s delete_repo)
EOF
