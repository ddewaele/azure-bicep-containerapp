// =============================================================================
// Cheapest Azure Linux VM — Standard_B1s (1 vCPU, 1 GiB RAM, ~$3.80/month)
//
// Deploys: VNet + Subnet, NSG, Public IP, NIC, and the VM itself.
// Uses SSH key authentication (no password) for security.
// =============================================================================
targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name prefix for all resources.')
@minLength(3)
@maxLength(12)
param prefix string = 'cheapvm'

@description('Admin username for the VM.')
param adminUsername string = 'azureuser'

@description('SSH public key for authentication. Generate with: ssh-keygen -t ed25519')
@secure()
param sshPublicKey string

@description('VM size — Standard_B1s is the cheapest general-purpose option.')
param vmSize string = 'Standard_B1s'

// ---------------------------------------------------------------------------
// Locals
// ---------------------------------------------------------------------------

var uniqueSuffix = uniqueString(resourceGroup().id)
var vmName       = '${prefix}-vm'

// ---------------------------------------------------------------------------
// Network Security Group — allow SSH only
// ---------------------------------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${prefix}-nsg'
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
    ]
  }
}

// ---------------------------------------------------------------------------
// Virtual Network + Subnet
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${prefix}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/24' ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Public IP (Basic SKU — free when attached to a running VM)
// ---------------------------------------------------------------------------
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${prefix}-pip'
  location: location
  sku: { name: 'Basic' }
  properties: {
    publicIPAllocationMethod: 'Dynamic'
    dnsSettings: {
      domainNameLabel: '${prefix}-${uniqueSuffix}'
    }
  }
}

// ---------------------------------------------------------------------------
// Network Interface
// ---------------------------------------------------------------------------
resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${prefix}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet:                  { id: vnet.properties.subnets[0].id }
          publicIPAddress:         { id: publicIp.id }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Virtual Machine — B1s, Ubuntu 24.04, SSH key auth, no password
// ---------------------------------------------------------------------------
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }

    osProfile: {
      computerName:  vmName
      adminUsername:  adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path:    '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }

    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer:     'ubuntu-24_04-lts'
        sku:       'server'
        version:   'latest'
      }
      osDisk: {
        name:         '${vmName}-osdisk'
        createOption: 'FromImage'
        managedDisk: {
          // Standard HDD is the cheapest disk type
          storageAccountType: 'Standard_LRS'
        }
        diskSizeGB: 30
      }
    }

    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Public IP address of the VM (available after the VM starts).')
output publicIpAddress string = publicIp.properties.ipAddress

@description('DNS name to connect via SSH.')
output fqdn string = publicIp.properties.dnsSettings.fqdn

@description('SSH command to connect to the VM.')
output sshCommand string = 'ssh ${adminUsername}@${publicIp.properties.dnsSettings.fqdn}'
