// =============================================================================
// Azure Container Registry — standalone project
//
// Creates a Basic-tier ACR for storing container images.
// After deployment, build and push images using the Azure CLI or Docker.
// =============================================================================
targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Azure region for the registry.')
param location string = resourceGroup().location

@description('Globally unique registry name (alphanumeric, 5–50 chars). Must be unique across all of Azure.')
@minLength(5)
@maxLength(50)
param registryName string

@description('ACR SKU tier. Basic is cheapest (~$5/month).')
@allowed([ 'Basic', 'Standard', 'Premium' ])
param sku string = 'Basic'

// ---------------------------------------------------------------------------
// Container Registry
// ---------------------------------------------------------------------------
resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: registryName
  location: location
  sku: {
    name: sku
  }
  properties: {
    adminUserEnabled: true   // enables username/password auth for docker push
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('ACR login server, e.g. myregistry.azurecr.io')
output loginServer string = registry.properties.loginServer

@description('Registry name (use with az acr commands).')
output registryName string = registry.name
