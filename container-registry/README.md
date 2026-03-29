# Azure Container Registry

A standalone project for creating an Azure Container Registry and pushing container images to it. Includes a sample frontend and backend app to build and push.

## What gets deployed

| Resource | Spec | Purpose |
|---|---|---|
| Azure Container Registry | Basic SKU | Stores Docker images |

## Estimated cost

~$5/month for Basic tier. Storage: first 10 GiB included.

## Project structure

```
container-registry/
├── main.bicep               # Creates the ACR
├── parameters/
│   └── main.bicepparam      # Registry name and SKU
├── backend/
│   ├── server.js            # Sample Node.js API
│   └── Dockerfile
└── frontend/
    ├── server.js            # Sample Node.js web server
    ├── index.html           # Single-page app
    └── Dockerfile
```

## Deploy the registry

```bash
az group create --name rg-acr-demo --location westeurope

az deployment group create \
  --resource-group rg-acr-demo \
  --template-file main.bicep \
  --parameters parameters/main.bicepparam

# Get the login server
REGISTRY=$(az deployment group show \
  --resource-group rg-acr-demo \
  --name main \
  --query "properties.outputs.loginServer.value" \
  --output tsv)

echo $REGISTRY
```

## Build and push images

### Option A — Build in Azure (recommended)

No local Docker needed. ACR builds the images on its own amd64 agents.

```bash
az acr build --registry ${REGISTRY%%.*} --image backend:latest  ./backend
az acr build --registry ${REGISTRY%%.*} --image frontend:latest ./frontend
```

### Option B — Build locally with Docker

On Apple Silicon, pass `--platform linux/amd64`.

```bash
az acr login --name ${REGISTRY%%.*}

docker build --platform linux/amd64 -t $REGISTRY/backend:latest  ./backend
docker push $REGISTRY/backend:latest

docker build --platform linux/amd64 -t $REGISTRY/frontend:latest ./frontend
docker push $REGISTRY/frontend:latest
```

## Verify images in the registry

```bash
# List repositories
az acr repository list --name ${REGISTRY%%.*} --output table

# Show tags for a specific image
az acr repository show-tags --name ${REGISTRY%%.*} --repository backend --output table
az acr repository show-tags --name ${REGISTRY%%.*} --repository frontend --output table
```

## Inspect an image

```bash
# Show manifest and digest
az acr repository show --name ${REGISTRY%%.*} --image backend:latest --output table

# Show detailed manifest (layers, size, architecture)
az acr manifest show --registry ${REGISTRY%%.*} --name backend:latest
```

## Delete an image

```bash
az acr repository delete --name ${REGISTRY%%.*} --image backend:latest --yes
```

## ACR SKU comparison

| Feature | Basic | Standard | Premium |
|---|---|---|---|
| Price/month | ~$5 | ~$20 | ~$50 |
| Storage included | 10 GiB | 100 GiB | 500 GiB |
| Geo-replication | No | No | Yes |
| Private link | No | No | Yes |
| Webhooks | 2 | 10 | 500 |

Basic is sufficient for development and learning. Use Standard or Premium for production workloads.

## Tear down

```bash
az group delete --name rg-acr-demo --yes
```
