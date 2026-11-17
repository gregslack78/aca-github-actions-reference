#!/usr/bin/env bash
set -Eeuo pipefail
: "${REVISION:?}" "${ACA_APP:?}" "${ACA_RESOURCE_GROUP:?}" "${GITHUB_STEP_SUMMARY:?}"
[[ "$REVISION" == "$ACA_APP"--* ]]
[[ "$REVISION" =~ ^[a-z0-9-]+$ ]]
app=$(az containerapp show --name "$ACA_APP" --resource-group "$ACA_RESOURCE_GROUP" -o json)
old=$(jq -er '
  .properties.configuration.ingress.traffic |
  if length == 1 and .[0].weight == 100 and
     (.[0].latestRevision != true) and (.[0].revisionName | length > 0)
  then .[0].revisionName else error("Require one explicit revision at 100%") end
' <<< "$app")
fqdn=$(jq -er '.properties.configuration.ingress.fqdn' <<< "$app")
promotion_started=false
on_error() {
  result=$?
  trap - ERR
  echo "::error::Rollback failed (exit $result); previous revision: $old"
  if [[ "$promotion_started" == true ]]; then
    if az containerapp ingress traffic set --name "$ACA_APP" \
      --resource-group "$ACA_RESOURCE_GROUP" --revision-weight "$old=100" --output none; then
      echo "::warning::Traffic restored to $old; verify the private endpoint immediately"
    else
      echo "::error::Traffic restoration failed; invoke the incident runbook"
    fi
  fi
  exit "$result"
}
trap on_error ERR
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
  "https://$candidate/health" | jq -er 'select(.message == "Hello from ACA") | .commit | select(type == "string" and length > 0)')
promotion_started=true
az containerapp ingress traffic set --name "$ACA_APP" --resource-group "$ACA_RESOURCE_GROUP" \
  --revision-weight "$REVISION=100" --output none
bash scripts/smoke.sh "$fqdn" "$expected_commit"
echo "Manual rollback to \`$REVISION\` (commit \`$expected_commit\`)" >> "$GITHUB_STEP_SUMMARY"
