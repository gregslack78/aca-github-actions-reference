#!/usr/bin/env bash
set -euo pipefail
hostname=${1:?Supply the ACA FQDN}
commit=${2:?Supply the expected commit}
[[ "$hostname" =~ ^[a-zA-Z0-9.-]+$ ]]
for attempt in $(seq 1 12); do
  if body=$(curl --fail --silent --show-error --connect-timeout 5 --max-time 20 \
    "https://$hostname/health"); then
    if jq -e --arg commit "$commit" \
      '.message == "Hello from ACA" and .commit == $commit' <<< "$body" >/dev/null; then
      echo "Verified $hostname serves commit $commit"
      exit 0
    fi
  fi
  echo "::warning::Health/commit verification attempt $attempt failed for $hostname"
  sleep 5
done
echo "::error::Private health endpoint did not serve the expected commit"
exit 1
