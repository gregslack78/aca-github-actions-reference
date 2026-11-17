targetScope = 'resourceGroup'

@description('Azure region. Check VM size availability and vCPU quota first.')
param location string = resourceGroup().location

@description('Short lowercase prefix used in resource names.')
@minLength(3)
@maxLength(12)
param prefix string = 'acapoc'

@description('SSH public key (contents of the .pub file) for the runner VMs.')
param sshPublicKey string

@description('VM size for the runner scale sets.')
param vmSize string = 'Standard_D2as_v5'

@description('Build runner VMs. The guide sizes for 15; two is enough to prove the pipeline.')
@minValue(1)
@maxValue(15)
param buildInstanceCount int = 2

@description('Deploy runner VMs.')
@minValue(1)
@maxValue(2)
param deployInstanceCount int = 1

@description('Name of the Container App that the pipeline deploys to.')
param appName string = 'hello-poc'

@description('Placeholder image that listens on 8080. Replaced by the first pipeline release.')
param bootstrapImage string = 'mcr.microsoft.com/dotnet/samples:aspnetapp'

@description('Create the bootstrap app only on the first deployment. Disable when an app already exists to preserve its image, settings and traffic.')
param deployApp bool = true

param tags object = {
  purpose: 'github-actions-to-aca-poc'
}

var suffix = uniqueString(resourceGroup().id)

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    prefix: prefix
    tags: tags
  }
}

// Runtime image-pull identity: separate from the GitHub build and deploy identities.
resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${prefix}-pull'
  location: location
  tags: tags
}

module registry 'modules/registry.bicep' = {
  name: 'registry'
  params: {
    location: location
    tags: tags
    registryName: take('acr${prefix}${suffix}', 50)
    vnetId: network.outputs.vnetId
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
    pullPrincipalId: pullIdentity.properties.principalId
  }
}

module acaEnv 'modules/containerapp-env.bicep' = {
  name: 'aca-environment'
  params: {
    location: location
    tags: tags
    prefix: prefix
    acaSubnetId: network.outputs.acaSubnetId
  }
}

// The zone name is the environment's generated defaultDomain, so it is created in a module
// that receives it as a parameter.
module acaDns 'modules/dns-aca.bicep' = {
  name: 'aca-private-dns'
  params: {
    zoneName: acaEnv.outputs.defaultDomain
    staticIp: acaEnv.outputs.staticIp
    vnetId: network.outputs.vnetId
    tags: tags
  }
}

resource existingApp 'Microsoft.App/containerApps@2025-01-01' existing = {
  name: appName
}

module app 'modules/containerapp.bicep' = if (deployApp) {
  name: 'container-app'
  dependsOn: [
    acaDns
  ]
  params: {
    location: location
    tags: tags
    appName: appName
    environmentId: acaEnv.outputs.environmentId
    pullIdentityId: pullIdentity.id
    registryLoginServer: registry.outputs.loginServer
    bootstrapImage: bootstrapImage
  }
}

module runners 'modules/runners.bicep' = {
  name: 'runners'
  params: {
    location: location
    tags: tags
    prefix: prefix
    sshPublicKey: sshPublicKey
    vmSize: vmSize
    buildSubnetId: network.outputs.buildSubnetId
    deploySubnetId: network.outputs.deploySubnetId
    buildInstanceCount: buildInstanceCount
    deployInstanceCount: deployInstanceCount
  }
}

output registryName string = registry.outputs.registryName
output registryLoginServer string = registry.outputs.loginServer
output acaEnvironmentName string = acaEnv.outputs.environmentName
output acaDefaultDomain string = acaEnv.outputs.defaultDomain
output acaStaticIp string = acaEnv.outputs.staticIp
output acaAppName string = appName
output acaAppFqdn string = deployApp ? app!.outputs.fqdn : existingApp.properties.configuration.ingress.fqdn
output acaBootstrapRevision string = '${appName}--bootstrap'
output buildScaleSetName string = runners.outputs.buildScaleSetName
output deployScaleSetName string = runners.outputs.deployScaleSetName
output natPublicIp string = network.outputs.natPublicIp
output pullIdentityId string = pullIdentity.id
