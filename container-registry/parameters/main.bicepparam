using '../main.bicep'

param location     = 'westeurope'
param registryName = 'az104labddw${uniqueString('ecr')}'  // must be globally unique, alphanumeric only
param sku          = 'Basic'
