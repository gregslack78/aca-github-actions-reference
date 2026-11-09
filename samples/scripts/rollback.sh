#!/usr/bin/env bash
set -euo pipefail
: "${REVISION:?}" "${ACA_APP:?}" "${ACA_RESOURCE_GROUP:?}" "${GITHUB_STEP_SUMMARY:?}"
[[ "$REVISION" == "$ACA_APP"--* ]]
[[ "$REVISION" =~ ^[a-z0-9-]+$ ]]
az containerapp revision show --name "$ACA_APP" --resource-group "$ACA_RESOURCE_GROUP" \
  --revision "$REVISION" --output none
az containerapp revision activate --name "$ACA_APP" --resource-group "$ACA_RESOURCE_GROUP" \
  --revision "$REVISION" --output none
healthy=false
for _ in $(seq 1 60); do
  state=$(az containerapp revision show --name "$ACA_APP" \
    --resource-group "$ACA_RESOURCE_GROUP" --revision "$REVISION" -o json)
  if [[ $(jq -r '.properties.healthState' <<< "$state") == Healthy ]]; then
    healthy=true
    break
  fi
  sleep 5
done
[[ "$healthy" == true ]]
candidate=$(jq -er '.properties.fqdn' <<< "$state")
expected_commit=$(curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
  "https://$candidate/health" | jq -er 'select(.message == "Hello from ACA") | .commit')
az containerapp ingress traffic set --name "$ACA_APP" --resource-group "$ACA_RESOURCE_GROUP" \
  --revision-weight "$REVISION=100" --output none
fqdn=$(az containerapp show --name "$ACA_APP" --resource-group "$ACA_RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn -o tsv)
bash scripts/smoke.sh "$fqdn" "$expected_commit"
echo "Manual rollback to \`$REVISION\` (commit \`$expected_commit\`)" >> "$GITHUB_STEP_SUMMARY"
