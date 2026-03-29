// =============================================================================
// Step 2 — Add hub-spoke peering (deploy AFTER 01-vnets.bicep)
//
// Creates bidirectional peering:
//   Hub ↔ Spoke A
//   Hub ↔ Spoke B
//   (NO direct peering between Spoke A and Spoke B)
//
// After deploying, test that:
//   ✓ hub-vm can ping spoke VMs (and vice versa)
//   ✗ spoke-a-web STILL cannot ping spoke-b-web (peering is NOT transitive)
//
// Usage:
//   az deployment group create \
//     --resource-group rg-vnet-peering \
//     --template-file 02-peering.bicep
// =============================================================================
targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Reference existing VNets (created by 01-vnets.bicep)
// ---------------------------------------------------------------------------
resource hubVnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: 'hub-vnet'
}

resource spokeAVnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: 'spoke-a-vnet'
}

resource spokeBVnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: 'spoke-b-vnet'
}

// ---------------------------------------------------------------------------
// Hub ↔ Spoke A peering
// ---------------------------------------------------------------------------
resource hubToSpokeA 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: hubVnet
  name: 'hub-to-spoke-a'
  properties: {
    remoteVirtualNetwork:      { id: spokeAVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic:     true    // hub accepts forwarded traffic (needed for step 3)
    allowGatewayTransit:       false
    useRemoteGateways:         false
  }
}

resource spokeAToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: spokeAVnet
  name: 'spoke-a-to-hub'
  properties: {
    remoteVirtualNetwork:      { id: hubVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic:     true    // spoke accepts forwarded traffic back from hub
    allowGatewayTransit:       false
    useRemoteGateways:         false
  }
}

// ---------------------------------------------------------------------------
// Hub ↔ Spoke B peering
// ---------------------------------------------------------------------------
resource hubToSpokeB 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: hubVnet
  name: 'hub-to-spoke-b'
  properties: {
    remoteVirtualNetwork:      { id: spokeBVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic:     true
    allowGatewayTransit:       false
    useRemoteGateways:         false
  }
}

resource spokeBToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  parent: spokeBVnet
  name: 'spoke-b-to-hub'
  properties: {
    remoteVirtualNetwork:      { id: hubVnet.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic:     true
    allowGatewayTransit:       false
    useRemoteGateways:         false
  }
}
