// =============================================================================
// Step 2 — Azure-side VNet + bidirectional peering to the on-prem VNet
//
//   azure-vnet 10.20.0.0/16
//     ├── azure-subnet 10.20.1.0/24
//     └── pe-subnet    10.20.2.0/24  (for private endpoints in step 3)
//
//   onprem-vnet <────────── peered ──────────> azure-vnet
//
// Requires 01-onprem-vnet.bicep to have been deployed first (references
// onprem-vnet by name via an existing resource).
//
// Usage:
//   az deployment group create \
//     --resource-group $RG \
//     --template-file 02-azure-vnet.bicep \
//     --parameters @parameters/02-azure-vnet.json
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Address space for the Azure-side VNet.')
param vnetAddressPrefix string = '10.20.0.0/16'

@description('General-purpose Azure subnet.')
param subnetAddressPrefix string = '10.20.1.0/24'

@description('Subnet for private endpoints (private endpoint network policies disabled).')
param peSubnetAddressPrefix string = '10.20.2.0/24'

// ---------------------------------------------------------------------------
// Reference the on-prem VNet created by 01-onprem-vnet.bicep
// ---------------------------------------------------------------------------
resource onpremVnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: 'onprem-vnet'
}

// ---------------------------------------------------------------------------
// Azure-side VNet
// ---------------------------------------------------------------------------
resource azureVnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'azure-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ vnetAddressPrefix ]
    }
    subnets: [
      {
        name: 'azure-subnet'
        properties: {
          addressPrefix: subnetAddressPrefix
        }
      }
      {
        name: 'pe-subnet'
        properties: {
          addressPrefix:                    peSubnetAddressPrefix
          privateEndpointNetworkPolicies:   'Disabled'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Bidirectional peering between Azure VNet and on-prem VNet
// ---------------------------------------------------------------------------
resource peerAzureToOnprem 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  name:   'azure-to-onprem'
  parent: azureVnet
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic:     false
    allowGatewayTransit:       false
    useRemoteGateways:         false
    remoteVirtualNetwork:      { id: onpremVnet.id }
  }
}

resource peerOnpremToAzure 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  name:   'onprem-to-azure'
  parent: onpremVnet
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic:     false
    allowGatewayTransit:       false
    useRemoteGateways:         false
    remoteVirtualNetwork:      { id: azureVnet.id }
  }
}

output azureVnetId  string = azureVnet.id
output azureVnetName string = azureVnet.name
output peSubnetId   string = '${azureVnet.id}/subnets/pe-subnet'
