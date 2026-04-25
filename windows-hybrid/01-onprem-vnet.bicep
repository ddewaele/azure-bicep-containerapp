// =============================================================================
// Step 1 — "On-prem" VNet + Windows Server VM + Bastion Developer
//
// Simulates an on-prem environment inside Azure. The Windows VM is promoted
// to a domain controller manually via PowerShell (see scripts/setup-adds.ps1)
// after RDP'ing in through Bastion.
//
//   onprem-vnet 10.10.0.0/16
//     └── onprem-subnet 10.10.1.0/24
//           └── dc-vm (Windows Server 2022, static IP 10.10.1.10)
//     └── Bastion Developer SKU (free, browser RDP)
//
// Usage:
//   az deployment group create \
//     --resource-group $RG \
//     --template-file 01-onprem-vnet.bicep \
//     --parameters @parameters/01-onprem-vnet.json \
//     --parameters adminPassword='<YourStrongPassword>'
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Local admin username for the Windows VM.')
param adminUsername string = 'azureadmin'

@description('Local admin password. Min 12 chars, must include upper/lower/digit/special.')
@secure()
@minLength(12)
param adminPassword string

@description('VM size. B2s (2 vCPU / 4 GiB) is the cheapest that runs AD DS comfortably.')
param vmSize string = 'Standard_B2s'

@description('Address space for the simulated on-prem VNet.')
param vnetAddressPrefix string = '10.10.0.0/16'

@description('Subnet for the Windows Server VM.')
param subnetAddressPrefix string = '10.10.1.0/24'

@description('Static private IP for the domain controller.')
param dcPrivateIp string = '10.10.1.10'

@description('Source IP (or CIDR) allowed to RDP directly over the public IP. Defaults to "*" = any — restrict to your own IP for production.')
param rdpSourceAddressPrefix string = '*'

// ---------------------------------------------------------------------------
// NSG for the on-prem subnet
// VNet-internal traffic is allowed (so Bastion keeps working). RDP over the
// public IP is also allowed, restricted to rdpSourceAddressPrefix.
// ---------------------------------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'onprem-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-bastion-rdp'
        properties: {
          priority:                 100
          protocol:                 'Tcp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      'VirtualNetwork'
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '3389'
        }
      }
      {
        name: 'allow-internet-rdp'
        properties: {
          priority:                 105
          protocol:                 'Tcp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      rdpSourceAddressPrefix
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '3389'
        }
      }
      {
        name: 'allow-vnet-smb'
        properties: {
          priority:                 110
          protocol:                 'Tcp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      'VirtualNetwork'
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '445'
        }
      }
      {
        name: 'allow-vnet-ad'
        properties: {
          priority:                 120
          protocol:                 '*'
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
// VNet — single subnet for the DC/file server
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'onprem-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetAddressPrefix ]
    }
    subnets: [
      {
        name: 'onprem-subnet'
        properties: {
          addressPrefix:        subnetAddressPrefix
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Public IP — allows direct RDP from your machine without going via Bastion.
// Standard SKU, static so the address doesn't change across reboots.
// ---------------------------------------------------------------------------
resource dcPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'dc-vm-pip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// ---------------------------------------------------------------------------
// NIC — static private IP so scripts can reference the DC by a known address
// ---------------------------------------------------------------------------
resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'dc-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress:          dcPrivateIp
          subnet:                    { id: '${vnet.id}/subnets/onprem-subnet' }
          publicIPAddress:           { id: dcPublicIp.id }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Windows Server 2022 VM — promoted to DC manually (scripts/setup-adds.ps1)
// Gen1 image runs on B-series sizes without Trusted Launch
// ---------------------------------------------------------------------------
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'dc-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName:  'DC-VM'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent:       true
        enableAutomaticUpdates: false
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer:     'WindowsServer'
        sku:       '2022-datacenter'
        version:   'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk:  { storageAccountType: 'Standard_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
  }
}

// ---------------------------------------------------------------------------
// Azure Bastion — Developer SKU (free, browser-based RDP)
// No dedicated subnet needed for Developer SKU.
// ---------------------------------------------------------------------------
resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: 'onprem-bastion'
  location: location
  sku: { name: 'Developer' }
  properties: {
    virtualNetwork: { id: vnet.id }
  }
}

output vnetId       string = vnet.id
output vnetName     string = vnet.name
output dcPrivateIp  string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output dcPublicIp   string = dcPublicIp.properties.ipAddress
output vmName       string = vm.name
