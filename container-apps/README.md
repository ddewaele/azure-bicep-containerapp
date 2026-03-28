# Azure Bicep — Container Apps Demo

A minimal Bicep template that deploys a **frontend SPA** and a **backend API** as linked Azure Container Apps over HTTPS, following the [Azure Well-Architected Framework](https://learn.microsoft.com/en-us/azure/well-architected/).

## Architecture

```
Browser
  │  HTTPS (TLS managed by Azure)
  ▼
┌──────────────────────────────────────────────┐
│         Container Apps Environment            │
│                                              │
│  ┌────────────────────────────────────┐      │
│  │  Frontend  (public, port 80)       │      │
│  │  Serves SPA + proxies /api/* ──────┼──►  │
│  └────────────────────────────────────┘      │
│              ┌──────────────────────────┐     │
│              │  Backend  (internal-only) │     │
│              │  GET /api/message → JSON  │◄────│
│              └──────────────────────────┘     │
│                                              │
│  + Log Analytics · Azure Container Registry  │
└──────────────────────────────────────────────┘
```

The backend has **no public endpoint** — only the frontend can reach it via the private network. See [docs/networking.md](docs/networking.md) for a layer-by-layer explanation.

## Project structure

```
AzureBiceps/
├── main.bicep                   # Entry point — parameters and module wiring
├── modules/
│   ├── registry.bicep           # Azure Container Registry
│   ├── environment.bicep        # Log Analytics + Container Apps Environment
│   └── app.bicep                # Reusable Container App module
├── backend/
│   ├── server.js                # Minimal Node.js API (zero dependencies)
│   └── Dockerfile
├── frontend/
│   ├── index.html               # Single-page app (vanilla JS)
│   ├── server.js                # Serves SPA + reverse-proxies /api/*
│   └── Dockerfile
├── parameters/
│   └── main.bicepparam          # Deployment parameters
├── docker-compose.yml           # Run locally before deploying
└── docs/
    ├── networking.md            # How frontend↔backend networking works
    └── logging.md               # Structured logging + KQL queries
```

## Prerequisites

| Tool | Version |
|---|---|
| Azure CLI | >= 2.61 |
| Bicep CLI | >= 0.28 (`az bicep install`) |
| Docker | any recent |

## Run locally

```bash
docker compose up --build
open http://localhost:8080
```

## Deploy to Azure

Deployment has two phases: infrastructure first, then apps (after images are pushed to ACR).

### Phase 1 — Infrastructure

```bash
az login

az group create --name rg-biceps-demo --location westeurope

# Creates ACR + Log Analytics + Container Apps Environment
az deployment group create \
  --resource-group rg-biceps-demo \
  --template-file main.bicep \
  --parameters parameters/main.bicepparam

# Capture the ACR login server for the next step
REGISTRY=$(az deployment group show \
  --resource-group rg-biceps-demo \
  --name main \
  --query "properties.outputs.registryLoginServer.value" \
  --output tsv)
```

### Phase 2 — Build, push, deploy apps

#### Option A — Build locally with Docker

On Apple Silicon, you **must** pass `--platform linux/amd64`.

```bash
az acr login --name ${REGISTRY%%.*}

docker build --platform linux/amd64 -t $REGISTRY/backend:latest  ./backend
docker push $REGISTRY/backend:latest

docker build --platform linux/amd64 -t $REGISTRY/frontend:latest ./frontend
docker push $REGISTRY/frontend:latest
```

#### Option B — Build in Azure (no local Docker needed)

```bash
az acr build --registry ${REGISTRY%%.*} --image backend:latest  ./backend
az acr build --registry ${REGISTRY%%.*} --image frontend:latest ./frontend
```

#### Deploy the apps

```bash
az deployment group create \
  --resource-group rg-biceps-demo \
  --template-file main.bicep \
  --parameters parameters/main.bicepparam \
  --parameters deployApps=true
```

### Get the frontend URL

```bash
az deployment group show \
  --resource-group rg-biceps-demo \
  --name main \
  --query "properties.outputs.frontendUrl.value" \
  --output tsv
```

## Update after a code change

```bash
# Rebuild and push
docker build --platform linux/amd64 -t $REGISTRY/backend:latest  ./backend  && docker push $REGISTRY/backend:latest
docker build --platform linux/amd64 -t $REGISTRY/frontend:latest ./frontend && docker push $REGISTRY/frontend:latest

# Redeploy (creates a new revision that pulls the updated images)
az deployment group create \
  --resource-group rg-biceps-demo \
  --template-file main.bicep \
  --parameters parameters/main.bicepparam \
  --parameters deployApps=true
```

For CI/CD, use a unique image tag per build:

```bash
az deployment group create \
  --resource-group rg-biceps-demo \
  --template-file main.bicep \
  --parameters parameters/main.bicepparam \
  --parameters deployApps=true imageTag=$(git rev-parse --short HEAD)
```

## Verify the backend is private

```bash
az containerapp list \
  --resource-group rg-biceps-demo \
  --query "[].{name:name, external:properties.configuration.ingress.external}" \
  --output table
```

The backend should show `External: False`.

## Tear down

```bash
az group delete --name rg-biceps-demo --yes
```

Removes all resources and stops all charges.

## Well-Architected Framework

| Pillar | Decision |
|---|---|
| **Reliability** | Min 1 replica; HTTP-based auto-scaling |
| **Security** | Backend internal-only; HTTPS enforced; registry password stored as Container App secret |
| **Cost Optimization** | Basic ACR; Consumption workload profile; 0.25 vCPU / 0.5 GiB |
| **Operational Excellence** | Structured JSON logging to Log Analytics; modular Bicep |
| **Performance Efficiency** | HTTP/2 via `transport: auto`; concurrency-based scaling |

## Learn more

- [Networking deep-dive](docs/networking.md) — how the frontend reaches the private backend, internal DNS, the proxy pattern
- [Logging](docs/logging.md) — structured log format, live streaming, KQL queries for Log Analytics
