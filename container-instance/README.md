# Azure Container Instance

Deploys a single container directly via **Azure Container Instance (ACI)** — no orchestrator, no environment, just a container with a public IP.

This example reuses the backend API from the [container-apps](../container-apps/) project. Push the image to ACR once, then deploy it anywhere.

## Architecture

```
Internet
   │
   ▼  port 3000 (TCP)
┌─────────────────────────┐
│  Container Group (ACI)  │
│  ┌───────────────────┐  │
│  │  backend container│  │
│  │  /api/message     │  │
│  └───────────────────┘  │
│  Public IP              │
└─────────────────────────┘
```

## Prerequisites

1. The backend image built and pushed to ACR:
   ```bash
   az acr build \
     --registry <registryName> \
     --image backend:latest \
     container-apps/backend/
   ```

2. ACR admin credentials enabled:
   ```bash
   az acr update --name <registryName> --admin-enabled true
   ```

## Deploy

This project depends on the ../container-registry project for the ACR deployment. Make sure to deploy that first and note the registry name and admin password. (or use the commands below to retrieve them from the deployment outputs)

```bash
# Create resource group
az group create --name rg-container-instance --location westeurope

REGISTRY_NAME=$(az deployment group show \
  --resource-group rg-acr-demo \
  --name main \
  --query "properties.outputs.registryName.value" \
  --output tsv)

# Get ACR admin password
ACR_PASSWORD=$(az acr credential show --name $REGISTRY_NAME --query "passwords[0].value" -o tsv)

# Deploy
az deployment group create \
  --resource-group rg-container-instance \
  --template-file main.bicep \
  --parameters parameters/main.bicepparam \
  --parameters registryPassword="$ACR_PASSWORD"
```

## Test

```bash
# Get public IP
IP=$(az container show \
  --resource-group rg-container-instance \
  --name backend-aci \
  --query ipAddress.ip -o tsv)

# Call the API
curl http://$IP:3000/api/message
```

Expected response:
```json
{
  "message": "Hello from the backend API!",
  "hostname": "...",
  "timestamp": "..."
}
```

## View logs

```bash
az container logs \
  --resource-group rg-container-instance \
  --name backend-aci
```

## ACI vs Container Apps

| | ACI | Container Apps |
|---|---|---|
| Use case | Single container, quick deploys | Long-running apps, scale-to-zero |
| Ingress | Raw IP + port | HTTPS with custom domain |
| Scaling | Manual (redeploy) | Automatic (HTTP / event-driven) |
| Cost | Per second (CPU + memory) | Per request (Consumption plan) |
| Orchestration | None | Built-in (Dapr, KEDA) |

## Clean up

```bash
az group delete --name rg-container-instance --yes
```
