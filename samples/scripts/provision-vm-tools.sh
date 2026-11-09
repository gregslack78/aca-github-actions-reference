#!/usr/bin/env bash
set -euo pipefail
mode=${1:?Supply build or deploy}
[[ "$mode" == build || "$mode" == deploy ]]
[[ $(dpkg --print-architecture) == amd64 ]]
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]]
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git jq python3 tar gzip coreutils
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc |
  sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/microsoft.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ noble main" |
  sudo tee /etc/apt/sources.list.d/azure-cli.list >/dev/null
sudo apt-get update
sudo apt-get install -y azure-cli
sudo env AZURE_EXTENSION_DIR=/opt/azure-cli-extensions \
  az extension add --name containerapp --upgrade --only-show-errors
sudo chmod -R a+rX /opt/azure-cli-extensions
if ! id runner >/dev/null 2>&1; then
  sudo useradd --create-home --shell /bin/bash runner
fi
if [[ "$mode" == build ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
    sudo tee /etc/apt/keyrings/docker.asc >/dev/null
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  sudo usermod -aG docker runner
  sudo systemctl enable --now docker
  sudo -u runner docker info >/dev/null
fi
echo "Provisioned $mode tooling. Register the runner separately; do not capture its credentials in an image."
