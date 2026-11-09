#!/usr/bin/env bash
set -euo pipefail
for command in bash git curl jq python3 az timeout; do
  command -v "$command" >/dev/null
done
python3 --version
az version --output json
az containerapp revision show --help >/dev/null
curl --version | head -n 1
if [[ "${BUILD_MODE:-acr-task}" == vmss ]]; then
  docker version
  docker info >/dev/null
fi
