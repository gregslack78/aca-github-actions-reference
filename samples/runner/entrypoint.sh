#!/usr/bin/env bash
set -euo pipefail
: "${GH_OWNER:?}" "${GH_REPO:?}" "${GH_RUNNER_TOKEN:?}" "${RUNNER_LABEL:?}"
[[ "$RUNNER_LABEL" =~ ^[a-z0-9-]+$ ]]
api="https://api.github.com/repos/$GH_OWNER/$GH_REPO/actions/runners/registration-token"
token=$(curl --fail-with-body --silent --show-error --request POST \
  -H "Authorization: Bearer $GH_RUNNER_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" "$api" | jq -er .token)
unset GH_RUNNER_TOKEN
./config.sh --url "https://github.com/$GH_OWNER/$GH_REPO" --token "$token" \
  --unattended --ephemeral --disableupdate \
  --name "aca-$(cat /proc/sys/kernel/random/uuid)" \
  --labels "$RUNNER_LABEL" --work _work
unset token
exec timeout --signal=INT 1800 ./run.sh
