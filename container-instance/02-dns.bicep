// =============================================================================
// Step 2 — Add DNS name label
//
// Instead of a raw IP, ACI assigns a stable FQDN:
//   <dnsNameLabel>.<region>.azurecontainer.io
//
// The label must be unique within the region.
//
// Usage:
//   az deployment group create \
//     --resource-group rg-container-instance \
//     --template-file 02-dns.bicep \
//     --parameters @parameters/02-dns.json \
//     --parameters registryPassword="$ACR_PASSWORD"
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Name of the container group.')
param containerGroupName string = 'backend-aci-dns'

@description('ACR registry name (without .azurecr.io).')
param registryName string

@description('Container image name and tag.')
param containerImage string = 'backend:latest'

@description('ACR admin password.')
@secure()
param registryPassword string

@description('Port the container listens on.')
param port int = 3000

@description('Number of vCPUs to allocate (0.1–4).')
param cpuCores string = '0.1'

@description('Memory in GiB to allocate (0.1–16).')
param memoryGb string = '0.1'

@description('DNS label — must be unique in the region. FQDN: <label>.<region>.azurecontainer.io')
param dnsNameLabel string = 'backend-aci'

var registryServer   = '${registryName}.azurecr.io'
var registryUsername = registryName
var fullImage        = '${registryServer}/${containerImage}'

// ---------------------------------------------------------------------------
// Container Group
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

    ipAddress: {
      type: 'Public'
      dnsNameLabel: dnsNameLabel    // <-- assigns FQDN instead of bare IP
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
            requests: { cpu: json(cpuCores), memoryInGB: json(memoryGb) }
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Fully-qualified domain name assigned by Azure.')
output fqdn string = containerGroup.properties.ipAddress.fqdn

@description('Full URL to the API endpoint.')
output apiUrl string = 'http://${containerGroup.properties.ipAddress.fqdn}:${port}/api/message'
