// =============================================================================
// Module: Azure Container Registry (ACR)
//
// Provisions a Basic-tier registry with admin credentials enabled.
// The admin password is returned as a @secure() output so Bicep never
// logs or surfaces it in plain text.
//
// Note: admin credentials are appropriate for a demo. For production,
// use a managed identity with the AcrPull role instead.
// =============================================================================

@description('Globally unique registry name (alphanumeric, 5–50 chars).')
param name string

@description('Azure region.')
param location string

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  sku: {
    name: 'Basic'   // Cost Optimization: cheapest tier sufficient for a demo
  }
  properties: {
    adminUserEnabled: true
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Login server hostname, e.g. myregistry.azurecr.io')
output loginServer string = registry.properties.loginServer

@description('Admin username for registry authentication.')
#disable-next-line outputs-should-not-contain-secrets // credentials are passed to Container App secrets, never logged
output adminUsername string = registry.listCredentials().username

@description('Admin password for registry authentication.')
#disable-next-line outputs-should-not-contain-secrets // passed as @secure() and stored as Container App secret
@secure()
output adminPassword string = registry.listCredentials().passwords[0].value
