// =============================================================================
// Step 3 — Azure Files + Storage Sync Service (hybrid file sync infrastructure)
//
// Creates:
//   • Storage Account + File Share (the cloud half of the sync)
//   • Private endpoint for the file service, reachable from both VNets
//   • Private DNS zone linked to both VNets so UNC paths resolve privately
//   • Storage Sync Service + Sync Group
//
// Manual steps (done after this Bicep deploys):
//   1. Create the cloud endpoint (`az storagesync sync-group cloud-endpoint create`).
//      Requires the Storage Sync service principal to have "Reader and Data Access"
//      on the storage account — usually auto-granted on first use.
//   2. Install the Azure File Sync agent on dc-vm (scripts/install-filesync-agent.ps1).
//   3. Register dc-vm with the sync service (from the agent UI, or via PowerShell).
//   4. Create a server endpoint pointing at a local path (e.g. D:\SyncedData).
//
// Requires 02-azure-vnet.bicep to have been deployed first.
//
// Usage:
//   az deployment group create \
//     --resource-group $RG \
//     --template-file 03-file-sync.bicep \
//     --parameters @parameters/03-file-sync.json
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Globally-unique storage account name. 3-24 chars, lowercase/digits only.')
@minLength(3)
@maxLength(24)
param storageAccountName string = toLower('hybsync${uniqueString(resourceGroup().id)}')

@description('File share name.')
param fileShareName string = 'hybrid-share'

@description('File share quota in GiB.')
param fileShareQuotaGiB int = 100

@description('Storage Sync Service name.')
param syncServiceName string = 'hybrid-sync-svc'

@description('Sync Group name.')
param syncGroupName string = 'hybrid-sync-group'

// ---------------------------------------------------------------------------
// Reference the Azure VNet (for private endpoint + DNS link)
// ---------------------------------------------------------------------------
resource azureVnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: 'azure-vnet'

  resource peSubnet 'subnets' existing = {
    name: 'pe-subnet'
  }
}

// Reference the on-prem VNet (for DNS link so dc-vm can resolve the private endpoint)
resource onpremVnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: 'onprem-vnet'
}

// ---------------------------------------------------------------------------
// Storage Account + File Share
// ---------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name:     storageAccountName
  location: location
  kind:     'StorageV2'
  sku:      { name: 'Standard_LRS' }
  properties: {
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess:    false
    minimumTlsVersion:        'TLS1_2'
    // Public endpoint stays open by default — private endpoint is additive.
    // Set this to 'Disabled' to force private-only access once everything works.
    publicNetworkAccess: 'Enabled'
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storage
  name:   'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name:   fileShareName
  properties: {
    shareQuota: fileShareQuotaGiB
  }
}

// ---------------------------------------------------------------------------
// Storage Sync Service + Sync Group
// Cloud endpoint + server endpoint are created manually (see README).
// ---------------------------------------------------------------------------
resource syncService 'Microsoft.StorageSync/storageSyncServices@2022-09-01' = {
  name:     syncServiceName
  location: location
}

resource syncGroup 'Microsoft.StorageSync/storageSyncServices/syncGroups@2022-09-01' = {
  parent: syncService
  name:   syncGroupName
}

// ---------------------------------------------------------------------------
// Private endpoint for the file service
// ---------------------------------------------------------------------------
resource fileEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name:     'file-share-pe'
  location: location
  properties: {
    subnet: { id: azureVnet::peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'file-share-plsc'
        properties: {
          privateLinkServiceId: storage.id
          groupIds:             [ 'file' ]
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Private DNS zone — links both VNets so UNC paths resolve to the private IP
// ---------------------------------------------------------------------------
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name:     'privatelink.file.${environment().suffixes.storage}'
  location: 'global'
}

resource dnsLinkAzure 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent:   privateDnsZone
  name:     'azure-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork:      { id: azureVnet.id }
  }
}

resource dnsLinkOnprem 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent:   privateDnsZone
  name:     'onprem-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork:      { id: onpremVnet.id }
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: fileEndpoint
  name:   'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'file-config'
        properties: { privateDnsZoneId: privateDnsZone.id }
      }
    ]
  }
}

output storageAccountName string = storage.name
output fileShareName      string = fileShare.name
output syncServiceName    string = syncService.name
output syncGroupName      string = syncGroup.name
output fileShareUnc       string = '\\\\${storage.name}.file.${environment().suffixes.storage}\\${fileShare.name}'
