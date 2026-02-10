# Admin Portal — Verification Guide

Step-by-step instructions for verifying the admin portal deployment and the Azure resources it manages.

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- Access to the resource group (`rg-rag-dev-qoggj`)
- The admin portal URL (Container App FQDN)

## Step 1: Verify the Container App is Running

```bash
# Check the admin-portal Container App exists and is running
az containerapp show \
  --name admin-portal \
  --resource-group rg-rag-dev-qoggj \
  --query '{fqdn:properties.configuration.ingress.fqdn, status:properties.runningStatus}' \
  -o json
```

Expected: an FQDN like `admin-portal.<env-id>.uksouth.azurecontainerapps.io` with a running status.

```bash
# Health check
curl -s https://<admin-portal-fqdn>/health
```

Expected: `{"status": "ok"}`

## Step 2: Verify RBAC Roles

Check that the managed identity has the required roles:

```bash
IDENTITY_PRINCIPAL_ID="715b7950-0b27-4465-a12e-2c211e967876"
RESOURCE_GROUP="rg-rag-dev-qoggj"

# List role assignments for the identity
az role assignment list \
  --assignee "$IDENTITY_PRINCIPAL_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --query '[].{role:roleDefinitionName, scope:scope}' \
  -o table
```

You should see at least:
- **API Management Service Contributor** on the APIM resource
- **Cosmos DB Built-in Data Contributor** on the Cosmos account
- **Storage Blob Data Contributor** on the storage account

## Step 3: Verify the Portal Lists Existing Tenants

Open the admin portal in a browser:

```
https://<admin-portal-fqdn>/
```

You should see a table with the three existing tenants:
- `hr-chatbot` — HR Assistant
- `legal-chatbot` — Legal Assistant
- `exec-chatbot` — Executive Briefing Assistant

Or test via curl:

```bash
curl -s https://<admin-portal-fqdn>/api/tenants | python3 -m json.tool
```

## Step 4: Create a Test Tenant

In the browser, click **Create Tenant** and fill in:

| Field | Value |
|-------|-------|
| Tenant ID | `test-chatbot` |
| Display Name | `Test Assistant` |
| System Prompt | `You are a test assistant.` |
| Temperature | `0.3` |
| Max Tokens | `1024` |
| Welcome Message | `Hello! This is a test.` |
| Primary Colour | Pick any colour |

Click **Create Tenant**. The page should show the APIM subscription key.

## Step 5: Verify APIM Resources Were Created

```bash
APIM_NAME="rag-dev-qoggj-apim"
RESOURCE_GROUP="rg-rag-dev-qoggj"

# Check the product exists
az apim product show \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --product-id "test-chatbot" \
  --query '{displayName:displayName, state:state}' \
  -o json

# Check the subscription exists
az apim subscription show \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --subscription-id "test-chatbot-subscription" \
  --query '{displayName:displayName, state:state}' \
  -o json

# Check the named value exists
az apim nv show \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --named-value-id "openai-key-test-chatbot" \
  --query '{displayName:displayName, secret:secret}' \
  -o json
```

## Step 6: Verify the Policy Was Updated

```bash
# Get the OpenAI API policy
az apim api policy show \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --api-id "rag-openai-api" \
  --policy-id "policy" \
  --query 'value' -o tsv | grep "test-chatbot"
```

Expected: a `<when>` block referencing `openai-key-test-chatbot`.

## Step 7: Verify Cosmos DB Config

```bash
COSMOS_ENDPOINT="https://rag-dev-qoggj-cosmos.documents.azure.com:443/"

TOKEN=$(az account get-access-token \
  --resource https://cosmos.azure.com \
  --query accessToken -o tsv)

curl -s "${COSMOS_ENDPOINT}dbs/rag-platform/colls/chatbot-config/docs/test-chatbot" \
  -H "Authorization: type=aad&ver=1.0&sig=${TOKEN}" \
  -H "x-ms-version: 2018-12-31" \
  -H "x-ms-documentdb-partitionkey: [\"test-chatbot\"]" | python3 -m json.tool
```

## Step 8: Upload a Document and Reindex

1. In the tenant detail view, use the drag-and-drop area to upload a test document (any `.txt` or `.pdf` file).
2. Click **Reindex** to trigger the AI Search indexer.

Verify the blob was created with the correct metadata:

```bash
STORAGE_ACCOUNT="ragdevqoggjstor"

az storage blob list \
  --account-name "$STORAGE_ACCOUNT" \
  --container-name documents \
  --prefix "test-chatbot/" \
  --auth-mode login \
  --query '[].{name:name, metadata:metadata}' \
  -o json
```

Expected: blob(s) with `metadata.app_scope = "test-chatbot"`.

## Step 9: Test End-to-End via APIM

Using the subscription key from step 4:

```bash
APIM_GATEWAY="https://rag-dev-qoggj-apim.azure-api.net"
SUBSCRIPTION_KEY="<key-from-step-4>"

# Test via the subscription API
curl -s -X POST "${APIM_GATEWAY}/api/chat" \
  -H "Content-Type: application/json" \
  -H "Ocp-Apim-Subscription-Key: ${SUBSCRIPTION_KEY}" \
  -d '{
    "messages": [{"role": "user", "content": "What documents do you have?"}]
  }'
```

## Step 10: Clean Up Test Tenant

In the admin portal, navigate to the test tenant detail view and click **Delete Tenant**. This removes:
- The Cosmos DB config document
- The APIM named value, subscription, API link, and product

Verify cleanup:

```bash
# Should return 404 / not found
az apim product show \
  --resource-group "$RESOURCE_GROUP" \
  --service-name "$APIM_NAME" \
  --product-id "test-chatbot" 2>&1 | head -1
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Portal returns 500 on tenant list | Missing COSMOS_ENDPOINT or COSMOS_DATABASE env var | Check Container App env vars |
| "Failed to create product" error | Missing APIM Service Contributor role | Assign the role to the managed identity |
| "Failed to get subscription key" | Subscription creation failed upstream | Check APIM product and subscription in Azure Portal |
| Policy update fails with 412 | Concurrent policy modification | Retry — the portal uses ETag-based optimistic concurrency |
| Document upload fails | Missing Storage Blob Data Contributor role | Assign the role to the managed identity |
| Indexer shows "error" status | Usually transient — RBAC propagation delay | Wait a few minutes and retry |
| Portal page loads but shows blank | Static file path mismatch | Check browser console for 404 errors on `/static/*` |
