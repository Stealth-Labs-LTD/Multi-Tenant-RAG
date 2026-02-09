#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Seed chatbot configuration documents into Cosmos DB.
#
# Usage:
#   ./scripts/seed-chatbot-config.sh \
#     --cosmos-endpoint <endpoint-url> \
#     [--database <database-name>]
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - Cosmos DB Built-in Data Contributor role on the target account
#
# The script creates three chatbot configurations:
#   - hr-chatbot:   HR policy assistant
#   - legal-chatbot: Legal/compliance assistant
#   - exec-chatbot:  Executive briefing assistant
###############################################################################

usage() {
    cat <<EOF
Usage: $0 --cosmos-endpoint <endpoint-url> [--database <database-name>]

Required arguments:
  --cosmos-endpoint, -c    Cosmos DB endpoint URL (e.g. https://myaccount.documents.azure.com:443/)

Optional arguments:
  --database, -d           Database name (default: rag-platform)

Examples:
  $0 --cosmos-endpoint https://rag-dev-cosmos.documents.azure.com:443/
  $0 -c https://rag-dev-cosmos.documents.azure.com:443/ -d my-database
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
COSMOS_ENDPOINT=""
COSMOS_DATABASE="rag-platform"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cosmos-endpoint|-c)
            COSMOS_ENDPOINT="$2"; shift 2 ;;
        --database|-d)
            COSMOS_DATABASE="$2"; shift 2 ;;
        -h|--help)
            usage ;;
        *)
            echo "Error: Unknown argument '$1'"
            usage ;;
    esac
done

if [[ -z "$COSMOS_ENDPOINT" ]]; then
    echo "Error: --cosmos-endpoint is required."
    usage
fi

# ---------------------------------------------------------------------------
# Resolve Cosmos DB account name from the endpoint URL
# ---------------------------------------------------------------------------
COSMOS_ACCOUNT_NAME=$(echo "$COSMOS_ENDPOINT" | sed -E 's|https://([^.]+)\..*|\1|')

echo "==> Cosmos DB endpoint:  $COSMOS_ENDPOINT"
echo "==> Cosmos DB account:   $COSMOS_ACCOUNT_NAME"
echo "==> Database:            $COSMOS_DATABASE"
echo ""

# ---------------------------------------------------------------------------
# Helper: upsert a document via az cosmosdb sql container create-item or REST
# Falls back to REST API if the CLI command is unavailable.
# ---------------------------------------------------------------------------
upsert_item() {
    local container_name="$1"
    local partition_key_value="$2"
    local document="$3"

    echo "    Upserting item in container '$container_name' with partition key '$partition_key_value'..."

    # Try using az rest with the Cosmos DB REST API
    local resource_url="${COSMOS_ENDPOINT}dbs/${COSMOS_DATABASE}/colls/${container_name}/docs"

    # Get an access token for Cosmos DB
    local token
    token=$(az account get-access-token \
        --resource https://cosmos.azure.com \
        --query accessToken -o tsv 2>/dev/null) || {
        echo "    Error: Failed to get Cosmos DB access token. Ensure you are logged in with 'az login'."
        return 1
    }

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "$resource_url" \
        -H "Authorization: type=aad&ver=1.0&sig=${token}" \
        -H "Content-Type: application/json" \
        -H "x-ms-version: 2018-12-31" \
        -H "x-ms-documentdb-is-upsert: True" \
        -H "x-ms-documentdb-partitionkey: [\"${partition_key_value}\"]" \
        -d "$document")

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "    Success (HTTP $http_code)"
    else
        echo "    Warning: HTTP $http_code returned. Attempting fallback via az CLI..."
        local tmpfile
        tmpfile=$(mktemp /tmp/cosmos-doc-XXXXXX.json)
        echo "$document" > "$tmpfile"

        az cosmosdb sql container create-item \
            --account-name "$COSMOS_ACCOUNT_NAME" \
            --database-name "$COSMOS_DATABASE" \
            --container-name "$container_name" \
            --body @"$tmpfile" \
            2>/dev/null || {
                echo "    Error: Failed to upsert item. Check your permissions and Cosmos DB configuration."
                rm -f "$tmpfile"
                return 1
            }

        rm -f "$tmpfile"
        echo "    Success (via az CLI fallback)"
    fi
}

# ---------------------------------------------------------------------------
# Chatbot configurations
# ---------------------------------------------------------------------------
echo "==> Seeding HR chatbot configuration..."
upsert_item "chatbot-config" "hr-chatbot" '{
  "id": "hr-chatbot",
  "chatbotId": "hr-chatbot",
  "chatbotName": "HR Assistant",
  "system_prompt": "You are an HR assistant for the organization. Answer questions about HR policies, benefits, leave, and workplace procedures using the provided context. Be helpful, professional, and accurate. If you cannot find the answer in the provided context, say so clearly.",
  "temperature": 0.3,
  "max_tokens": 1024,
  "welcomeMessage": "Hello! I'\''m your HR assistant. Ask me about company policies, benefits, or workplace procedures.",
  "primaryColor": "#2563EB",
  "app_scopes": ["hr-chatbot"]
}'

echo ""
echo "==> Seeding Legal chatbot configuration..."
upsert_item "chatbot-config" "legal-chatbot" '{
  "id": "legal-chatbot",
  "chatbotId": "legal-chatbot",
  "chatbotName": "Legal Assistant",
  "system_prompt": "You are a legal assistant for the organization. Answer questions about terms of service, compliance policies, contracts, and legal procedures using the provided context. Be precise, thorough, and always include relevant caveats. If you cannot find the answer in the provided context, say so clearly and recommend consulting the legal team.",
  "temperature": 0.2,
  "max_tokens": 2048,
  "welcomeMessage": "Hello! I'\''m your legal assistant. Ask me about terms of service, compliance policies, or legal procedures.",
  "primaryColor": "#7C3AED",
  "app_scopes": ["legal-chatbot"]
}'

echo ""
echo "==> Seeding Executive chatbot configuration..."
upsert_item "chatbot-config" "exec-chatbot" '{
  "id": "exec-chatbot",
  "chatbotId": "exec-chatbot",
  "chatbotName": "Executive Briefing Assistant",
  "system_prompt": "You are an executive briefing assistant. Provide concise, strategic summaries of organizational information using the provided context. Focus on key insights, metrics, and actionable recommendations. Present information in a clear, executive-friendly format with bullet points where appropriate. If you cannot find the answer in the provided context, say so clearly.",
  "temperature": 0.4,
  "max_tokens": 1536,
  "welcomeMessage": "Hello! I'\''m your executive briefing assistant. Ask me for strategic summaries, key metrics, or organizational insights.",
  "primaryColor": "#059669",
  "app_scopes": ["exec-chatbot"]
}'

echo ""
echo "==> All chatbot configurations seeded successfully."
echo ""
echo "Verify by querying the chatbot-config container:"
echo "  az cosmosdb sql container read-item \\"
echo "    --account-name $COSMOS_ACCOUNT_NAME \\"
echo "    --database-name $COSMOS_DATABASE \\"
echo "    --container-name chatbot-config \\"
echo "    --partition-key-path '/chatbotId' \\"
echo "    --rid hr-chatbot"
