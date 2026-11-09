#!/usr/bin/env bash
set -euo pipefail
: "${GH_OWNER:?}" "${GH_REPO:?}" "${RUNNER_LABEL:?}"
: "${RUNNER_VERSION:?}" "${RUNNER_SHA256:?}"
[[ "$RUNNER_LABEL" =~ ^[a-z0-9-]+$ ]]
id runner >/dev/null
sudo install -d -o runner -g runner /opt/actions-runner
archive=$(mktemp)
trap 'rm -f -- "$archive"' EXIT
curl --fail --silent --show-error --location --output "$archive" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
echo "$RUNNER_SHA256  $archive" | sha256sum --check
sudo tar -xzf "$archive" -C /opt/actions-runner
sudo chown -R runner:runner /opt/actions-runner
cd /opt/actions-runner
sudo ./bin/installdependencies.sh
read -r -s -p "One-hour GitHub runner registration token: " token
printf '\n'
sudo -u runner ./config.sh --url "https://github.com/$GH_OWNER/$GH_REPO" \
  --token "$token" --unattended --name "$(hostname)" \
  --labels "$RUNNER_LABEL" --work _work
unset token
sudo ./svc.sh install runner
sudo ./svc.sh start
