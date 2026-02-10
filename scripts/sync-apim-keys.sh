#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Sync APIM subscription keys into named values for OpenAI bearer token auth.
#
# Reads the primary key from each product subscription via the listSecrets
# REST API, then writes it into the corresponding APIM named value so the
# OpenAI-compatible API policy can match bearer tokens to tenants.
#
# Usage:
#   ./scripts/sync-apim-keys.sh \
#     --resource-group <rg-name> \
#     --apim-name <apim-name>
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - Contributor or API Management Service Contributor role
###############################################################################

usage() {
    cat <<EOF
Usage: $0 --resource-group <rg-name> --apim-name <apim-name>

Required arguments:
  --resource-group, -g    Resource group name
  --apim-name, -n         APIM service name

Examples:
  $0 --resource-group rg-rag-dev-qoggj --apim-name rag-dev-qoggj-apim
EOF
    exit 1
}

RESOURCE_GROUP=""
APIM_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group|-g)
            RESOURCE_GROUP="$2"; shift 2 ;;
        --apim-name|-n)
            APIM_NAME="$2"; shift 2 ;;
        -h|--help)
            usage ;;
        *)
            echo "Error: Unknown argument '$1'"
            usage ;;
    esac
done

if [[ -z "$RESOURCE_GROUP" || -z "$APIM_NAME" ]]; then
    echo "Error: --resource-group and --apim-name are required."
    usage
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv)

echo "==> Subscription: $SUBSCRIPTION_ID"
echo "==> Resource group: $RESOURCE_GROUP"
echo "==> APIM service: $APIM_NAME"
echo ""

# Product subscription mappings (parallel arrays for Bash 3 compat)
SUB_NAMES=(
    "hr-chatbot-subscription"
    "legal-chatbot-subscription"
    "exec-chatbot-subscription"
)
NV_NAMES=(
    "openai-key-hr-chatbot"
    "openai-key-legal-chatbot"
    "openai-key-exec-chatbot"
)

for i in "${!SUB_NAMES[@]}"; do
    sub_name="${SUB_NAMES[$i]}"
    nv_name="${NV_NAMES[$i]}"

    echo "==> Reading key for subscription: $sub_name"

    # Use listSecrets REST API to get the subscription's primary key
    primary_key=$(az rest \
        --method POST \
        --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/${sub_name}/listSecrets?api-version=2024-05-01" \
        --query primaryKey -o tsv)

    if [[ -z "$primary_key" ]]; then
        echo "    Error: Could not retrieve key for $sub_name"
        continue
    fi

    echo "    Key retrieved (${#primary_key} chars)"

    # Update the named value with the actual subscription key
    echo "    Writing to named value: $nv_name"
    az rest \
        --method PATCH \
        --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/namedValues/${nv_name}?api-version=2024-05-01" \
        --headers "Content-Type=application/json" "If-Match=*" \
        --body "{\"properties\": {\"value\": \"${primary_key}\", \"secret\": true}}" \
        --only-show-errors -o none

    echo "    Done."
    echo ""
done

echo "==> All subscription keys synced to named values."
echo ""

# ============================================================================
# Sync keys to Container Apps
# ============================================================================

echo "==> Syncing APIM keys to Container Apps..."

# Get exec-chatbot key for Open WebUI
EXEC_KEY=$(az rest \
    --method POST \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/exec-chatbot-subscription/listSecrets?api-version=2024-05-01" \
    --query primaryKey -o tsv)

if [[ -n "$EXEC_KEY" ]]; then
    echo "    Updating open-webui OPENAI_API_KEY..."
    az containerapp update \
        --name open-webui \
        --resource-group "$RESOURCE_GROUP" \
        --set-env-vars "OPENAI_API_KEY=$EXEC_KEY" \
        --only-show-errors -o none
    echo "    Done."
else
    echo "    Warning: Could not retrieve exec-chatbot key for open-webui"
fi

# Get legal-chatbot key for LibreChat
LEGAL_KEY=$(az rest \
    --method POST \
    --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/legal-chatbot-subscription/listSecrets?api-version=2024-05-01" \
    --query primaryKey -o tsv)

if [[ -n "$LEGAL_KEY" ]]; then
    echo "    Updating librechat APIM_SUBSCRIPTION_KEY..."
    az containerapp update \
        --name librechat \
        --resource-group "$RESOURCE_GROUP" \
        --set-env-vars "APIM_SUBSCRIPTION_KEY=$LEGAL_KEY" \
        --only-show-errors -o none
    echo "    Done."
else
    echo "    Warning: Could not retrieve legal-chatbot key for librechat"
fi

# Set LibreChat DOMAIN_SERVER and DOMAIN_CLIENT from its FQDN
LIBRECHAT_FQDN=$(az containerapp show \
    --name librechat \
    --resource-group "$RESOURCE_GROUP" \
    --query "properties.configuration.ingress.fqdn" -o tsv 2>/dev/null)

if [[ -n "$LIBRECHAT_FQDN" ]]; then
    echo "    Updating librechat DOMAIN_SERVER and DOMAIN_CLIENT..."
    az containerapp update \
        --name librechat \
        --resource-group "$RESOURCE_GROUP" \
        --set-env-vars "DOMAIN_SERVER=https://${LIBRECHAT_FQDN}" "DOMAIN_CLIENT=https://${LIBRECHAT_FQDN}" \
        --only-show-errors -o none
    echo "    Done."
fi

echo ""
echo "==> All keys synced."
echo ""
echo "Test the OpenAI API with:"
echo "  curl -X POST https://${APIM_NAME}.azure-api.net/v1/chat/completions \\"
echo "    -H 'Authorization: Bearer <subscription-key>' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"rag-platform\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"stream\":true}'"
