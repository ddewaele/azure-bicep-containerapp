using '../main.bicep'

param location      = 'westeurope'
param adminUsername = 'azureuser'
param vmSize        = 'Standard_B1s'

// Paste your SSH public key here
param sshPublicKey  = '<paste-your-ssh-public-key-here>'
