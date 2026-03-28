// =============================================================================
// VNet Peering Demo — Two virtual networks peered together
//
// Demonstrates:
//   1. Two VNets with NON-overlapping address spaces (required for peering)
//   2. Bidirectional peering (VNet A → B and B → A)
//   3. A VM in each VNet to test connectivity via private IPs
//
// Azure requires that peered VNets have non-overlapping CIDR ranges.
// If they overlap, peering creation fails. See the README for details.
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

@description('Admin username for both VMs.')
param adminUsername string = 'azureuser'

@description('VM size — B1s is the cheapest.')
param vmSize string = 'Standard_B1s'

// ---------------------------------------------------------------------------
// VNet A — 10.1.0.0/16
// ---------------------------------------------------------------------------
resource vnetA 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-a'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.1.0.0/16' ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.1.0.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// VNet B — 10.2.0.0/16 (non-overlapping with VNet A)
// ---------------------------------------------------------------------------
resource vnetB 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'vnet-b'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.2.0.0/16' ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.2.0.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Peering — bidirectional (both sides must be created)
// ---------------------------------------------------------------------------

// A → B
resource peeringAtoB 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: vnetA
  name: 'vnet-a-to-vnet-b'
  properties: {
    remoteVirtualNetwork: { id: vnetB.id }
    allowVirtualNetworkAccess: true   // VMs can communicate across the peering
    allowForwardedTraffic:     false  // no hub-spoke forwarding needed
    allowGatewayTransit:       false  // no VPN gateway in this demo
    useRemoteGateways:         false
  }
}

// B → A
resource peeringBtoA 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: vnetB
  name: 'vnet-b-to-vnet-a'
  properties: {
    remoteVirtualNetwork: { id: vnetA.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic:     false
    allowGatewayTransit:       false
    useRemoteGateways:         false
  }
}

// ---------------------------------------------------------------------------
// Shared NSG — allow SSH + ICMP (ping)
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
// Public IPs (one per VM, for SSH access)
// ---------------------------------------------------------------------------
resource pipA 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'vm-a-pip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource pipB 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'vm-b-pip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// ---------------------------------------------------------------------------
// NICs
// ---------------------------------------------------------------------------
resource nicA 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'vm-a-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet:                    { id: vnetA.properties.subnets[0].id }
          publicIPAddress:           { id: pipA.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource nicB 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'vm-b-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet:                    { id: vnetB.properties.subnets[0].id }
          publicIPAddress:           { id: pipB.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// VMs — one in each VNet
// ---------------------------------------------------------------------------
var vmConfig = {
  size:  vmSize
  image: {
    publisher: 'Canonical'
    offer:     'ubuntu-24_04-lts'
    sku:       'server'
    version:   'latest'
  }
  osDiskType: 'Standard_LRS'
}

resource vmA 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: 'vm-a'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmConfig.size }
    osProfile: {
      computerName:  'vm-a'
      adminUsername:  adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            { path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: vmConfig.image
      osDisk: {
        name:         'vm-a-osdisk'
        createOption: 'FromImage'
        managedDisk:  { storageAccountType: vmConfig.osDiskType }
        diskSizeGB:   30
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nicA.id } ]
    }
  }
}

resource vmB 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: 'vm-b'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmConfig.size }
    osProfile: {
      computerName:  'vm-b'
      adminUsername:  adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            { path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: vmConfig.image
      osDisk: {
        name:         'vm-b-osdisk'
        createOption: 'FromImage'
        managedDisk:  { storageAccountType: vmConfig.osDiskType }
        diskSizeGB:   30
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nicB.id } ]
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output vmAPublicIp  string = pipA.properties.ipAddress
output vmBPublicIp  string = pipB.properties.ipAddress
output vmAPrivateIp string = nicA.properties.ipConfigurations[0].properties.privateIPAddress
output vmBPrivateIp string = nicB.properties.ipConfigurations[0].properties.privateIPAddress
output sshToVmA     string = 'ssh ${adminUsername}@${pipA.properties.ipAddress}'
output sshToVmB     string = 'ssh ${adminUsername}@${pipB.properties.ipAddress}'
output pingTest     string = 'SSH into vm-a, then run: ping ${nicB.properties.ipConfigurations[0].properties.privateIPAddress}'
