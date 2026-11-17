#!/usr/bin/env bash
# Runs ON a runner VM (through 'az vmss run-command'), not on your machine.
# Downloads, verifies and registers one persistent GitHub runner as a service.
# Usage: runner-register.remote.sh OWNER REPO LABEL RUNNER_VERSION RUNNER_SHA256 REGISTRATION_TOKEN
set -euo pipefail
owner=${1:?owner} repo=${2:?repo} label=${3:?label} version=${4:?version} sha=${5:?sha256} token=${6:?token}
[[ "$label" =~ ^[a-z0-9-]+$ ]]

# First-boot provisioning (cloud-init) installs Azure CLI and, on build VMs, Docker.
for _ in $(seq 1 120); do
  [[ -f /var/lib/poc-tools-ready ]] && break
  if [[ -f /var/lib/poc-tools-failed ]]; then
    echo "Tool provisioning failed. Last log lines:"
    tail -n 30 /var/log/poc-provision.log || true
    exit 1
  fi
  sleep 10
done
[[ -f /var/lib/poc-tools-ready ]] || { echo "Timed out waiting for tool provisioning"; exit 1; }

if [[ -f /opt/actions-runner/.runner ]]; then
  echo "Runner already registered on $(hostname)"
  echo REGISTER_OK
  exit 0
fi

install -d -o runner -g runner /opt/actions-runner
archive=$(mktemp)
trap 'rm -f -- "$archive"' EXIT
curl --fail --silent --show-error --location --output "$archive" \
  "https://github.com/actions/runner/releases/download/v${version}/actions-runner-linux-x64-${version}.tar.gz"
echo "$sha  $archive" | sha256sum --check
tar -xzf "$archive" -C /opt/actions-runner
chown -R runner:runner /opt/actions-runner
cd /opt/actions-runner
./bin/installdependencies.sh >/dev/null
sudo -u runner ./config.sh --url "https://github.com/$owner/$repo" --token "$token" \
  --unattended --replace --name "$(hostname)" --labels "$label" --work _work
./svc.sh install runner
./svc.sh start
./svc.sh status | head -n 5
echo REGISTER_OK
