// =============================================================================
// Module — single NSG flow log (deployed in NetworkWatcherRG).
// Called by 03-flow-logs.bicep via `scope: resourceGroup('NetworkWatcherRG')`.
// =============================================================================
targetScope = 'resourceGroup'

param location string
param flowLogName string
param targetNsgId string
param storageAccountId string
param workspaceResourceId string
param workspaceCustomerGuid string
param workspaceRegion string
param retentionDays int = 7
param trafficAnalyticsInterval int = 10

// Azure auto-creates one Network Watcher per region in NetworkWatcherRG.
// The naming convention is `NetworkWatcher_<region>` (e.g. NetworkWatcher_westeurope).
resource networkWatcher 'Microsoft.Network/networkWatchers@2023-09-01' existing = {
  name: 'NetworkWatcher_${location}'
}

resource flowLog 'Microsoft.Network/networkWatchers/flowLogs@2023-09-01' = {
  parent:   networkWatcher
  name:     flowLogName
  location: location
  properties: {
    targetResourceId: targetNsgId
    storageId:        storageAccountId
    enabled:          true
    format: {
      type:    'JSON'
      version: 2
    }
    retentionPolicy: {
      days:    retentionDays
      enabled: true
    }
    flowAnalyticsConfiguration: {
      networkWatcherFlowAnalyticsConfiguration: {
        enabled:                  true
        workspaceResourceId:      workspaceResourceId
        workspaceId:              workspaceCustomerGuid
        workspaceRegion:          workspaceRegion
        trafficAnalyticsInterval: trafficAnalyticsInterval
      }
    }
  }
}

output flowLogId string = flowLog.id
