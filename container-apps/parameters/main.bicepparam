// Bicep parameters file for the demo deployment.
//
// Two-phase deployment:
//   Phase 1: deployApps=false → creates ACR + Container Apps Environment
//   Phase 2: deployApps=true  → creates both Container Apps (after images are in ACR)

using '../main.bicep'

param environmentName = 'demo'
param imageTag        = 'latest'

// Set to true after building and pushing images to ACR.
param deployApps = false
