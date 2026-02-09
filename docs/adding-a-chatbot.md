# Adding a New Chatbot

This runbook walks through the complete process of adding a new tenant chatbot to the multi-tenant RAG platform.

**Estimated time:** 30-45 minutes

---

## Prerequisites

- Azure CLI installed and authenticated (`az login`)
- Contributor access to the resource group
- API Management administrator access
- Cosmos DB Built-in Data Contributor role
- Storage Blob Data Contributor role

---

## Step 1: Create an APIM Product and Subscription

Each chatbot gets its own API Management product and subscription key. This enables per-tenant rate limiting, monitoring, and access control.

### 1.1 Create the APIM Product

```bash
APIM_NAME="<your-apim-name>"
RESOURCE_GROUP="<your-resource-group>"
CHATBOT_ID="finance-chatbot"
CHATBOT_DISPLAY_NAME="Finance Assistant"

az apim product create \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --product-id "$CHATBOT_ID" \
  --display-name "$CHATBOT_DISPLAY_NAME" \
  --description "Product for the $CHATBOT_DISPLAY_NAME chatbot" \
  --subscription-required true \
  --approval-required false \
  --state published
```

### 1.2 Add the RAG API to the Product

```bash
az apim product api add \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --product-id "$CHATBOT_ID" \
  --api-id "rag-chat-api"
```

### 1.3 Create a Subscription

```bash
az apim subscription create \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --product-id "/products/$CHATBOT_ID" \
  --display-name "${CHATBOT_ID}-subscription" \
  --subscription-id "${CHATBOT_ID}-sub"
```

### 1.4 Retrieve the Subscription Key

```bash
az apim subscription show \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --subscription-id "${CHATBOT_ID}-sub" \
  --query "primaryKey" -o tsv
```

Save this key -- you will need it for the frontend configuration.

---

## Step 2: Add Chatbot Configuration to Cosmos DB

The chatbot configuration document controls the system prompt, temperature, UI settings, and document scoping.

### 2.1 Prepare the Configuration Document

```json
{
  "id": "finance-chatbot",
  "chatbotId": "finance-chatbot",
  "chatbotName": "Finance Assistant",
  "system_prompt": "You are a finance assistant for the organization. Answer questions about financial policies, budgets, expense procedures, and reporting using the provided context. Be precise and include relevant policy references. If you cannot find the answer in the provided context, say so clearly.",
  "temperature": 0.3,
  "max_tokens": 1024,
  "welcomeMessage": "Hello! I'm your finance assistant. Ask me about budgets, expense policies, or financial procedures.",
  "primaryColor": "#D97706",
  "app_scopes": ["finance-chatbot"]
}
```

### 2.2 Insert the Configuration

You can use the seed script with a single item or insert directly:

```bash
COSMOS_ENDPOINT="https://<your-cosmos-account>.documents.azure.com:443/"

# Get access token
TOKEN=$(az account get-access-token \
  --resource https://cosmos.azure.com \
  --query accessToken -o tsv)

# Upsert the document
curl -X POST "${COSMOS_ENDPOINT}dbs/rag-platform/colls/chatbot-config/docs" \
  -H "Authorization: type=aad&ver=1.0&sig=${TOKEN}" \
  -H "Content-Type: application/json" \
  -H "x-ms-version: 2018-12-31" \
  -H "x-ms-documentdb-is-upsert: True" \
  -H "x-ms-documentdb-partitionkey: [\"finance-chatbot\"]" \
  -d '{
    "id": "finance-chatbot",
    "chatbotId": "finance-chatbot",
    "chatbotName": "Finance Assistant",
    "system_prompt": "You are a finance assistant...",
    "temperature": 0.3,
    "max_tokens": 1024,
    "welcomeMessage": "Hello! I am your finance assistant.",
    "primaryColor": "#D97706",
    "app_scopes": ["finance-chatbot"]
  }'
```

---

## Step 3: Create Blob Folder and Upload Documents

### 3.1 Create the Folder Structure

Azure Blob Storage uses virtual directories. Simply upload files with the chatbot ID as the path prefix.

```bash
STORAGE_ACCOUNT="<your-storage-account>"
CONTAINER="documents"

# Upload a document
az storage blob upload \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$CONTAINER" \
  --name "finance-chatbot/expense-policy.pdf" \
  --file ./data/finance-chatbot/expense-policy.pdf \
  --auth-mode login
```

