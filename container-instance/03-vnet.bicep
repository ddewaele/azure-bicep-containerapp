// =============================================================================
// Step 3 — VNet integration (private subnet)
//
// Deploys ACI into a dedicated subnet — no public IP, private access only.
//
// Key differences from main.bicep:
//   - Subnet must be delegated to Microsoft.ContainerInstance/containerGroups
//   - No public IP address on the container group
//   - Container group gets a private IP from the subnet range
//   - Access requires a VM or Bastion in the same (or peered) VNet
//
// Usage:
//   az deployment group create \
//     --resource-group rg-container-instance \
//     --template-file 03-vnet.bicep \
//     --parameters @parameters/03-vnet.json \
//     --parameters registryPassword="$ACR_PASSWORD"
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

var registryServer   = '${registryName}.azurecr.io'
var registryUsername = registryName
var fullImage        = '${registryServer}/${containerImage}'

// ---------------------------------------------------------------------------
// VNet — ACI requires its own delegated subnet
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
                // Required: subnet must be delegated exclusively to ACI
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
    ]
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

    // Placing ACI into the VNet subnet — no public IP
    subnetIds: [
      { id: '${vnet.id}/subnets/aci-subnet' }
    ]

    // Private port exposure (no ipAddress.type = 'Public')
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
// Outputs
// ---------------------------------------------------------------------------

@description('Private IP address of the container group within the VNet.')
output privateIp string = containerGroup.properties.ipAddress.ip

@description('VNet resource ID.')
output vnetId string = vnet.id
