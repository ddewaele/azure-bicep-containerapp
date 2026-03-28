// =============================================================================
// Module: Container Apps Environment
//
// Provisions:
//   - Log Analytics Workspace  (Operational Excellence — centralised logs)
//   - Container Apps Environment  (shared network plane for all apps)
// =============================================================================

@description('Name for the Container Apps Environment (and Log Analytics prefix).')
param name string

@description('Azure region.')
param location string

// ---------------------------------------------------------------------------
// Log Analytics Workspace
// Well-Architected / Operational Excellence: structured logs, 30-day retention
// ---------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${name}-logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'   // Pay-per-use — Cost Optimization
    }
    retentionInDays: 30
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Container Apps Managed Environment
// ---------------------------------------------------------------------------
resource containerAppsEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: name
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        // listKeys() is resolved at deploy time — the key is never stored in the template
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    // Consumption workload profile — scale to zero is supported out of the box
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Resource ID of the Container Apps Environment.')
output environmentId string = containerAppsEnv.id

@description('Default domain used to build FQDNs for apps in this environment.')
output defaultDomain string = containerAppsEnv.properties.defaultDomain
