using '../01-vnets.bicep'

param location      = 'westeurope'
param adminUsername = 'azureuser'
param vmSize        = 'Standard_B2ats_v2'

// Paste your SSH public key here
param sshPublicKey  = '<paste-your-ssh-public-key-here>'
