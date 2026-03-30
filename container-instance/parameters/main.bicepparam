using '../main.bicep'

param location         = 'westeurope'
param containerGroupName = 'backend-aci'

// Replace with your ACR login server and image reference
// e.g. myregistry.azurecr.io/backend:latest
param containerImage   = '<registryName>.azurecr.io/backend:latest'
param registryServer   = '<registryName>.azurecr.io'
param registryUsername = '<registryName>'

// Pass registryPassword at deploy time — do NOT commit secrets here:
//   --parameters registryPassword='...'
