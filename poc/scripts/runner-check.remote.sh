#!/usr/bin/env bash
# Runs ON a runner VM (through 'az vmss run-command'), not on your machine.
# Reports what the pipeline depends on: tools, private DNS, and private reachability.
# Usage: runner-check.remote.sh ACR_LOGIN_SERVER APP_FQDN [docker]
set -uo pipefail
acr=${1:?acr login server} fqdn=${2:?app fqdn} want_docker=${3:-}
failed=0

echo "--- host: $(hostname)"
for tool in git curl jq python3 az; do
  if command -v "$tool" >/dev/null 2>&1; then echo "tool ok: $tool"; else echo "tool MISSING: $tool"; failed=1; fi
done
if ! AZURE_EXTENSION_DIR=/opt/azure-cli-extensions az extension list --query "[?name=='containerapp'].name" -o tsv | grep -q containerapp; then
  echo "containerapp extension MISSING"; failed=1
fi
if [[ "$want_docker" == docker ]]; then
  if docker info >/dev/null 2>&1; then echo "docker ok"; else echo "docker MISSING or not running"; failed=1; fi
  if id runner | grep -q docker; then echo "runner is in docker group"; else echo "runner is NOT in docker group"; failed=1; fi
fi
echo "--- DNS (private addresses expected: 10.x)"
for host in "$acr" "$fqdn"; do
  addresses=$(getent ahostsv4 "$host" | awk '{print $1}' | sort -u)
  if [[ -z "$addresses" ]]; then
    echo "DNS FAILED: $host"; failed=1
  elif ! python3 -c 'import ipaddress,sys
nets = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
sys.exit(not all(any(ipaddress.ip_address(a) in n for n in nets) for a in sys.stdin.read().split()))' <<< "$addresses"; then
    echo "DNS is not private: $host -> $addresses"; failed=1
  else
    echo "$host -> $addresses"
  fi
done
echo "--- HTTPS to the private app"
if ! curl --fail --silent --show-error --max-time 20 -o /dev/null -w 'status=%{http_code}\n' "https://$fqdn/"; then
  echo "HTTPS check FAILED"; failed=1
fi
echo "--- runner service"
systemctl list-units --type=service --no-legend 'actions.runner.*' 2>/dev/null | head -n 3 || true
if [[ "$failed" -ne 0 ]]; then echo CHECK_FAILED; exit 1; fi
echo CHECK_OK
