# Cheapest Azure Linux VM

A single Bicep template that deploys the most cost-effective Linux VM possible on Azure.

## What gets deployed

| Resource | Spec | Purpose |
|---|---|---|
| Virtual Network | 10.0.0.0/24 | Private network for the VM |
| Network Security Group | SSH (port 22) only | Firewall |
| Public IP | Basic SKU, dynamic | SSH access |
| Network Interface | — | Connects VM to VNet + public IP |
| Virtual Machine | **Standard_B1s** — 1 vCPU, 1 GiB RAM | The VM itself |
| OS Disk | 30 GB Standard HDD (Standard_LRS) | Cheapest storage |

**OS:** Ubuntu 24.04 LTS
**Auth:** SSH key only (no password)

## Estimated cost

~$3.80/month for the B1s VM + ~$1.20/month for 30 GB Standard HDD = **~$5/month**.

## Deploy

```bash
# Create resource group
az group create --name rg-cheapvm --location westeurope

# Deploy (pass your SSH public key)
az deployment group create \
  --resource-group rg-cheapvm \
  --template-file main.bicep \
  --parameters parameters/main.bicepparam \
  --parameters sshPublicKey="$(cat ~/.ssh/azure-cheap-vm/ed25519.pub)"
```

## Connect

```bash
# Get the SSH command from the deployment output
az deployment group show \
  --resource-group rg-cheapvm \
  --name main \
  --query "properties.outputs.sshCommand.value" \
  --output tsv

# Or connect directly
ssh azureuser@$(az deployment group show \
  --resource-group rg-cheapvm \
  --name main \
  --query "properties.outputs.fqdn.value" \
  --output tsv)
```

## Tear down

```bash
az group delete --name rg-cheapvm --yes
```
