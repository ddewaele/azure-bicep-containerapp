#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Build both container images in Azure and push them to ACR.
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - REGISTRY environment variable set to the ACR login server, e.g.:
#
#       export REGISTRY=az104labvgyscrfmmz4du.azurecr.io
#
#     You can get this from the deployment output:
#
#       export REGISTRY=$(az deployment group show \
#         --resource-group rg-acr-demo \
#         --name main \
#         --query "properties.outputs.loginServer.value" \
#         --output tsv)
# =============================================================================

if [ -z "${REGISTRY:-}" ]; then
  echo "Error: REGISTRY is not set."
  echo ""
  echo "Set it to your ACR login server, e.g.:"
  echo ""
  echo "  export REGISTRY=az104labvgyscrfmmz4du.azurecr.io"
  echo ""
  echo "Or get it from your deployment:"
  echo ""
  echo "  export REGISTRY=\$(az deployment group show \\"
  echo "    --resource-group rg-acr-demo \\"
  echo "    --name main \\"
  echo "    --query \"properties.outputs.loginServer.value\" \\"
  echo "    --output tsv)"
  exit 1
fi

# Strip .azurecr.io to get the registry name (az acr build expects the name, not the FQDN)
REGISTRY_NAME="${REGISTRY%%.*}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Building backend image in Azure..."
az acr build \
  --registry "$REGISTRY_NAME" \
  --image backend:latest \
  "$SCRIPT_DIR/backend"

echo ""
echo "==> Building frontend image in Azure..."
az acr build \
  --registry "$REGISTRY_NAME" \
  --image frontend:latest \
  "$SCRIPT_DIR/frontend"

echo ""
echo "==> Done. Images in $REGISTRY:"
az acr repository list --name "$REGISTRY_NAME" --output table
