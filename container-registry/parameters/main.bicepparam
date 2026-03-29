using '../main.bicep'

param location     = 'westeurope'
param registryName = 'az104lab${uniqueString('ecr')}'  // must be globally unique, alphanumeric only
param sku          = 'Basic'
