// =============================================================================
// Step 3 — Enable spoke-to-spoke routing through the hub
//           (deploy AFTER 01-vnets.bicep and 02-peering.bicep)
//
// This step:
//   1. Creates route tables (UDRs) on spoke subnets pointing to hub-vm
//   2. Attaches the route tables to the spoke subnets
//
// After deploying, you must ALSO run these commands manually:
//
//   # Enable IP forwarding on hub-vm's NIC
//   az network nic update \
//     --resource-group rg-vnet-peering \
//     --name hub-vm-nic \
//     --ip-forwarding true
//
//   # Enable IP forwarding in the OS (SSH into hub-vm)
//   sudo sysctl -w net.ipv4.ip_forward=1
//   echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
//
// Usage:
//   az deployment group create \
//     --resource-group rg-vnet-peering \
//     --template-file 03-hub-routing.bicep \
//     --parameters hubVmPrivateIp=10.10.1.4
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Private IP address of hub-vm. Get it from: az vm list-ip-addresses -g rg-vnet-peering -n hub-vm --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv')
param hubVmPrivateIp string

// ---------------------------------------------------------------------------
// Reference existing NSG (created by 01-vnets.bicep)
// ---------------------------------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' existing = {
  name: 'peering-demo-nsg'
}

// ---------------------------------------------------------------------------
// Route table for Spoke A subnets: "to reach 10.2.0.0/16, go through hub-vm"
// ---------------------------------------------------------------------------
resource spokeARouteTable 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'spoke-a-to-spoke-b-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'to-spoke-b'
        properties: {
          addressPrefix:    '10.2.0.0/16'
          nextHopType:      'VirtualAppliance'
          nextHopIpAddress: hubVmPrivateIp
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Route table for Spoke B subnets: "to reach 10.1.0.0/16, go through hub-vm"
// ---------------------------------------------------------------------------
resource spokeBRouteTable 'Microsoft.Network/routeTables@2023-09-01' = {
  name: 'spoke-b-to-spoke-a-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'to-spoke-a'
        properties: {
          addressPrefix:    '10.1.0.0/16'
          nextHopType:      'VirtualAppliance'
          nextHopIpAddress: hubVmPrivateIp
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Attach route tables to spoke subnets
//
// We must redeclare the full VNet + subnet definition when updating — Azure
// replaces the subnet properties, so we include the existing NSG reference.
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
          addressPrefix:        '10.1.1.0/24'
          networkSecurityGroup: { id: nsg.id }
          routeTable:           { id: spokeARouteTable.id }
        }
      }
      {
        name: 'app'
        properties: {
          addressPrefix:        '10.1.2.0/24'
          networkSecurityGroup: { id: nsg.id }
          routeTable:           { id: spokeARouteTable.id }
        }
      }
    ]
  }
}

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
          addressPrefix:        '10.2.1.0/24'
          networkSecurityGroup: { id: nsg.id }
          routeTable:           { id: spokeBRouteTable.id }
        }
      }
      {
        name: 'data'
        properties: {
          addressPrefix:        '10.2.2.0/24'
          networkSecurityGroup: { id: nsg.id }
          routeTable:           { id: spokeBRouteTable.id }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output nextSteps string = 'Now run: az network nic update -g rg-vnet-peering -n hub-vm-nic --ip-forwarding true && SSH into hub-vm and run: sudo sysctl -w net.ipv4.ip_forward=1'
output spokeARouteTableId string = spokeARouteTable.id
output spokeBRouteTableId string = spokeBRouteTable.id
