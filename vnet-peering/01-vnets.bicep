// =============================================================================
// Step 1 — Three VNets, six subnets, five VMs, NO peering
//
// Deploy this first. Test that:
//   ✓ VMs in the same VNet / different subnets can ping each other
//   ✗ VMs in different VNets CANNOT reach each other (no peering yet)
//
// Usage:
//   az deployment group create \
//     --resource-group rg-vnet-peering \
//     --template-file 01-vnets.bicep \
//     --parameters parameters/main.bicepparam \
//     --parameters sshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"
// =============================================================================
targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('SSH public key for VM authentication.')
@secure()
param sshPublicKey string

@description('Admin username for all VMs.')
param adminUsername string = 'azureuser'

@description('VM size — B2ats_v2 is cheap with 2 vCPUs and 1 GiB RAM.')
param vmSize string = 'Standard_B2ats_v2'

// ---------------------------------------------------------------------------
// Shared VM config
// ---------------------------------------------------------------------------
var vmImage = {
  publisher: 'Canonical'
  offer:     'ubuntu-24_04-lts'
  sku:       'server-arm64'
  version:   'latest'
}

// ---------------------------------------------------------------------------
// NSG — allow SSH + ICMP across all VNets
// ---------------------------------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'peering-demo-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority:                 1000
          direction:                'Inbound'
          access:                   'Allow'
          protocol:                 'Tcp'
          sourcePortRange:          '*'
          destinationPortRange:     '22'
          sourceAddressPrefix:      '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowICMP'
        properties: {
          priority:                 1010
          direction:                'Inbound'
          access:                   'Allow'
          protocol:                 'Icmp'
          sourcePortRange:          '*'
          destinationPortRange:     '*'
          sourceAddressPrefix:      'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Hub VNet — 10.10.0.0/16
// ---------------------------------------------------------------------------
resource hubVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'hub-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.10.0.0/16' ]
    }
    subnets: [
      {
        name: 'shared'
        properties: {
          addressPrefix: '10.10.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
      {
        name: 'management'
        properties: {
          addressPrefix: '10.10.2.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Spoke A VNet — 10.1.0.0/16
// ---------------------------------------------------------------------------
resource spokeAVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'spoke-a-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.1.0.0/16' ]
    }
    subnets: [
      {
        name: 'web'
        properties: {
          addressPrefix: '10.1.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
      {
        name: 'app'
        properties: {
          addressPrefix: '10.1.2.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Spoke B VNet — 10.2.0.0/16
// ---------------------------------------------------------------------------
resource spokeBVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'spoke-b-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.2.0.0/16' ]
    }
    subnets: [
      {
        name: 'web'
        properties: {
          addressPrefix: '10.2.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
      {
        name: 'data'
        properties: {
          addressPrefix: '10.2.2.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Public IP — only hub-vm gets one (jump box)
// ---------------------------------------------------------------------------
resource hubPip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'hub-vm-pip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// ---------------------------------------------------------------------------
// NICs
// ---------------------------------------------------------------------------
resource hubNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'hub-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet:                    { id: hubVnet.properties.subnets[0].id }
          publicIPAddress:           { id: hubPip.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource spokeAWebNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'spoke-a-web-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet:                    { id: spokeAVnet.properties.subnets[0].id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource spokeAAppNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'spoke-a-app-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet:                    { id: spokeAVnet.properties.subnets[1].id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource spokeBWebNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'spoke-b-web-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet:                    { id: spokeBVnet.properties.subnets[0].id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource spokeBDataNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'spoke-b-data-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet:                    { id: spokeBVnet.properties.subnets[1].id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// VMs
// ---------------------------------------------------------------------------
resource hubVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: 'hub-vm'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: 'hub-vm'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [ { path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey } ] }
      }
    }
    storageProfile: {
      imageReference: vmImage
      osDisk: { name: 'hub-vm-osdisk', createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' }, diskSizeGB: 30 }
    }
    networkProfile: { networkInterfaces: [ { id: hubNic.id } ] }
  }
}

resource spokeAWebVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: 'spoke-a-web'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: 'spoke-a-web'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [ { path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey } ] }
      }
    }
    storageProfile: {
      imageReference: vmImage
      osDisk: { name: 'spoke-a-web-osdisk', createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' }, diskSizeGB: 30 }
    }
    networkProfile: { networkInterfaces: [ { id: spokeAWebNic.id } ] }
  }
}

resource spokeAAppVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: 'spoke-a-app'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: 'spoke-a-app'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [ { path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey } ] }
      }
    }
    storageProfile: {
      imageReference: vmImage
      osDisk: { name: 'spoke-a-app-osdisk', createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' }, diskSizeGB: 30 }
    }
    networkProfile: { networkInterfaces: [ { id: spokeAAppNic.id } ] }
  }
}

resource spokeBWebVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: 'spoke-b-web'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: 'spoke-b-web'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [ { path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey } ] }
      }
    }
    storageProfile: {
      imageReference: vmImage
      osDisk: { name: 'spoke-b-web-osdisk', createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' }, diskSizeGB: 30 }
    }
    networkProfile: { networkInterfaces: [ { id: spokeBWebNic.id } ] }
  }
}

resource spokeBDataVm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: 'spoke-b-data'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: 'spoke-b-data'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [ { path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey } ] }
      }
    }
    storageProfile: {
      imageReference: vmImage
      osDisk: { name: 'spoke-b-data-osdisk', createOption: 'FromImage', managedDisk: { storageAccountType: 'Standard_LRS' }, diskSizeGB: 30 }
    }
    networkProfile: { networkInterfaces: [ { id: spokeBDataNic.id } ] }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output hubVmPublicIp      string = hubPip.properties.ipAddress
output hubVmPrivateIp     string = hubNic.properties.ipConfigurations[0].properties.privateIPAddress
output spokeAWebPrivateIp string = spokeAWebNic.properties.ipConfigurations[0].properties.privateIPAddress
output spokeAAppPrivateIp string = spokeAAppNic.properties.ipConfigurations[0].properties.privateIPAddress
output spokeBWebPrivateIp string = spokeBWebNic.properties.ipConfigurations[0].properties.privateIPAddress
output spokeBDataPrivateIp string = spokeBDataNic.properties.ipConfigurations[0].properties.privateIPAddress
output sshToHub           string = 'ssh -A ${adminUsername}@${hubPip.properties.ipAddress}'
