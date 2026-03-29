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

## Pulling and running images on an Azure VM

### Install Docker on the VM

Docker is not pre-installed on Ubuntu Azure VMs. Install it and add your user to the `docker` group so you don't need `sudo` for every command:

```bash
# Install Docker
sudo apt update && sudo apt install -y docker.io

# Add your user to the docker group (avoids "permission denied" errors)
sudo usermod -aG docker $USER

# Apply the group change (or log out and back in)
newgrp docker

# Verify
docker ps
```

### Installing the azure cli

curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash


### Authenticate to ACR from the VM

There are three ways to authenticate. From most to least recommended:

#### Option 1 — Managed Identity (best for production)

Assign a **system-assigned managed identity** to the VM and grant it the `AcrPull` role. No passwords, no expiry, no secrets to manage.

```bash
# Enable managed identity on the VM (if not already)
az vm identity assign \
  --resource-group <vm-resource-group> \
  --name <vm-name>

# Get the VM's principal ID
PRINCIPAL_ID=$(az vm show \
  --resource-group <vm-resource-group> \
  --name <vm-name> \
  --query identity.principalId \
  --output tsv)

# Get the ACR resource ID
ACR_ID=$(az acr show --name <registry-name> --query id --output tsv)

# Grant AcrPull role
az role assignment create \
  --assignee $PRINCIPAL_ID \
  --role AcrPull \
  --scope $ACR_ID
```

Then on the VM:

```bash
# Login using the VM's managed identity
az login --identity
az acr login --name <registry-name>

# Pull and run
docker pull <registry>.azurecr.io/backend:latest
```

#### Option 2 — Azure CLI token (good for development)

If the Azure CLI is installed on the VM and you're logged in:

```bash
az login    # interactive login, or use --identity for managed identity
az acr login --name <registry-name>

# This creates a short-lived Docker credential (~3 hours)
docker pull <registry>.azurecr.io/backend:latest
```

#### Option 3 — Admin credentials (quick and dirty)

Uses the ACR admin username/password. Simple but the password is long-lived and shared — not recommended for production.

```bash
# Get the credentials
az acr credential show --name <registry-name>

# Login with username/password
docker login <registry>.azurecr.io \
  --username <admin-username> \
  --password <admin-password>

docker pull <registry>.azurecr.io/backend:latest
```

### Running the containers on the VM

Once authenticated and images are pulled, run them with Docker:

```bash
REGISTRY=<registry>.azurecr.io

# Start the backend (internal, port 3000)
docker run -d \
  --name backend \
  --restart unless-stopped \
  -p 3000:3000 \
  $REGISTRY/backend:latest

# Start the frontend (public, port 80)
# BACKEND_URL points to the backend container via the host network
docker run -d \
  --name frontend \
  --restart unless-stopped \
  -p 80:80 \
  -e BACKEND_URL=http://host.docker.internal:3000 \
  $REGISTRY/frontend:latest
```

Note: `host.docker.internal` may not work on Linux. Use the Docker bridge IP instead:

```bash
# Get the host IP on the Docker bridge network
DOCKER_HOST_IP=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')

docker run -d \
  --name frontend \
  --restart unless-stopped \
  -p 80:80 \
  -e BACKEND_URL=http://$DOCKER_HOST_IP:3000 \
  $REGISTRY/frontend:latest
```

Or simpler — use Docker's `--network host` mode:

```bash
# Backend on port 3000
docker run -d --name backend --restart unless-stopped --network host $REGISTRY/backend:latest

# Frontend on port 80, backend is on localhost:3000
docker run -d --name frontend --restart unless-stopped --network host \
  -e BACKEND_URL=http://localhost:3000 \
  $REGISTRY/frontend:latest
```

With `--network host`, both containers share the VM's network stack directly. The frontend reaches the backend on `localhost:3000`. This is the simplest approach for a single VM.

### Using Docker Compose on the VM

For a cleaner setup, install Docker Compose and use a compose file:

```bash
# Install the compose plugin
sudo apt install -y docker-compose-v2

# Create docker-compose.yml on the VM
cat > docker-compose.yml << 'COMPOSE'
services:
  backend:
    image: REGISTRY_PLACEHOLDER/backend:latest
    restart: unless-stopped

  frontend:
    image: REGISTRY_PLACEHOLDER/frontend:latest
    ports:
      - "80:80"
    environment:
      BACKEND_URL: "http://backend:3000"
    depends_on:
      - backend
COMPOSE

# Replace placeholder with your actual registry
sed -i "s|REGISTRY_PLACEHOLDER|$REGISTRY|g" docker-compose.yml

# Start both containers
docker compose up -d

# View logs
docker compose logs -f
```

Your docker compose might look something like this

```
services:
  backend:
    image: az104labvgyscrfmmz4du.azurecr.io/backend:latest
    restart: unless-stopped

  frontend:
    image: az104labvgyscrfmmz4du.azurecr.io/frontend:latest
    ports:
      - "80:80"
    environment:
      BACKEND_URL: "http://backend:3000"
    depends_on:
      - backend
```

### NSG rules for web traffic

If you want to access the frontend from a browser, make sure the VM's NSG allows HTTP/HTTPS:

```bash
az network nsg rule create \
  --resource-group <vm-resource-group> \
  --nsg-name <nsg-name> \
  --name AllowHTTP \
  --priority 1010 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-range 80

az network nsg rule create \
  --resource-group <vm-resource-group> \
  --nsg-name <nsg-name> \
  --name AllowHTTPS \
  --priority 1020 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-range 443
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
