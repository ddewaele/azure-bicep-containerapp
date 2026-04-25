// =============================================================================
// Step 1 — Network + 2 Ubuntu VMs + Bastion Developer
//
//   netmon-vnet 10.50.0.0/16
//     ├── vm1-subnet 10.50.1.0/24  ── nsg-vm1 (allow SSH from VNet, HTTP from Internet)
//     │     └── vm1  (10.50.1.10, public IP)
//     └── vm2-subnet 10.50.2.0/24  ── nsg-vm2 (allow SSH from VNet, ICMP from vm1-subnet only)
//           └── vm2  (10.50.2.10, private only)
//     + Bastion Developer SKU (free, no dedicated subnet needed)
//
// NSG design is intentionally mixed (some allow, some deny) so Network Watcher
// tools have interesting data to show: IP flow verify produces Y/N, flow logs
// produce allow + deny entries, Connection Monitor probes show one succeeding
// path (TCP 22) and one blocked path (TCP 80).
//
// Usage:
//   az deployment group create \
//     --resource-group $RG \
//     --template-file 01-network.bicep \
//     --parameters @parameters/01-network.json \
//     --parameters sshPublicKey="$(cat ~/.ssh/azure-cheap-vm/ed25519.pub)"
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Admin username for both VMs.')
param adminUsername string = 'azureuser'

@description('SSH public key for both VMs.')
param sshPublicKey string

@description('VM size — B2as_v2 is 2 vCPU / 4 GiB, fine for AMA + monitoring tasks.')
param vmSize string = 'Standard_B2as_v2'

@description('VNet address space.')
param vnetAddressPrefix string = '10.50.0.0/16'

param vm1SubnetPrefix  string = '10.50.1.0/24'
param vm2SubnetPrefix  string = '10.50.2.0/24'
param vm1PrivateIp     string = '10.50.1.10'
param vm2PrivateIp     string = '10.50.2.10'

// ---------------------------------------------------------------------------
// NSG for vm1: SSH from VNet, HTTP from Internet, ICMP from VNet
// (HTTP allow gives flow logs an Internet-inbound entry to show)
// ---------------------------------------------------------------------------
resource nsgVm1 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-vm1'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-vnet-ssh'
        properties: {
          priority:                 100
          protocol:                 'Tcp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      'VirtualNetwork'
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '22'
        }
      }
      {
        name: 'allow-internet-http'
        properties: {
          priority:                 200
          protocol:                 'Tcp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      'Internet'
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '80'
        }
      }
      {
        name: 'allow-vnet-icmp'
        properties: {
          priority:                 300
          protocol:                 'Icmp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      'VirtualNetwork'
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '*'
        }
      }
      {
        name: 'deny-all-inbound'
        properties: {
          priority:                 4000
          protocol:                 '*'
          access:                   'Deny'
          direction:                'Inbound'
          sourceAddressPrefix:      '*'
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// NSG for vm2: SSH from VNet (so Bastion works), ICMP only from vm1-subnet
// No HTTP allow — so vm1→vm2:80 will be denied. Useful for Connection Monitor
// showing a blocked-at-NSG path and for IP flow verify Y/N answers.
// ---------------------------------------------------------------------------
resource nsgVm2 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'nsg-vm2'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-vnet-ssh'
        properties: {
          priority:                 100
          protocol:                 'Tcp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      'VirtualNetwork'
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '22'
        }
      }
      {
        name: 'allow-vm1subnet-icmp'
        properties: {
          priority:                 110
          protocol:                 'Icmp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      vm1SubnetPrefix
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '*'
        }
      }
      {
        name: 'deny-all-inbound'
        properties: {
          priority:                 4000
          protocol:                 '*'
          access:                   'Deny'
          direction:                'Inbound'
          sourceAddressPrefix:      '*'
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '*'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// VNet — subnet NSGs are attached here
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'netmon-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetAddressPrefix ]
    }
    subnets: [
      {
        name: 'vm1-subnet'
        properties: {
          addressPrefix:        vm1SubnetPrefix
          networkSecurityGroup: { id: nsgVm1.id }
        }
      }
      {
        name: 'vm2-subnet'
        properties: {
          addressPrefix:        vm2SubnetPrefix
          networkSecurityGroup: { id: nsgVm2.id }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Public IP + NIC for vm1 (Internet-inbound entry point)
// ---------------------------------------------------------------------------
resource vm1PublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'vm1-pip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource vm1Nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'vm1-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet:                    { id: '${vnet.id}/subnets/vm1-subnet' }
          privateIPAllocationMethod: 'Static'
          privateIPAddress:          vm1PrivateIp
          publicIPAddress:           { id: vm1PublicIp.id }
        }
      }
    ]
  }
}

resource vm2Nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'vm2-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet:                    { id: '${vnet.id}/subnets/vm2-subnet' }
          privateIPAllocationMethod: 'Static'
          privateIPAddress:          vm2PrivateIp
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Ubuntu VMs (Gen2 image matches B-series sizes)
// ---------------------------------------------------------------------------
var imageReference = {
  publisher: 'Canonical'
  offer:     '0001-com-ubuntu-server-jammy'
  sku:       '22_04-lts-gen2'
  version:   'latest'
}

var osDisk = {
  createOption: 'FromImage'
  managedDisk:  { storageAccountType: 'Standard_LRS' }
  deleteOption: 'Delete'
}

resource vm1 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm1'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile:  { imageReference: imageReference, osDisk: osDisk }
    osProfile: {
      computerName:  'vm1'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }] }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: vm1Nic.id, properties: { deleteOption: 'Delete' } }]
    }
  }
}

resource vm2 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm2'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile:  { imageReference: imageReference, osDisk: osDisk }
    osProfile: {
      computerName:  'vm2'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }] }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: vm2Nic.id, properties: { deleteOption: 'Delete' } }]
    }
  }
}

// ---------------------------------------------------------------------------
// Bastion Developer SKU — free, browser-based SSH, no dedicated subnet needed
// ---------------------------------------------------------------------------
resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: 'netmon-bastion'
  location: location
  sku: { name: 'Developer' }
  properties: {
    virtualNetwork: { id: vnet.id }
  }
}

output vm1Id          string = vm1.id
output vm2Id          string = vm2.id
output vm1Name        string = vm1.name
output vm2Name        string = vm2.name
output vm1PrivateIp   string = vm1PrivateIp
output vm2PrivateIp   string = vm2PrivateIp
output vm1PublicIp    string = vm1PublicIp.properties.ipAddress
output nsgVm1Id       string = nsgVm1.id
output nsgVm2Id       string = nsgVm2.id
output nsgVm1Name     string = nsgVm1.name
output nsgVm2Name     string = nsgVm2.name
output vnetId         string = vnet.id
