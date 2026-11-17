@description('Azure region.')
param location string

param tags object

param appName string
param environmentId string

@description('Resource ID of the user-assigned identity the app uses to pull images.')
param pullIdentityId string

param registryLoginServer string

@description('Placeholder image listening on 8080. The first pipeline release replaces it.')
param bootstrapImage string

@description('Explicit IPv4 allow rules for the optional public demo. Empty for the private app.')
param allowedCidrs array = []

@minValue(0)
@maxValue(1)
param minReplicas int = 1

resource app 'Microsoft.App/containerApps@2025-01-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${pullIdentityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Multiple'
      ingress: {
        // The environment determines whether external ingress is public or VNet-only.
        external: true
        targetPort: 8080
        transport: 'auto'
        allowInsecure: false
        ipSecurityRestrictions: [for (cidr, index) in allowedCidrs: {
          name: 'allowed-${index}'
          action: 'Allow'
          ipAddressRange: cidr
          description: index == 0 ? 'Browser access' : 'Deployment runner verification'
        }]
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: registryLoginServer
          identity: pullIdentityId
        }
      ]
    }
    template: {
      revisionSuffix: 'bootstrap'
      containers: [
        {
          name: 'hello'
          image: bootstrapImage
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: 3
      }
    }
  }
}

output appName string = app.name
output appId string = app.id
output fqdn string = app.properties.configuration.ingress.fqdn
output bootstrapRevision string = '${app.name}--bootstrap'
