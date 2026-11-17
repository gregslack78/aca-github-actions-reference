# POC infrastructure (Bicep)

Deploys the Azure side of the [POC](../POC.md): a private registry, an internal Container Apps environment with one app, and two
VM scale sets that act as self-hosted GitHub runners, all in one VNet.
It does **not** create Entra app registrations or any GitHub setting; the numbered scripts in [../scripts](../scripts) do that.

## Layout

```text
infra/
  main.bicep                  Entry point (resource group scope); wires the modules together
  main.bicepparam             Parameter file; reads values from environment variables
  public-demo.bicep           Optional separate public demo with explicit IPv4 allow rules
  cloud-init/runner.yaml      First-boot tool install for runner VMs (uses ../../samples/scripts/provision-vm-tools.sh)
  modules/
    network.bicep             VNet, five subnets (including reserved demo subnet), NAT gateway, NSG
    registry.bicep            ACR Premium, private endpoint, private DNS zone, AcrPull role for the pull identity
    containerapp-env.bicep    Log Analytics and the internal Container Apps environment
    dns-aca.bicep             Private DNS zone named after the environment's default domain, with * and @ records
    containerapp.bicep        The Container App (multiple revisions, port 8080, placeholder image)
    runners.bicep             Build and deploy VM scale sets
```

## What is deployed

| Resource | Details |
|---|---|
| Virtual network `vnet-<prefix>` | `10.60.0.0/16`: runners-build `/24`, runners-deploy `/27`, private-endpoints `/27`, aca `/26`, reserved aca-demo `/27` (ACA subnets delegated to `Microsoft.App/environments`) |
| NAT gateway + public IP | Explicit outbound access for the runner and ACA subnets. Runner and private-endpoint subnets have default outbound access disabled |
| Network security group | On the runner subnets, with no inbound rules (default rules deny inbound from the internet) |
| Container Registry | Premium, **public network access disabled**, admin user disabled, data endpoint enabled, classic RBAC mode, private endpoint in the private-endpoints subnet |
| Private DNS zone `privatelink.azurecr.io` | Linked to the VNet; the private endpoint's zone group writes the login and data-endpoint records |
| Log Analytics workspace | 30-day retention, receives Container Apps logs |
| Container Apps environment | **Internal** (no public address), workload profiles, Consumption profile |
| Private DNS zone `<environment default domain>` | Wildcard and apex A records to the environment's static IP, linked to the VNet |
| User-assigned identity `id-<prefix>-pull` | `AcrPull` on the registry; the only identity the app runs with |
| Container App `hello-poc` | Multiple-revision mode, ingress on 8080 (`external` on the internal environment = VNet-only), min 1 / max 3 replicas, 0.25 vCPU / 0.5 GiB, starts on `mcr.microsoft.com/dotnet/samples:aspnetapp` |
| VM scale set `vmss-<prefix>-build` | Uniform, manual upgrades, `Standard_D2as_v5`, Ubuntu 24.04, 32 GiB Standard SSD, SSH key only, **no public IP, no managed identity**; Docker installed at first boot |
| VM scale set `vmss-<prefix>-deploy` | Same, without Docker |

Placeholder image: the Container App needs a healthy revision before the first release so there is something to roll forward from.
The first pipeline release replaces it with the sample app. On first creation, `scripts/01-deploy-infra.sh` pins 100% of traffic to the named bootstrap revision
(`hello-poc--bootstrap`), because the release script requires one explicit revision and rejects `latest`.
On a rerun, the script detects the existing app and passes `deployApp=false`; neither the app module nor traffic pinning runs.
This preserves the released image, configuration and traffic when changing runner capacity.

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `location` | resource group location | Check VM size availability and vCPU quota |
| `prefix` | `acapoc` | 3 to 12 characters; used in resource names |
| `sshPublicKey` | none (required) | Contents of your `.pub` file. Read from the `SSH_PUBLIC_KEY` environment variable by `main.bicepparam` |
| `vmSize` | `Standard_D2as_v5` | Env var `VM_SIZE` |
| `buildInstanceCount` | `2` | 1 to 15. Env var `BUILD_INSTANCE_COUNT` |
| `deployInstanceCount` | `1` | 1 to 2. Env var `DEPLOY_INSTANCE_COUNT` |
| `appName` | `hello-poc` | Env var `ACA_APP` |
| `bootstrapImage` | `mcr.microsoft.com/dotnet/samples:aspnetapp` | Any public image that listens on port 8080 |
| `deployApp` | `true` | First creation only. Pass `false` for an existing app; direct Bicep users must set this explicitly on reruns |
| `tags` | `purpose=github-actions-to-aca-poc` | Applied to every resource |

