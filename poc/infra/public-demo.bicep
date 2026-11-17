targetScope = 'resourceGroup'

param location string = resourceGroup().location
param prefix string
param appName string
param image string
param registryLoginServer string
param browserCidr string
param runnerCidr string
param deployApp bool = true
param deploySubnet bool = true
@description('Explicit opt-in to a publicly viewable hello-world demo without IP restrictions.')
param publicAccess bool = false

var tags = {
  purpose: 'github-actions-to-aca-poc'
  component: 'browser-demo'
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: 'vnet-${prefix}'
}

resource nat 'Microsoft.Network/natGateways@2024-05-01' existing = {
  name: 'natgw-${prefix}'
}

resource demoSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (deploySubnet) {
  parent: vnet
  name: 'snet-aca-demo'
  properties: {
    addressPrefix: '10.60.5.0/27'
    natGateway: { id: nat.id }
    delegations: [
      {
        name: 'aca-environments'
        properties: { serviceName: 'Microsoft.App/environments' }
      }
    ]
  }
}

resource existingSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-aca-demo'
}

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: 'log-${prefix}'
}

resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: 'id-${prefix}-pull'
}

resource environment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: 'cae-${prefix}-demo'
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: deploySubnet ? demoSubnet!.id : existingSubnet.id
      internal: false
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

resource existingApp 'Microsoft.App/containerApps@2025-01-01' existing = {
  name: appName
}

module app 'modules/containerapp.bicep' = if (deployApp) {
  name: 'public-demo-app'
  params: {
    location: location
    tags: tags
    appName: appName
    environmentId: environment.id
    pullIdentityId: pullIdentity.id
    registryLoginServer: registryLoginServer
    bootstrapImage: image
    allowedCidrs: publicAccess ? [] : [browserCidr, runnerCidr]
    minReplicas: 0
  }
}

output appId string = resourceId('Microsoft.App/containerApps', appName)
output fqdn string = deployApp ? app!.outputs.fqdn : existingApp.properties.configuration.ingress.fqdn
