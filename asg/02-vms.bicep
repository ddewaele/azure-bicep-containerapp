// =============================================================================
// Step 2 — VMs: web-vm-1, web-vm-2, logic-vm, db-vm
//
// Each VM NIC is assigned to its ASG — this is what grants it membership
// in the tier and makes the NSG rules from 01-network.bicep apply.
//
//   web-vm-1  NIC → asg-web    (Node.js web server :80, public IP)
//   web-vm-2  NIC → asg-web    (Node.js web server :80)
//   logic-vm  NIC → asg-logic  (Node.js API :3000, queries PostgreSQL)
//   db-vm     NIC → asg-db     (PostgreSQL :5432)
//
// Static private IPs are used so cloud-init can reference other VMs by IP.
// The IPs are injected into the cloud-init templates via replace().
//
// Requires 01-network.bicep to be deployed first.
//
// Usage:
//   az deployment group create \
//     --resource-group rg-asg-demo \
//     --template-file 02-vms.bicep \
//     --parameters @parameters/02-vms.json \
//     --parameters sshPublicKey="$(cat ~/.ssh/id_rsa.pub)"
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Admin username for all VMs.')
param adminUsername string = 'azureuser'

@description('SSH public key for all VMs.')
param sshPublicKey string

@description('VM size for all VMs.')
param vmSize string = 'Standard_B2ats_v2'

// Static private IPs — injected into cloud-init so each VM knows its peers
@description('Static private IP for logic-vm.')
param logicVmPrivateIp string = '10.0.1.20'

@description('Static private IP for db-vm.')
param dbVmPrivateIp string = '10.0.2.10'

// ---------------------------------------------------------------------------
// References to resources deployed by 01-network.bicep
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: 'asg-vnet'
}

resource asgWeb 'Microsoft.Network/applicationSecurityGroups@2023-09-01' existing = {
  name: 'asg-web'
}

resource asgLogic 'Microsoft.Network/applicationSecurityGroups@2023-09-01' existing = {
  name: 'asg-logic'
}

resource asgDb 'Microsoft.Network/applicationSecurityGroups@2023-09-01' existing = {
  name: 'asg-db'
}

// ---------------------------------------------------------------------------
// Cloud-init scripts
// Token replacement injects private IPs so cloud-init doesn't need to
// discover them at runtime.
// ---------------------------------------------------------------------------
var webCloudInit = base64(
  replace(
    replace(loadTextContent('cloud-init/web.yaml'), '__LOGIC_VM_IP__', logicVmPrivateIp),
    '__DB_VM_IP__', dbVmPrivateIp
  )
)

var logicCloudInit = base64(
  replace(loadTextContent('cloud-init/logic.yaml'), '__DB_VM_IP__', dbVmPrivateIp)
)

var dbCloudInit = base64(loadTextContent('cloud-init/db.yaml'))

// ---------------------------------------------------------------------------
// Shared VM configuration
// ---------------------------------------------------------------------------
var imageReference = {
  publisher: 'Canonical'
  offer:     '0001-com-ubuntu-server-jammy'
  sku:       '22_04-lts'
  version:   'latest'
}

var osDisk = {
  createOption: 'FromImage'
  managedDisk:  { storageAccountType: 'Standard_LRS' }
  deleteOption: 'Delete'
}

// ---------------------------------------------------------------------------
// Public IP — web-vm-1 only (internet entry point for the demo)
// ---------------------------------------------------------------------------
resource webVm1PublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'web-vm-1-pip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

// ---------------------------------------------------------------------------
// NICs — static private IPs so cloud-init token replacement is consistent
// ---------------------------------------------------------------------------
resource webVm1Nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'web-vm-1-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet:                    { id: '${vnet.id}/subnets/web-subnet' }
          privateIPAllocationMethod: 'Static'
          privateIPAddress:          '10.0.1.10'
          publicIPAddress:           { id: webVm1PublicIp.id }
          applicationSecurityGroups: [{ id: asgWeb.id }]
        }
      }
    ]
  }
}

resource webVm2Nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'web-vm-2-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet:                    { id: '${vnet.id}/subnets/web-subnet' }
          privateIPAllocationMethod: 'Static'
          privateIPAddress:          '10.0.1.11'
          applicationSecurityGroups: [{ id: asgWeb.id }]
        }
      }
    ]
  }
}

resource logicVmNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'logic-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet:                    { id: '${vnet.id}/subnets/web-subnet' }
          privateIPAllocationMethod: 'Static'
          privateIPAddress:          logicVmPrivateIp
          applicationSecurityGroups: [{ id: asgLogic.id }]
        }
      }
    ]
  }
}

resource dbVmNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'db-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet:                    { id: '${vnet.id}/subnets/db-subnet' }
          privateIPAllocationMethod: 'Static'
          privateIPAddress:          dbVmPrivateIp
          applicationSecurityGroups: [{ id: asgDb.id }]
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// VMs
// ---------------------------------------------------------------------------
resource webVm1 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'web-vm-1'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile:  { imageReference: imageReference, osDisk: osDisk }
    osProfile: {
      computerName:  'web-vm-1'
      adminUsername: adminUsername
      customData:    webCloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }] }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: webVm1Nic.id, properties: { deleteOption: 'Delete' } }]
    }
  }
}

resource webVm2 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'web-vm-2'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile:  { imageReference: imageReference, osDisk: osDisk }
    osProfile: {
      computerName:  'web-vm-2'
      adminUsername: adminUsername
      customData:    webCloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }] }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: webVm2Nic.id, properties: { deleteOption: 'Delete' } }]
    }
  }
}

resource logicVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'logic-vm'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile:  { imageReference: imageReference, osDisk: osDisk }
    osProfile: {
      computerName:  'logic-vm'
      adminUsername: adminUsername
      customData:    logicCloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }] }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: logicVmNic.id, properties: { deleteOption: 'Delete' } }]
    }
  }
}

resource dbVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'db-vm'
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile:  { imageReference: imageReference, osDisk: osDisk }
    osProfile: {
      computerName:  'db-vm'
      adminUsername: adminUsername
      customData:    dbCloudInit
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: { publicKeys: [{ path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: sshPublicKey }] }
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: dbVmNic.id, properties: { deleteOption: 'Delete' } }]
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output webVm1PublicIp   string = webVm1PublicIp.properties.ipAddress
output webVm1PrivateIp  string = webVm1Nic.properties.ipConfigurations[0].properties.privateIPAddress
output webVm2PrivateIp  string = webVm2Nic.properties.ipConfigurations[0].properties.privateIPAddress
output logicVmPrivateIp string = logicVmNic.properties.ipConfigurations[0].properties.privateIPAddress
output dbVmPrivateIp    string = dbVmNic.properties.ipConfigurations[0].properties.privateIPAddress
