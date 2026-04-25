// =============================================================================
// Step 3 — NSG Flow Logs + Traffic Analytics
//
// NSG Flow Logs (v2) stream 5-tuple flow records to a storage account as
// JSON blobs. Traffic Analytics is layered on top: it ingests those blobs,
// enriches them (geo, topology, flow type), and writes the result to the
// Log Analytics workspace where it can be queried via KQL / visualised in
// the Network Insights blade.
//
// Key detail: flow log resources live under Network Watcher, which Azure
// automatically creates in the `NetworkWatcherRG` resource group per
// subscription. We therefore deploy the flow log children into that RG
// via a cross-RG module.
//
// Prerequisite — ensure Network Watcher is enabled for the region:
//   az network watcher configure --enabled true --locations <region>
//
// Requires 01-network.bicep and 02-monitoring.bicep deployed first.
//
// Usage:
//   az deployment group create \
//     --resource-group $RG \
//     --template-file 03-flow-logs.bicep \
//     --parameters @parameters/03-flow-logs.json
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Resource group where Network Watcher lives. Default = Azure-managed NetworkWatcherRG.')
param networkWatcherRG string = 'NetworkWatcherRG'

@description('Globally-unique storage account name for flow log JSON blobs.')
@minLength(3)
@maxLength(24)
param storageAccountName string = toLower('netmon${uniqueString(resourceGroup().id)}')

@description('Flow log retention in days.')
param retentionDays int = 7

@description('Traffic Analytics processing interval in minutes: 10 or 60.')
@allowed([ 10, 60 ])
param trafficAnalyticsInterval int = 10

// ---------------------------------------------------------------------------
// Reference resources from steps 1 and 2
// ---------------------------------------------------------------------------
resource nsgVm1 'Microsoft.Network/networkSecurityGroups@2023-09-01' existing = {
  name: 'nsg-vm1'
}

resource nsgVm2 'Microsoft.Network/networkSecurityGroups@2023-09-01' existing = {
  name: 'nsg-vm2'
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: 'netmon-workspace'
}

// ---------------------------------------------------------------------------
// Storage account — destination for raw flow log JSON blobs
// Flow logs land in container `insights-logs-networksecuritygroupflowevent`
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
  }
}

// ---------------------------------------------------------------------------
// Flow logs — deployed cross-RG into NetworkWatcherRG
// Each flow log targets one NSG and optionally enables Traffic Analytics.
// ---------------------------------------------------------------------------
module flowLogNsg1 'modules/flow-log.bicep' = {
  name:  'nsg-vm1-flowlog'
  scope: resourceGroup(networkWatcherRG)
  params: {
    location:                 location
    flowLogName:              'nsg-vm1-flowlog'
    targetNsgId:              nsgVm1.id
    storageAccountId:         storage.id
    workspaceResourceId:      workspace.id
    workspaceCustomerGuid:    workspace.properties.customerId
    workspaceRegion:          workspace.location
    retentionDays:            retentionDays
    trafficAnalyticsInterval: trafficAnalyticsInterval
  }
}

module flowLogNsg2 'modules/flow-log.bicep' = {
  name:  'nsg-vm2-flowlog'
  scope: resourceGroup(networkWatcherRG)
  params: {
    location:                 location
    flowLogName:              'nsg-vm2-flowlog'
    targetNsgId:              nsgVm2.id
    storageAccountId:         storage.id
    workspaceResourceId:      workspace.id
    workspaceCustomerGuid:    workspace.properties.customerId
    workspaceRegion:          workspace.location
    retentionDays:            retentionDays
    trafficAnalyticsInterval: trafficAnalyticsInterval
  }
}

output storageAccountName string = storage.name
output storageAccountId   string = storage.id
