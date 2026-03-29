// =============================================================================
// Step 3 — Enable spoke-to-spoke routing through the hub
//           (deploy AFTER 01-vnets.bicep and 02-peering.bicep)
//
// This step:
//   1. Enables IP forwarding on hub-vm's NIC (so it can act as a router)
//   2. Creates route tables (UDRs) on spoke subnets pointing to hub-vm
//   3. Runs a command on hub-vm to enable IP forwarding in the OS
//
// After deploying, test that:
//   ✓ spoke-a-web can ping spoke-b-web (traffic flows through hub-vm)
//
// NOTE: You must also enable IP forwarding inside the hub-vm OS:
//   ssh into hub-vm and run:
//     sudo sysctl -w net.ipv4.ip_forward=1
//     echo 'net.ipv4.ip_forward=1' | sudo tee -a /etc/sysctl.conf
//
// Usage:
//   az deployment group create \
//     --resource-group rg-vnet-peering \
//     --template-file 03-hub-routing.bicep
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

// ---------------------------------------------------------------------------
// Reference existing resources (created by 01-vnets.bicep)
// ---------------------------------------------------------------------------
resource hubNic 'Microsoft.Network/networkInterfaces@2023-09-01' existing = {
  name: 'hub-vm-nic'
}

resource spokeAVnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: 'spoke-a-vnet'
}

resource spokeBVnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: 'spoke-b-vnet'
}

// ---------------------------------------------------------------------------
// Enable IP forwarding on hub-vm's NIC
// ---------------------------------------------------------------------------
// We need to redeclare the NIC with enableIPForwarding set to true.
// This updates the existing NIC in-place.
resource hubNicUpdate 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: 'hub-vm-nic'
  location: location
  properties: {
    enableIPForwarding: true
    ipConfigurations: hubNic.properties.ipConfigurations
  }
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
          nextHopIpAddress: hubNic.properties.ipConfigurations[0].properties.privateIPAddress
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
          nextHopIpAddress: hubNic.properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Attach route tables to spoke subnets
//
// We must redeclare the full subnet definition when updating — Azure replaces
// the subnet properties, so we include the existing NSG reference.
// ---------------------------------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' existing = {
  name: 'peering-demo-nsg'
}

resource spokeAVnetUpdate 'Microsoft.Network/virtualNetworks@2023-09-01' = {
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

resource spokeBVnetUpdate 'Microsoft.Network/virtualNetworks@2023-09-01' = {
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

output hubVmIpForwarding string = 'NIC IP forwarding enabled. Now SSH into hub-vm and run: sudo sysctl -w net.ipv4.ip_forward=1'
output spokeARouteTableId string = spokeARouteTable.id
output spokeBRouteTableId string = spokeBRouteTable.id
