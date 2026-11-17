@description('Azure region.')
param location string

param tags object

param prefix string

@description('SSH public key for the runneradmin account (key authentication only).')
param sshPublicKey string

param vmSize string
param adminUsername string = 'runneradmin'
param buildSubnetId string
param deploySubnetId string
param buildInstanceCount int
param deployInstanceCount int

var provisionScript = loadFileAsBase64('../../../samples/scripts/provision-vm-tools.sh')
var cloudInitTemplate = loadTextContent('../cloud-init/runner.yaml')

var pools = [
  {
    name: 'vmss-${prefix}-build'
    mode: 'build'
    subnetId: buildSubnetId
    capacity: buildInstanceCount
  }
  {
    name: 'vmss-${prefix}-deploy'
    mode: 'deploy'
    subnetId: deploySubnetId
    capacity: deployInstanceCount
  }
]

// Uniform, manual-upgrade scale sets: fixed capacity, no public IP, no managed identity on the VMs.
resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-07-01' = [for pool in pools: {
  name: pool.name
  location: location
  tags: tags
  sku: {
    name: vmSize
    tier: 'Standard'
    capacity: pool.capacity
  }
  properties: {
    orchestrationMode: 'Uniform'
    overprovision: false
    upgradePolicy: { mode: 'Manual' }
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: take('gh${pool.mode}', 9)
        adminUsername: adminUsername
        customData: base64(replace(replace(cloudInitTemplate, '@@PROVISION_B64@@', provisionScript), '@@MODE@@', pool.mode))
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: sshPublicKey
              }
            ]
          }
        }
      }
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: 'ubuntu-24_04-lts'
          sku: 'server'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
          diskSizeGB: 32
          managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        }
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'nic'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'ipconfig'
                  properties: {
                    primary: true
                    subnet: { id: pool.subnetId }
                  }
                }
              ]
            }
          }
        ]
      }
    }
  }
}]

output buildScaleSetName string = vmss[0].name
output deployScaleSetName string = vmss[1].name
