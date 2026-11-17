@description('Exact defaultDomain of the internal Container Apps environment.')
param zoneName string

@description('staticIp of the internal Container Apps environment.')
param staticIp string

param vnetId string
param tags object

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: zoneName
  location: 'global'
  tags: tags
}

resource wildcard 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: zone
  name: '*'
  properties: {
    ttl: 3600
    aRecords: [{ ipv4Address: staticIp }]
  }
}

resource apex 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: zone
  name: '@'
  properties: {
    ttl: 3600
    aRecords: [{ ipv4Address: staticIp }]
  }
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: 'link-vnet'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}
