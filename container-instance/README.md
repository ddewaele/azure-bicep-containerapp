# Azure Container Instance

Deploys a single container directly via **Azure Container Instance (ACI)** — no orchestrator, no environment, just a container with a public IP.

This project builds up incrementally — each Bicep file adds a new capability on top of the base deployment.

## Architecture progression

| File | What it adds |
|---|---|
| `01-simple-aci.bicep` | Base deployment — public IP, raw port |
| `02-dns.bicep` | DNS name label — FQDN instead of bare IP |
| `03-vnet.bicep` | VNet integration — private subnet, no public IP |
| `04-appgw.bicep` | Application Gateway — public HTTP on port 80, ACI private |
| `05-fileshare.bicep` | Azure Files volume mount — read files from the container |

## Prerequisites

1. **ACR registry** deployed and admin credentials enabled — see the [container-registry](../container-registry/) project.

2. **Backend image** built and pushed:
   ```bash
   # For 01-simple-aci / 02-dns / 03-vnet / 04-appgw (original backend):
   az acr build \
     --registry $REGISTRY_NAME \
     --image backend:latest \
     container-apps/backend/

   # For 05-fileshare (extended backend with /api/files route):
   az acr build \
     --registry $REGISTRY_NAME \
     --image backend:latest \
     container-instance/backend/
   ```

## Common setup

```bash
# Create resource group (shared across all steps)
az group create --name rg-container-instance --location westeurope

# Retrieve registry name and password from container-registry deployment
REGISTRY_NAME=$(az deployment group show \
  --resource-group rg-acr-demo \
  --name main \
  --query "properties.outputs.registryName.value" \
  --output tsv)

ACR_PASSWORD=$(az acr credential show \
  --name $REGISTRY_NAME \
  --query "passwords[0].value" -o tsv)
```

`registryName` is passed via CLI for all steps — no need to edit any param file.

---

## Step 1 — Base deployment (`01-simple-aci.bicep`)

Public IP, raw port. The simplest possible ACI deployment.

```bash
az deployment group create \
  --resource-group rg-container-instance \
  --template-file 01-simple-aci.bicep \
  --parameters @parameters/01-simple-aci.json \
  --parameters registryName="$REGISTRY_NAME" \
  --parameters registryPassword="$ACR_PASSWORD"
```

```bash
IP=$(az container show -g rg-container-instance -n backend-aci \
  --query ipAddress.ip -o tsv)
curl http://$IP:3000/api/message
```

---

## Step 2 — DNS name label (`02-dns.bicep`)

Assigns a stable hostname: `<label>.westeurope.azurecontainer.io`

```bash
az deployment group create \
  --resource-group rg-container-instance \
  --template-file 02-dns.bicep \
  --parameters @parameters/02-dns.json \
  --parameters registryName="$REGISTRY_NAME" \
  --parameters registryPassword="$ACR_PASSWORD"
```

```bash
FQDN=$(az container show -g rg-container-instance -n backend-aci-dns \
  --query ipAddress.fqdn -o tsv)
curl http://$FQDN:3000/api/message
```

---

## Step 3 — VNet integration (`03-vnet.bicep`)

Deploys ACI into a private subnet alongside a **jump VM** and **Azure Bastion (Developer SKU, free)**. No public IPs anywhere — Bastion provides browser-based SSH access to the VM, from which you can curl the ACI.

```
Internet
   │  (Bastion browser SSH)
   ▼
┌──────────────────────────────────────────┐
│  VNet 10.0.0.0/16                        │
│                                          │
│  aci-subnet 10.0.1.0/24                  │
│  ┌──────────────────────┐                │
│  │  backend-aci (ACI)   │ ← private IP   │
│  └──────────────────────┘                │
│                                          │
│  vm-subnet 10.0.2.0/24                   │
│  ┌──────────────────────┐                │
│  │  jump-vm             │ ← private IP   │
│  └──────────────────────┘                │
└──────────────────────────────────────────┘
```

