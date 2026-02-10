#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Deploy the rag-chat Prompt Flow to an Azure ML managed online endpoint.
#
# Usage:
#   ./scripts/deploy-promptflow.sh \
#     --resource-group <rg-name> \
#     --workspace-name <ws-name> \
#     --endpoint-name <endpoint-name>
#
# Optional environment variables:
#   AZURE_SEARCH_ENDPOINT       - Azure AI Search endpoint URL
#   AZURE_SEARCH_INDEX_NAME     - Search index name (default: documents-index)
#   COSMOS_ENDPOINT             - Cosmos DB endpoint URL
#   COSMOS_DATABASE_NAME        - Cosmos DB database name (default: rag-platform)
###############################################################################

usage() {
    cat <<EOF
Usage: $0 --resource-group <rg> --workspace-name <ws> --endpoint-name <ep>

Required arguments:
  --resource-group, -g    Azure resource group name
  --workspace-name, -w    Azure ML workspace name
  --endpoint-name, -e     Managed online endpoint name

Optional environment variables:
  AZURE_SEARCH_ENDPOINT       Azure AI Search endpoint URL
  AZURE_SEARCH_INDEX_NAME     Search index name (default: documents-index)
  COSMOS_ENDPOINT             Cosmos DB endpoint URL
  COSMOS_DATABASE_NAME        Cosmos DB database name (default: rag-platform)
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
RESOURCE_GROUP=""
WORKSPACE_NAME=""
ENDPOINT_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group|-g)
            RESOURCE_GROUP="$2"; shift 2 ;;
        --workspace-name|-w)
            WORKSPACE_NAME="$2"; shift 2 ;;
        --endpoint-name|-e)
            ENDPOINT_NAME="$2"; shift 2 ;;
        -h|--help)
            usage ;;
        *)
            echo "Error: Unknown argument '$1'"
            usage ;;
    esac
done

if [[ -z "$RESOURCE_GROUP" || -z "$WORKSPACE_NAME" || -z "$ENDPOINT_NAME" ]]; then
    echo "Error: All required arguments must be provided."
    usage
fi

# Defaults for optional env vars
AZURE_SEARCH_INDEX_NAME="${AZURE_SEARCH_INDEX_NAME:-documents-index}"
COSMOS_DATABASE_NAME="${COSMOS_DATABASE_NAME:-rag-platform}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW_PATH="${SCRIPT_DIR}/../flows/rag-chat"
MODEL_NAME="rag-chat-flow"
DEPLOYMENT_NAME="rag-chat-deployment"
INSTANCE_TYPE="Standard_DS3_v2"
INSTANCE_COUNT=1

echo "==> Registering flow as a model: ${MODEL_NAME}"
az ml model create \
    --name "${MODEL_NAME}" \
    --path "${FLOW_PATH}" \
    --type custom_model \
    --resource-group "${RESOURCE_GROUP}" \
    --workspace-name "${WORKSPACE_NAME}"

MODEL_VERSION=$(az ml model show \
    --name "${MODEL_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --workspace-name "${WORKSPACE_NAME}" \
    --query "version" -o tsv)

echo "==> Registered model version: ${MODEL_VERSION}"

# ---------------------------------------------------------------------------
# Create endpoint if it does not exist
# ---------------------------------------------------------------------------
ENDPOINT_EXISTS=$(az ml online-endpoint show \
    --name "${ENDPOINT_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --workspace-name "${WORKSPACE_NAME}" \
    --query "name" -o tsv 2>/dev/null || true)

if [[ -z "$ENDPOINT_EXISTS" ]]; then
    echo "==> Creating online endpoint: ${ENDPOINT_NAME}"
    az ml online-endpoint create \
        --name "${ENDPOINT_NAME}" \
        --resource-group "${RESOURCE_GROUP}" \
        --workspace-name "${WORKSPACE_NAME}" \
        --auth-mode aad_token
else
    echo "==> Endpoint '${ENDPOINT_NAME}' already exists, skipping creation."
fi

# ---------------------------------------------------------------------------
# Build deployment YAML
# ---------------------------------------------------------------------------
DEPLOY_YAML=$(mktemp /tmp/deployment-XXXXXX.yaml)
trap 'rm -f "${DEPLOY_YAML}"' EXIT

cat > "${DEPLOY_YAML}" <<YAML
\$schema: https://azuremlschemas.azureedge.net/latest/managedOnlineDeployment.schema.json
name: ${DEPLOYMENT_NAME}
endpoint_name: ${ENDPOINT_NAME}
model: azureml:${MODEL_NAME}:${MODEL_VERSION}
instance_type: ${INSTANCE_TYPE}
instance_count: ${INSTANCE_COUNT}
environment_variables:
  AZURE_SEARCH_ENDPOINT: "${AZURE_SEARCH_ENDPOINT:-}"
  AZURE_SEARCH_INDEX_NAME: "${AZURE_SEARCH_INDEX_NAME}"
  COSMOS_ENDPOINT: "${COSMOS_ENDPOINT:-}"
  COSMOS_DATABASE_NAME: "${COSMOS_DATABASE_NAME}"
YAML

echo "==> Creating/updating deployment: ${DEPLOYMENT_NAME}"
az ml online-deployment create \
    --file "${DEPLOY_YAML}" \
    --resource-group "${RESOURCE_GROUP}" \
    --workspace-name "${WORKSPACE_NAME}" \
    --all-traffic

echo "==> Setting traffic to 100% on ${DEPLOYMENT_NAME}"
az ml online-endpoint update \
    --name "${ENDPOINT_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --workspace-name "${WORKSPACE_NAME}" \
    --traffic "${DEPLOYMENT_NAME}=100"

echo "==> Deployment complete."
echo "    Endpoint: ${ENDPOINT_NAME}"
echo "    Deployment: ${DEPLOYMENT_NAME}"
echo "    Model: ${MODEL_NAME}:${MODEL_VERSION}"

SCORING_URI=$(az ml online-endpoint show \
    --name "${ENDPOINT_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --workspace-name "${WORKSPACE_NAME}" \
    --query "scoring_uri" -o tsv 2>/dev/null || true)

if [[ -n "$SCORING_URI" ]]; then
    echo "    Scoring URI: ${SCORING_URI}"
fi
