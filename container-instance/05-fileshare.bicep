// =============================================================================
// Step 5 — Azure Files volume mount
//
// Mounts an Azure File Share into the container at /mnt/data.
// The backend image used here must include the /api/files route
// (see backend/server.js in this project).
//
// After deploying, you can upload files to the share and read them via:
//   curl http://<ip>:3000/api/files
//
// Upload a test file:
//   az storage file upload \
//     --account-name <storageAccountName> \
//     --share-name aci-share \
//     --source <local-file> \
//     --account-key "$STORAGE_KEY"
//
// Usage:
//   az deployment group create \
//     --resource-group rg-container-instance \
//     --template-file 05-fileshare.bicep \
//     --parameters @parameters/05-fileshare.json \
//     --parameters registryPassword="$ACR_PASSWORD"
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Name of the container group.')
param containerGroupName string = 'backend-aci-files'

@description('ACR registry name (without .azurecr.io).')
param registryName string

@description('Container image name and tag. Must include the /api/files route.')
param containerImage string = 'backend:latest'

@description('ACR admin password.')
@secure()
param registryPassword string

@description('Port the container listens on.')
param port int = 3000

@description('Number of vCPUs to allocate.')
param cpuCores int = 1

@description('Memory in GB to allocate.')
param memoryGb string = '1'

@description('Path inside the container where the file share is mounted.')
param mountPath string = '/mnt/data'

var registryServer         = '${registryName}.azurecr.io'
var registryUsername       = registryName
var fullImage              = '${registryServer}/${containerImage}'
var storageAccountName     = 'acistorage${uniqueString(resourceGroup().id)}'
var fileShareName          = 'aci-share'

// ---------------------------------------------------------------------------
// Storage Account
// ---------------------------------------------------------------------------
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

// ---------------------------------------------------------------------------
// File Share
// ---------------------------------------------------------------------------
resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileService
  name: fileShareName
  properties: {
    shareQuota: 1   // 1 GiB — minimal for a demo
  }
}

// ---------------------------------------------------------------------------
// Container Group — with volume mount
// ---------------------------------------------------------------------------
resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: location
  dependsOn: [ fileShare ]
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
        { protocol: 'TCP', port: port }
      ]
    }

    // Volume definition — references the file share via storage account key
    volumes: [
      {
        name: 'myshare'
        azureFile: {
          shareName:          fileShareName
          storageAccountName: storageAccount.name
          storageAccountKey:  storageAccount.listKeys().keys[0].value
          readOnly:           false
        }
      }
    ]

    containers: [
      {
        name: 'backend'
        properties: {
          image: fullImage
          ports: [ { protocol: 'TCP', port: port } ]
          environmentVariables: [
            { name: 'PORT',       value: string(port) }
            { name: 'MOUNT_PATH', value: mountPath    }
          ]
          resources: {
            requests: { cpu: cpuCores, memoryInGB: json(memoryGb) }
          }
          // Mount the volume into the container
          volumeMounts: [
            {
              name:      'myshare'
              mountPath: mountPath
              readOnly:  false
            }
          ]
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Public IP of the container group.')
output publicIp string = containerGroup.properties.ipAddress.ip

@description('URL to list files in the mounted share.')
output filesUrl string = 'http://${containerGroup.properties.ipAddress.ip}:${port}/api/files'

@description('Storage account name — use this with az storage file upload.')
output storageAccountName string = storageAccount.name