## Outputs

`registryName`, `registryLoginServer`, `acaEnvironmentName`, `acaDefaultDomain`, `acaStaticIp`, `acaAppName`, `acaAppFqdn`, `acaBootstrapRevision`,
`buildScaleSetName`, `deployScaleSetName`, `natPublicIp`, `pullIdentityId`.
`scripts/01-deploy-infra.sh` saves these to `poc/.state/outputs.env`.

## Deploy manually (without the scripts)

You need Azure CLI 2.60 or newer and a signed-in session (`az login`). Register the providers once per subscription:

```bash
for p in Microsoft.App Microsoft.ContainerRegistry Microsoft.Compute Microsoft.Network \
         Microsoft.OperationalInsights Microsoft.ManagedIdentity Microsoft.Authorization; do
  az provider register --namespace "$p" --wait
done
az extension add --name containerapp --upgrade
az bicep install
```

Deploy:

```bash
export SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"
# optional overrides: POC_PREFIX VM_SIZE BUILD_INSTANCE_COUNT DEPLOY_INSTANCE_COUNT ACA_APP
az group create --name rg-aca-gh-poc --location eastus2
az deployment group what-if  --resource-group rg-aca-gh-poc --parameters infra/main.bicepparam   # preview
az deployment group create   --resource-group rg-aca-gh-poc --name poc-infra --parameters infra/main.bicepparam
az deployment group show     --resource-group rg-aca-gh-poc --name poc-infra --query properties.outputs
```

Then pin traffic to the bootstrap revision (use the `acaBootstrapRevision` output):

```bash
az containerapp ingress traffic set --name hello-poc --resource-group rg-aca-gh-poc \
  --revision-weight "hello-poc--bootstrap=100"
```

The bootstrap pin is **only for first creation**. For an existing app, add `--parameters deployApp=false` to deployment
and what-if commands and do not run the bootstrap pin. The numbered script handles detection automatically.

Without the `.bicepparam` file, pass parameters directly, for example:
`az deployment group create -g rg-aca-gh-poc -f infra/main.bicep -p sshPublicKey="$(cat ~/.ssh/id_ed25519.pub)" buildInstanceCount=2`.

Continue with the Entra, GitHub, and runner steps in [POC.md](../POC.md#5-set-up-the-poc).

## Notes and limits

* **Optional browser demo.** [public-demo.bicep](public-demo.bicep) creates a separate external
  Consumption environment and app, not a replacement for the internal environment. Use
  [08-enable-browser-demo.sh](../scripts/08-enable-browser-demo.sh) to validate `/32` allow rules,
  add the reserved subnet, preserve existing app images/traffic on reruns, grant app-scoped deploy
  access, and enable the optional release step. It reuses the private registry, pull identity, NAT,
  and Log Analytics workspace. The demo scales from zero to three replicas; cold starts are expected.
  Additional environment/networking, compute, and logging charges can apply.

* **Repository layout matters.** `runners.bicep` reads `../../../samples/scripts/provision-vm-tools.sh` at compile time, so keep `poc/` and `samples/` side by side as they are in the reference repository.
* **Runner access.** The VMs have no public IP and there is no jump host or Bastion. The scripts use `az vmss run-command`. To add interactive access, deploy Azure Bastion in a dedicated `AzureBastionSubnet` (an extra subnet and cost).
* **Upgrade policy is Manual.** Changing `customData` or the image later does not alter existing VMs. Re-image or replace a VM only after draining its runner (guide section 7.4).
* **Single VNet.** A production design separates CI and production spokes and uses a shared firewall and DNS (guide section 6).
* **Authorization mode.** The registry uses classic RBAC (`AcrPush` / `AcrPull`). For an ABAC registry use repository-conditioned roles instead (guide section 6.2).
* **ACA probes.** The POC leaves the default probes. The guide recommends HTTP probes on `/health`; add them after the first release if you want to test that behavior.
* **Linting.** `az bicep build --file infra/main.bicep` compiles the template and reports analyzer warnings.
