// =============================================================================
// Azure Container Apps — Frontend + Backend over HTTPS
// Azure Well-Architected Framework: simple, secure, observable, cost-efficient
//
// Two-phase deployment:
//   Phase 1: deployApps=false  → creates ACR + environment (push images after)
//   Phase 2: deployApps=true   → creates both Container Apps
// =============================================================================
targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Short environment tag used in resource names (3–8 lowercase letters).')
@minLength(3)
@maxLength(8)
param environmentName string = 'demo'

@description('Image tag to deploy. Build and push your images with this tag before Phase 2.')
param imageTag string = 'latest'

@description('Set to true once your container images have been pushed to ACR. Phase 1 (false) creates infrastructure only; Phase 2 (true) adds the Container Apps.')
param deployApps bool = false

// ---------------------------------------------------------------------------
// Locals
// ---------------------------------------------------------------------------

// Deterministic token for globally-unique resource names
var resourceToken = toLower(uniqueString(subscription().id, resourceGroup().id, location))
var prefix        = '${environmentName}-${resourceToken}'

// ACR names are alphanumeric only (no hyphens), max 50 chars
var registryName  = toLower(replace('${environmentName}${resourceToken}', '-', ''))

// ---------------------------------------------------------------------------
// Phase 1 — Infrastructure (always deployed)
// ---------------------------------------------------------------------------

// 1. Azure Container Registry — stores the frontend and backend images
module registry 'modules/registry.bicep' = {
  name: 'container-registry'
  params: {
    name:     registryName
    location: location
  }
}

// 2. Shared Container Apps Environment (+ Log Analytics for observability)
module env 'modules/environment.bicep' = {
  name: 'container-apps-environment'
  params: {
    name:     '${prefix}-env'
    location: location
  }
}

// ---------------------------------------------------------------------------
// Phase 2 — Container Apps (only when deployApps=true)
// ---------------------------------------------------------------------------

// 3. Backend — internal ingress only (not reachable from the internet)
module backend 'modules/app.bicep' = if (deployApps) {
  name: 'backend-app'
  params: {
    name:              '${prefix}-backend'
    location:          location
    environmentId:     env.outputs.environmentId
    containerImage:    '${registry.outputs.loginServer}/backend:${imageTag}'
    isExternalIngress: false         // Security: backend is private
    targetPort:        3000
    registryServer:    registry.outputs.loginServer
    registryUsername:  registry.outputs.adminUsername
    registryPassword:  registry.outputs.adminPassword
    envVars:           []
  }
}

// 4. Frontend — external HTTPS ingress, proxies /api/* to the backend
module frontend 'modules/app.bicep' = if (deployApps) {
  name: 'frontend-app'
  params: {
    name:              '${prefix}-frontend'
    location:          location
    environmentId:     env.outputs.environmentId
    containerImage:    '${registry.outputs.loginServer}/frontend:${imageTag}'
    isExternalIngress: true          // Publicly reachable over HTTPS
    targetPort:        80
    registryServer:    registry.outputs.loginServer
    registryUsername:  registry.outputs.adminUsername
    registryPassword:  registry.outputs.adminPassword
    envVars: [
      {
        // Service discovery: apps in the same environment resolve each other by app name.
        // The frontend server.js proxies /api/* to this URL server-side.
        // The browser never contacts the backend directly.
        name:  'BACKEND_URL'
        value: 'http://${backend.outputs.appName}'
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('ACR login server — use this when running docker push.')
output registryLoginServer string = registry.outputs.loginServer

@description('Public HTTPS URL of the frontend web app (empty until Phase 2).')
output frontendUrl string = deployApps ? 'https://${frontend.outputs.fqdn}' : ''

@description('Internal URL the frontend uses to reach the backend (empty until Phase 2).')
output backendInternalUrl string = deployApps ? 'http://${backend.outputs.appName}' : ''
