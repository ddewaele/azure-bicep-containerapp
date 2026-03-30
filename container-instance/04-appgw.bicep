// =============================================================================
// Step 4 — Application Gateway in front of ACI
//
// Traffic flow:
//   Internet → App GW public IP (port 80) → ACI private IP (port 3000)
//
// Resources created:
//   - VNet with two subnets:
//       aci-subnet    10.0.1.0/24  (delegated to ContainerInstance)
//       appgw-subnet  10.0.2.0/24  (reserved for Application Gateway)
//   - Public IP for App GW
//   - Application Gateway Standard_v2
//   - ACI container group (private, VNet-integrated)
//
// Note: Standard_v2 App GW minimum cost is ~$0.008/hr + capacity units.
//       Delete the resource group when done to avoid charges.
//
// Usage:
//   az deployment group create \
//     --resource-group rg-container-instance \
//     --template-file 04-appgw.bicep \
//     --parameters @parameters/04-appgw.json \
//     --parameters registryPassword="$ACR_PASSWORD"
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Name of the container group.')
param containerGroupName string = 'backend-aci-appgw'

@description('ACR registry name (without .azurecr.io).')
param registryName string

@description('Container image name and tag.')
param containerImage string = 'backend:latest'

@description('ACR admin password.')
@secure()
param registryPassword string

@description('Port the container listens on.')
param port int = 3000

var registryServer   = '${registryName}.azurecr.io'
var registryUsername = registryName
var fullImage        = '${registryServer}/${containerImage}'
var appGwName        = 'aci-appgw'

// ---------------------------------------------------------------------------
// VNet — two subnets: one for ACI, one for App GW
// ---------------------------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: 'aci-appgw-vnet'
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
        name: 'appgw-subnet'
        properties: {
          addressPrefix: '10.0.2.0/24'
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Public IP for Application Gateway
// ---------------------------------------------------------------------------
resource appGwPublicIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: 'appgw-pip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
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
            requests: { cpu: 1, memoryInGB: json('1') }
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Application Gateway Standard_v2
//
// Internal IDs for App GW sub-resources must be constructed with resourceId()
// because Bicep doesn't support child-resource references within the same
// parent resource block.
// ---------------------------------------------------------------------------
resource appGw 'Microsoft.Network/applicationGateways@2023-09-01' = {
  name: appGwName
  location: location
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 1
    }

    gatewayIPConfigurations: [
      {
        name: 'appgw-ip-config'
        properties: {
          subnet: { id: '${vnet.id}/subnets/appgw-subnet' }
        }
      }
    ]

    frontendIPConfigurations: [
      {
        name: 'appgw-frontend-ip'
        properties: {
          publicIPAddress: { id: appGwPublicIp.id }
        }
      }
    ]

    frontendPorts: [
      {
        name: 'port-80'
        properties: { port: 80 }
      }
    ]

    backendAddressPools: [
      {
        name: 'aci-backend-pool'
        properties: {
          backendAddresses: [
            // Route traffic to the ACI private IP
            { ipAddress: containerGroup.properties.ipAddress.ip }
          ]
        }
      }
    ]

    backendHttpSettingsCollection: [
      {
        name: 'aci-http-settings'
        properties: {
          port: port
          protocol: 'Http'
          requestTimeout: 30
          pickHostNameFromBackendAddress: false
        }
      }
    ]

    httpListeners: [
      {
        name: 'http-listener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'appgw-frontend-ip')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port-80')
          }
          protocol: 'Http'
        }
      }
    ]

    requestRoutingRules: [
      {
        name: 'aci-routing-rule'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'http-listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'aci-backend-pool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGwName, 'aci-http-settings')
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Public IP of the Application Gateway — use this to reach the API.')
output appGwPublicIp string = appGwPublicIp.properties.ipAddress

@description('Full URL to the API endpoint (via App GW on port 80).')
output apiUrl string = 'http://${appGwPublicIp.properties.ipAddress}/api/message'

@description('ACI private IP (not directly reachable from internet).')
output aciPrivateIp string = containerGroup.properties.ipAddress.ip