```bash
az deployment group create \
  --resource-group rg-container-instance \
  --template-file 03-vnet.bicep \
  --parameters @parameters/03-vnet.json \
  --parameters registryName="$REGISTRY_NAME" \
  --parameters registryPassword="$ACR_PASSWORD" \
  --parameters sshPublicKey="$(cat ~/.ssh/id_rsa.pub)"
```

Connect and test:
1. Azure Portal → `jump-vm` → **Connect → Bastion**
2. Log in as `azureuser` with your SSH private key
3. From inside the VM:

```bash
# Get ACI private IP from deployment output
ACI_IP=$(az deployment group show \
  -g rg-container-instance -n 03-vnet \
  --query properties.outputs.aciPrivateIp.value -o tsv)

curl http://$ACI_IP:3000/api/message
```

> **Note**: Bastion Developer SKU is browser-based only. `az network bastion ssh` (native client) requires Standard SKU.

---

## Step 4 — Application Gateway (`04-appgw.bicep`)

Puts an Application Gateway Standard_v2 in front of ACI. Traffic enters on port 80 via public IP and is forwarded to the container's private IP on port 3000.

> **Cost note**: App GW Standard_v2 costs ~$0.008/hr plus capacity units. Delete the resource group when done.

```bash
az deployment group create \
  --resource-group rg-container-instance \
  --template-file 04-appgw.bicep \
  --parameters @parameters/04-appgw.json \
  --parameters registryName="$REGISTRY_NAME" \
  --parameters registryPassword="$ACR_PASSWORD"
```

```bash
APP_GW_IP=$(az deployment group show \
  -g rg-container-instance -n 04-appgw \
  --query properties.outputs.appGwPublicIp.value -o tsv)

# Port 80 via App GW — no port number needed
curl http://$APP_GW_IP/api/message
```

---

## Step 5 — Azure Files volume mount (`05-fileshare.bicep`)

Creates an Azure Storage Account + File Share, mounts it into the container at `/mnt/data`.

The backend in `backend/server.js` adds two new routes:

| Route | Description |
|---|---|
| `GET /api/files` | Lists all files in the mounted share |
| `GET /api/file?name=<filename>` | Returns the content of a single file |

Build and push the updated backend image first:
```bash
az acr build \
  --registry $REGISTRY_NAME \
  --image backend:latest \
  container-instance/backend/
```

Deploy:
```bash
az deployment group create \
  --resource-group rg-container-instance \
  --template-file 05-fileshare.bicep \
  --parameters @parameters/05-fileshare.json \
  --parameters registryName="$REGISTRY_NAME" \
  --parameters registryPassword="$ACR_PASSWORD"
```

Upload a test file and read it back:
```bash
STORAGE_NAME=$(az deployment group show \
  -g rg-container-instance -n 05-fileshare \
  --query properties.outputs.storageAccountName.value -o tsv)

STORAGE_KEY=$(az storage account keys list \
  --account-name $STORAGE_NAME --query "[0].value" -o tsv)

# Upload a file to the share
echo "Hello from Azure Files!" > hello.txt
az storage file upload \
  --account-name $STORAGE_NAME \
  --share-name aci-share \
  --source hello.txt \
  --account-key $STORAGE_KEY

# List files via the API
IP=$(az container show -g rg-container-instance -n backend-aci-files \
  --query ipAddress.ip -o tsv)
curl http://$IP:3000/api/files
curl http://$IP:3000/api/file?name=hello.txt
```

---

## View logs (any step)

```bash
az container logs \
  --resource-group rg-container-instance \
  --name <container-group-name>
```

---

## ACI vs Container Apps

| | ACI | Container Apps |
|---|---|---|
| Use case | Single container, quick deploys | Long-running apps, scale-to-zero |
| Ingress | Raw IP + port (or via App GW) | HTTPS with custom domain |
| Scaling | Manual (redeploy) | Automatic (HTTP / event-driven) |
| Cost | Per second (CPU + memory) | Per request (Consumption plan) |
| Orchestration | None | Built-in (Dapr, KEDA) |

---

## Clean up

```bash
az group delete --name rg-container-instance --yes
```
