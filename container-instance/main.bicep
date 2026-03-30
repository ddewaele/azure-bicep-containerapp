// =============================================================================
// Azure Container Instance — single backend container
//
// Deploys the backend API container directly via ACI (no orchestrator needed).
// The container is pulled from Azure Container Registry using admin credentials.
//
// Usage:
//   az group create --name rg-container-instance --location westeurope
//
//   az deployment group create \
//     --resource-group rg-container-instance \
//     --template-file main.bicep \
//     --parameters @parameters/main.json \
//     --parameters registryPassword='<acr-admin-password>'
//
// Get the ACR admin password:
//   az acr credential show --name <registryName> --query "passwords[0].value" -o tsv
//
// After deploying, get the public IP:
//   az container show \
//     --resource-group rg-container-instance \
//     --name backend-aci \
//     --query ipAddress.ip -o tsv
//
// Then test:
//   curl http://<ip>:3000/api/message
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Name of the container group.')
param containerGroupName string = 'backend-aci'

@description('ACR registry name (without .azurecr.io), e.g. myregistry')
param registryName string

@description('Container image name and tag to deploy, e.g. backend:latest')
param containerImage string = 'backend:latest'

@description('ACR admin password.')
@secure()
param registryPassword string

var registryServer   = '${registryName}.azurecr.io'
var registryUsername = registryName
var fullImage        = '${registryServer}/${containerImage}'

@description('Number of vCPUs to allocate.')
param cpuCores int = 1

@description('Memory in GB to allocate.')
param memoryGb string = '1'

@description('Port the container listens on.')
param port int = 3000

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
      ports: [
        {
          protocol: 'TCP'
          port: port
        }
      ]
    }

    containers: [
      {
        name: 'backend'
        properties: {
          image: fullImage
          ports: [
            {
              protocol: 'TCP'
              port: port
            }
          ]
          environmentVariables: [
            {
              name:  'PORT'
              value: string(port)
            }
          ]
          resources: {
            requests: {
              cpu:        cpuCores
              memoryInGB: json(memoryGb)
            }
          }
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Public IP address of the container group.')
output publicIp string = containerGroup.properties.ipAddress.ip

@description('Full URL to the API endpoint.')
output apiUrl string = 'http://${containerGroup.properties.ipAddress.ip}:${port}/api/message'
