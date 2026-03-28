using '../main.bicep'

param location      = 'westeurope'
param prefix        = 'cheapvm'
param adminUsername = 'azureuser'
param vmSize        = 'Standard_B1s'

// Paste your SSH public key here (contents of ~/.ssh/id_ed25519.pub or ~/.ssh/id_rsa.pub)
param sshPublicKey  = '<paste-your-ssh-public-key-here>'
