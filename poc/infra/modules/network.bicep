@description('Azure region.')
param location string

@description('Name prefix for resources.')
param prefix string

param tags object

@description('Address space for the POC VNet.')
param vnetAddressPrefix string = '10.60.0.0/16'

var natName = 'natgw-${prefix}'
var natIpName = 'pip-${natName}'

resource natIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: natIpName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nat 'Microsoft.Network/natGateways@2024-05-01' = {
  name: natName
  location: location
  tags: tags
  sku: { name: 'Standard' }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      { id: natIp.id }
    ]
  }
}

// No inbound rules are added: the default rules already deny inbound traffic from the internet.
resource runnerNsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${prefix}-runners'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${prefix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: 'snet-runners-build'
        properties: {
          addressPrefix: '10.60.1.0/24'
          natGateway: { id: nat.id }
          networkSecurityGroup: { id: runnerNsg.id }
          defaultOutboundAccess: false
        }
      }
      {
        name: 'snet-runners-deploy'
        properties: {
          addressPrefix: '10.60.2.0/27'
          natGateway: { id: nat.id }
          networkSecurityGroup: { id: runnerNsg.id }
          defaultOutboundAccess: false
        }
      }
      {
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: '10.60.3.0/27'
          defaultOutboundAccess: false
        }
      }
      {
        name: 'snet-aca'
        properties: {
          addressPrefix: '10.60.4.0/26'
          natGateway: { id: nat.id }
          delegations: [
            {
              name: 'aca-environments'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
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
    ]
  }
}

output vnetId string = vnet.id
output buildSubnetId string = '${vnet.id}/subnets/snet-runners-build'
output deploySubnetId string = '${vnet.id}/subnets/snet-runners-deploy'
output privateEndpointSubnetId string = '${vnet.id}/subnets/snet-private-endpoints'
output acaSubnetId string = '${vnet.id}/subnets/snet-aca'
output demoSubnetId string = '${vnet.id}/subnets/snet-aca-demo'
output natPublicIp string = natIp.properties.ipAddress
