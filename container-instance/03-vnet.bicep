// =============================================================================
// Step 3 — VNet integration (private subnet) + jump VM + Bastion
//
// Deploys ACI into a dedicated subnet — no public IP, private access only.
// Includes a jump VM and Azure Bastion (Developer SKU, free) so you can
// SSH into the VM via the Azure Portal and curl the ACI from there.
//
// Subnets:
//   aci-subnet  10.0.1.0/24  — delegated to ContainerInstance
//   vm-subnet   10.0.2.0/24  — jump VM (private IP only)
//
// Note: Bastion Developer SKU is free but browser-based only.
//   Connect via: Azure Portal → VM → Connect → Bastion
//   CLI native client (az network bastion ssh) requires Standard SKU.
//
// Usage:
//   az deployment group create \
//     --resource-group rg-container-instance \
//     --template-file 03-vnet.bicep \
//     --parameters @parameters/03-vnet.json \
//     --parameters registryPassword="$ACR_PASSWORD" \
//     --parameters sshPublicKey="$(cat ~/.ssh/id_rsa.pub)"
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Name of the container group.')
param containerGroupName string = 'backend-aci-vnet'

@description('ACR registry name (without .azurecr.io).')
param registryName string

@description('Container image name and tag.')
param containerImage string = 'backend:latest'

@description('ACR admin password.')
@secure()
param registryPassword string

@description('Port the container listens on.')
param port int = 3000

@description('Admin username for the jump VM.')
param adminUsername string = 'azureuser'

@description('SSH public key for the jump VM.')
param sshPublicKey string

@description('VM size for the jump VM.')
param vmSize string = 'Standard_B2ats_v2'

@description('Number of vCPUs to allocate to the container.')
param cpuCores int = 1

@description('Memory in GB to allocate to the container.')
param memoryGb string = '1'

var registryServer   = '${registryName}.azurecr.io'
var registryUsername = registryName
var fullImage        = '${registryServer}/${containerImage}'

// ---------------------------------------------------------------------------
// VNet — two subnets: ACI (delegated) and VM (jump host)
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'aci-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.0.0.0/16' ]
    }
    subnets: [
      {
        name: 'aci-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          delegations: [
            {
              name: 'aci-delegation'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
      {
        name: 'vm-subnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// NSG for VM subnet — no inbound from internet (Bastion handles SSH)
// ---------------------------------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: 'vm-subnet-nsg'
  location: location
  properties: {
    securityRules: []   // Bastion tunnels SSH internally — no public port 22 needed
  }
}

// ---------------------------------------------------------------------------
// Jump VM NIC — private IP only, no public IP
// ---------------------------------------------------------------------------
resource vmNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'jump-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet:                     { id: '${vnet.id}/subnets/vm-subnet' }
          privateIPAllocationMethod:  'Dynamic'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Jump VM
// ---------------------------------------------------------------------------
resource jumpVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'jump-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer:     '0001-com-ubuntu-server-jammy'
        sku:       '22_04-lts'
        version:   'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
        deleteOption: 'Delete'
      }
    }
    osProfile: {
      computerName:         'jump-vm'
      adminUsername:        adminUsername
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
    networkProfile: {
      networkInterfaces: [
        { id: vmNic.id, properties: { deleteOption: 'Delete' } }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Azure Bastion — Developer SKU (free, browser-based)
// ---------------------------------------------------------------------------
resource bastion 'Microsoft.Network/bastionHosts@2023-09-01' = {
  name: 'aci-bastion'
  location: location
  sku: {
    name: 'Developer'
  }
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// ---------------------------------------------------------------------------
// Container Group — private, VNet-integrated
// ---------------------------------------------------------------------------
resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: location
  properties: {
    osType: 'Linux'
    restartPolicy: 'Always'

    imageRegistryCredentials: [
      {
        server:   registryServer
        username: registryUsername
        password: registryPassword
      }
    ]

    subnetIds: [
      { id: '${vnet.id}/subnets/aci-subnet' }
    ]

    ipAddress: {
      type: 'Private'
      ports: [
        { protocol: 'TCP', port: port }
      ]
    }

    containers: [
      {
        name: 'backend'
        properties: {
          image: fullImage
          ports: [ { protocol: 'TCP', port: port } ]
          environmentVariables: [
            { name: 'PORT', value: string(port) }
          ]
          resources: {
            requests: { cpu: cpuCores, memoryInGB: json(memoryGb) }
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Private IP of the ACI container group.')
output aciPrivateIp string = containerGroup.properties.ipAddress.ip

@description('Curl command to test from inside the jump VM.')
output testCommand string = 'curl http://${containerGroup.properties.ipAddress.ip}:${port}/api/message'
