// =============================================================================
// Step 2 — Log Analytics + AMA pipeline
//
//   Data Collection Endpoint (DCE)
//         │  ingestion endpoint
//         ▼
//   Data Collection Rule (DCR)
//         │  defines WHAT (syslog, perf counters) and WHERE (Log Analytics)
//         ▼
//   Log Analytics workspace
//
//   AMA extension on each VM reads the DCR it's associated with and ships
//   data to the DCE, which forwards to the workspace per the DCR's dataFlows.
//
// Pipeline order matters: DCE before DCR (DCR references DCE), association
// before AMA can start working. Bicep enforces this via resource references.
//
// Requires 01-network.bicep to have been deployed first.
//
// Usage:
//   az deployment group create \
//     --resource-group $RG \
//     --template-file 02-monitoring.bicep \
//     --parameters @parameters/02-monitoring.json
// =============================================================================
targetScope = 'resourceGroup'

@description('Azure region.')
param location string = resourceGroup().location

@description('Log Analytics workspace name.')
param workspaceName string = 'netmon-workspace'

@description('Data Collection Endpoint name.')
param dceName string = 'netmon-dce'

@description('Data Collection Rule name.')
param dcrName string = 'netmon-dcr'

// ---------------------------------------------------------------------------
// Reference existing VMs from 01-network.bicep
// ---------------------------------------------------------------------------
resource vm1 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: 'vm1'
}

resource vm2 'Microsoft.Compute/virtualMachines@2023-09-01' existing = {
  name: 'vm2'
}

// ---------------------------------------------------------------------------
// Log Analytics workspace — the final destination for logs + Traffic Analytics
// ---------------------------------------------------------------------------
resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name:     workspaceName
  location: location
  properties: {
    sku:              { name: 'PerGB2018' }
    retentionInDays:  30
  }
}

// ---------------------------------------------------------------------------
// Data Collection Endpoint (DCE)
// The AMA uses this endpoint to ship telemetry. Must exist before the DCR
// that references it. If AMPLS (private link) is ever added, DCE is where
// it attaches.
// ---------------------------------------------------------------------------
resource dce 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name:     dceName
  location: location
  properties: {
    networkAcls: { publicNetworkAccess: 'Enabled' }
  }
}

// ---------------------------------------------------------------------------
// Data Collection Rule (DCR)
// Defines:
//   dataSources   — what to collect (syslog facilities, perf counters)
//   destinations  — where to send it (Log Analytics)
//   dataFlows     — which source streams go to which destinations
// ---------------------------------------------------------------------------
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name:     dcrName
  location: location
  properties: {
    dataCollectionEndpointId: dce.id
    dataSources: {
      syslog: [
        {
          name:          'syslogDataSource'
          streams:       [ 'Microsoft-Syslog' ]
          facilityNames: [ 'auth', 'authpriv', 'cron', 'daemon', 'kern', 'syslog', 'user' ]
          logLevels:     [ 'Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency' ]
        }
      ]
      performanceCounters: [
        {
          name:                       'perfCounterDataSource'
          streams:                    [ 'Microsoft-Perf' ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\Processor(*)\\% Processor Time'
            '\\Memory(*)\\% Used Memory'
            '\\LogicalDisk(*)\\% Free Space'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name:                'logAnalyticsDest'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams:      [ 'Microsoft-Syslog' ]
        destinations: [ 'logAnalyticsDest' ]
      }
      {
        streams:      [ 'Microsoft-Perf' ]
        destinations: [ 'logAnalyticsDest' ]
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Associate the DCR with each VM
// The AMA extension reads the DCR(s) associated with its host to know what
// to collect. One VM can have multiple DCR associations.
// ---------------------------------------------------------------------------
resource vm1DcrAssoc 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name:  'vm1-dcr-assoc'
  scope: vm1
  properties: {
    dataCollectionRuleId: dcr.id
  }
}

resource vm2DcrAssoc 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name:  'vm2-dcr-assoc'
  scope: vm2
  properties: {
    dataCollectionRuleId: dcr.id
  }
}

// ---------------------------------------------------------------------------
// Azure Monitor Agent (AMA) extension on each VM
// Installed AFTER the DCR association so the agent has something to read
// on first start.
// ---------------------------------------------------------------------------
resource vm1Ama 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent:   vm1
  name:     'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher:               'Microsoft.Azure.Monitor'
    type:                    'AzureMonitorLinuxAgent'
    typeHandlerVersion:      '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade:  true
  }
  dependsOn: [ vm1DcrAssoc ]
}

resource vm2Ama 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent:   vm2
  name:     'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher:               'Microsoft.Azure.Monitor'
    type:                    'AzureMonitorLinuxAgent'
    typeHandlerVersion:      '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade:  true
  }
  dependsOn: [ vm2DcrAssoc ]
}

output workspaceId   string = workspace.id
output workspaceName string = workspace.name
output dceId         string = dce.id
output dceName       string = dce.name
output dcrId         string = dcr.id
output dcrName       string = dcr.name