### 3.2 Upload Multiple Documents

```bash
# Upload all files from a local directory
for file in ./data/finance-chatbot/*; do
  filename=$(basename "$file")
  az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER" \
    --name "finance-chatbot/$filename" \
    --file "$file" \
    --auth-mode login \
    --overwrite
done
```

---

## Step 4: Set app_scope Metadata on Documents

The `app_scope` metadata tag controls which chatbot can access each document via AI Search filtering.

```bash
# Set metadata on each uploaded blob
for file in ./data/finance-chatbot/*; do
  filename=$(basename "$file")
  az storage blob metadata update \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER" \
    --name "finance-chatbot/$filename" \
    --metadata "app_scope=finance-chatbot" \
    --auth-mode login
done
```

For documents shared across multiple chatbots, use comma-separated values:

```bash
az storage blob metadata update \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name "$CONTAINER" \
  --name "shared/company-handbook.pdf" \
  --metadata "app_scope=finance-chatbot,hr-chatbot,exec-chatbot" \
  --auth-mode login
```

After setting metadata, trigger the AI Search indexer to reindex:

```bash
SEARCH_ENDPOINT="https://<your-search-service>.search.windows.net"
INDEXER_NAME="documents-indexer"

az rest --method POST \
  --url "${SEARCH_ENDPOINT}/indexers/${INDEXER_NAME}/run?api-version=2024-07-01" \
  --resource "https://search.azure.com"
```

---

## Step 5: Deploy Frontend with New APIM Key

Update the frontend environment to include the new chatbot's APIM subscription key.

### 5.1 Local Development

Create or update the `.env` file in `app/frontend/`:

```env
VITE_APP_ID=finance-chatbot
VITE_APIM_KEY=<subscription-key-from-step-1>
VITE_APIM_ENDPOINT=https://<your-apim-name>.azure-api.net
```

### 5.2 Production Deployment

Update the Container Apps environment variables or rebuild the Docker image with the new `VITE_APP_ID` build argument:

```bash
docker build \
  --build-arg VITE_APP_ID=finance-chatbot \
  -t myacr.azurecr.io/rag-platform:finance \
  ./app
```

---

## Step 6: Verify

### 6.1 Test the Configuration Endpoint

```bash
curl -s "https://<backend-url>/config/finance-chatbot" | python3 -m json.tool
```

Expected response:

```json
{
  "chatbotId": "finance-chatbot",
  "chatbotName": "Finance Assistant",
  "welcomeMessage": "Hello! I'm your finance assistant...",
  "primaryColor": "#D97706"
}
```

### 6.2 Test a Chat Query

```bash
curl -s -X POST "https://<backend-url>/chat" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "What is the expense reimbursement policy?"}],
    "context": {"app_id": "finance-chatbot"}
  }'
```

### 6.3 Verify Document Isolation

Confirm that the new chatbot can only access its own documents and shared documents:

```bash
# This should return results
curl -s -X POST "https://<backend-url>/chat" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "What is the expense policy?"}],
    "context": {"app_id": "finance-chatbot"}
  }'

# This should NOT return finance documents
curl -s -X POST "https://<backend-url>/chat" \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "What is the expense policy?"}],
    "context": {"app_id": "hr-chatbot"}
  }'
```

---

## Troubleshooting

| Problem | Possible Cause | Solution |
|---|---|---|
| 404 on /config endpoint | Cosmos DB document missing | Verify the document exists in the chatbot-config container with the correct partition key |
| Empty search results | app_scope metadata not set | Check blob metadata and re-trigger the indexer |
| Wrong documents returned | Incorrect app_scope value | Verify the app_scope metadata matches the chatbot ID exactly |
| APIM returns 401 | Invalid subscription key | Verify the subscription key and ensure the product is published |
| Indexer not picking up new docs | Indexer schedule | Manually trigger the indexer or wait for the next scheduled run (every 5 minutes) |

---

## Quick Reference

| Item | Value |
|---|---|
| Cosmos DB database | `rag-platform` |
| Config container | `chatbot-config` |
| Config partition key | `/chatbotId` |
| Blob container | `documents` |
| Blob path convention | `<chatbot-id>/<filename>` |
| Metadata key | `app_scope` |
| Search index | `documents-index` |
| Indexer name | `documents-indexer` |
