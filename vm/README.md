# Cheapest Azure Linux VM

A single Bicep template that deploys the most cost-effective Linux VM possible on Azure.

## What gets deployed

| Resource | Spec | Purpose |
|---|---|---|
| Virtual Network | 10.0.0.0/24 | Private network for the VM |
| Network Security Group | SSH (port 22) only | Firewall |
| Public IP | Standard SKU, static | SSH access |
| Network Interface | — | Connects VM to VNet + public IP |
| Virtual Machine | **Standard_B1s** — 1 vCPU, 1 GiB RAM | The VM itself |
| OS Disk | 30 GB Standard HDD (Standard_LRS) | Cheapest storage |

**OS:** Ubuntu 24.04 LTS
**Auth:** SSH key only (no password)
**Identity:** System-assigned managed identity (Azure's equivalent of an AWS instance profile)

## Estimated cost

| Resource | Monthly cost |
|---|---|
| Standard_B1s VM (1 vCPU, 1 GiB) | ~$3.80 |
| OS Disk — 30 GB Standard HDD | ~$1.20 |
| Public IP — Standard SKU (static) | ~$3.65 |
| **Total** | **~$8.65** |

Note: Basic SKU public IPs were free but are being retired by Azure. Standard SKU is now required.

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


## Managed identity

The VM is deployed with a **system-assigned managed identity**. This is Azure's equivalent of an AWS instance profile — it lets the VM authenticate to Azure services without passwords or tokens.

### How it works

When the VM is created with `identity: { type: 'SystemAssigned' }`, Azure:
1. Creates a service principal (identity) tied to the VM's lifecycle
2. Makes a token available via the Instance Metadata Service (`169.254.169.254`)
3. The Azure CLI reads this token when you run `az login --identity`

When the VM is deleted, the identity is automatically cleaned up.

### Using it on the VM

```bash
# Authenticate using the managed identity (no password, no browser)
az login --identity

# Verify
az account show
```

### Granting access to Azure services

The identity has no permissions by default. Assign roles to grant access:

```bash
# Get the VM's principal ID from the deployment output
PRINCIPAL_ID=$(az deployment group show \
  --resource-group rg-cheapvm \
  --name main \
  --query "properties.outputs.principalId.value" \
  --output tsv)

# Example: grant pull access to an Azure Container Registry
ACR_ID=$(az acr show --name <registry-name> --query id --output tsv)
az role assignment create --assignee $PRINCIPAL_ID --role AcrPull --scope $ACR_ID

# Example: grant read access to an entire resource group
RG_ID=$(az group show --name <rg-name> --query id --output tsv)
az role assignment create --assignee $PRINCIPAL_ID --role Reader --scope $RG_ID
```

Then on the VM, after `az login --identity`, commands like `az acr login` or `az resource list` work according to the assigned roles.

### AWS vs Azure comparison

| Concept | AWS | Azure |
|---|---|---|
| Identity attached to a VM | Instance Profile + IAM Role | System-assigned Managed Identity |
| Token endpoint | `169.254.169.254` (IMDSv2) | `169.254.169.254` (IMDS) |
| CLI auto-detects? | Yes — `aws` CLI works immediately | No — run `az login --identity` once per session |
| Permissions | IAM policies on the role | RBAC role assignments on the identity |
| Lifecycle | Detached from instance independently | Deleted when VM is deleted |

## Useful commands

```bash
# Show public IPs in your subscription
az network public-ip list \
  --query "[].{name:name, sku:sku.name, ip:ipAddress, rg:resourceGroup, location:location}" \
  --output table
```

## Tear down

```bash
az group delete --name rg-cheapvm --yes
```

## Troubleshooting SSH lockout

If you get locked out of SSH, it's likely fail2ban or ufw rate limiting banning your IP after failed login attempts.

### What happened to us

1. Changed sshd to port 2222, added a rate-limited ufw rule (`ufw limit 2222/tcp`)
2. Installed fail2ban with `maxretry=3`, `findtime=10m`, `bantime=1h`
3. Clicked "Check access" in the Azure Portal Connect screen — this triggered SSH attempts as `azureuser`
4. sshd rejected `azureuser` (not in `AllowUsers`), but the connection attempts still counted
5. fail2ban saw 3+ failures within 10 minutes and banned our IP for 1 hour
6. ufw rate limiting also kicked in independently (6 attempts in 30 seconds)
7. Legitimate `deploy` SSH sessions were blocked — same source IP

### Diagnostics

```bash
# Check if you're banned by fail2ban
fail2ban-client status sshd

# Check ufw rules (look for REJECT rules with your IP)
ufw status numbered

# Check iptables directly (fail2ban sometimes bypasses ufw)
iptables -L -n | grep <your-ip>

# Check sshd logs for recent failures
journalctl -u ssh --since "30 min ago" | grep -i "fail\|reject\|not allowed"
```

### Recovery (from your local machine, when locked out)

```bash
# Unban your IP via fail2ban (also clears its iptables/ufw rules)
az vm run-command invoke \
  --resource-group rg-cheapvm \
  --name cheapvm-vm \
  --command-id RunShellScript \
  --scripts "fail2ban-client set sshd unbanip <YOUR_IP_ADDRESS>"

# If a stale ufw reject rule remains
az vm run-command invoke \
  --resource-group rg-cheapvm \
  --name cheapvm-vm \
  --command-id RunShellScript \
  --scripts "ufw delete reject from <YOUR_IP_ADDRESS>"
```

### Prevention

```bash
# Whitelist your IP so fail2ban never bans it
# In /etc/fail2ban/jail.local:
ignoreip = 127.0.0.1/8 ::1 <YOUR_IP_ADDRESS>

# Switch ufw from rate-limited to plain allow (fail2ban handles rate limiting better)
ufw delete limit 2222/tcp
ufw allow 2222/tcp

# Don't click "Check access" in the Azure Portal — it probes as azureuser
```
