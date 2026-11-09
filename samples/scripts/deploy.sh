#!/usr/bin/env bash
set -Eeuo pipefail
: "${ACA_APP:?}" "${ACA_RESOURCE_GROUP:?}" "${IMAGE:?}" "${GITHUB_SHA:?}"
: "${ACR_LOGIN_SERVER:?}" "${IMAGE_REPOSITORY:?}" "${GITHUB_STEP_SUMMARY:?}"
[[ "$IMAGE" == "$ACR_LOGIN_SERVER/$IMAGE_REPOSITORY@"* ]]
[[ "${IMAGE##*@}" =~ ^sha256:[0-9a-f]{64}$ ]]
app=$(az containerapp show --name "$ACA_APP" --resource-group "$ACA_RESOURCE_GROUP" -o json)
[[ $(jq -r '.properties.configuration.activeRevisionsMode' <<< "$app") == Multiple ]]
old=$(jq -er '
  .properties.configuration.ingress.traffic |
  if length == 1 and .[0].weight == 100 and
     (.[0].latestRevision != true) and (.[0].revisionName | length > 0)
  then .[0].revisionName else error("Require one explicit revision at 100%") end
' <<< "$app")
fqdn=$(jq -er '.properties.configuration.ingress.fqdn' <<< "$app")
suffix="gha${GITHUB_RUN_ID}a${GITHUB_RUN_ATTEMPT}"
revision="$ACA_APP--$suffix"
promotion_started=false
on_error() {
  result=$?
  trap - ERR
  echo "::error::Deployment failed (exit $result); previous revision: $old"
  if [[ "$promotion_started" == true ]]; then
    if az containerapp ingress traffic set --name "$ACA_APP" \
      --resource-group "$ACA_RESOURCE_GROUP" --revision-weight "$old=100" --output none; then
      echo "::warning::Traffic restored to $old; verify the private endpoint immediately"
    else
      echo "::error::Automatic rollback failed; invoke the incident runbook"
    fi
  fi
  exit "$result"
}
trap on_error ERR
printf 'Previous revision: `%s`\nCandidate revision: `%s`\nImage: `%s`\n' \
  "$old" "$revision" "$IMAGE" >> "$GITHUB_STEP_SUMMARY"
az containerapp update --name "$ACA_APP" --resource-group "$ACA_RESOURCE_GROUP" \
  --image "$IMAGE" --revision-suffix "$suffix" --output none
healthy=false
for _ in $(seq 1 60); do
  state=$(az containerapp revision show --name "$ACA_APP" \
    --resource-group "$ACA_RESOURCE_GROUP" --revision "$revision" -o json)
  if [[ $(jq -r '.properties.healthState' <<< "$state") == Healthy ]]; then
    healthy=true
    break
  fi
  sleep 5
done
[[ "$healthy" == true ]]
candidate=$(jq -er '.properties.fqdn' <<< "$state")
bash scripts/smoke.sh "$candidate" "$GITHUB_SHA"
promotion_started=true
az containerapp ingress traffic set --name "$ACA_APP" --resource-group "$ACA_RESOURCE_GROUP" \
  --revision-weight "$revision=100" --output none
bash scripts/smoke.sh "$fqdn" "$GITHUB_SHA"
echo "Promoted: \`$revision\`" >> "$GITHUB_STEP_SUMMARY"
