# Admin Portal — Azure Setup

This document explains how the admin portal interacts with Azure services behind the scenes, what RBAC roles are required, and how the APIM policy update works.

## Azure Service Interactions

### 1. APIM Management (REST API)

The admin portal manages APIM resources using the Azure Management REST API (`api-version=2024-05-01`) with `aiohttp` and `DefaultAzureCredential`.

**Why REST API instead of the Azure SDK?** The APIM SDK (`azure-mgmt-apimanagement`) is synchronous and doesn't fit the async Quart app. Using `aiohttp` directly keeps everything async and avoids pulling in a heavy management SDK.

#### Product Creation

```
PUT https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}
    /providers/Microsoft.ApiManagement/service/{apim}/products/{tenant-id}
    ?api-version=2024-05-01

Body:
{
  "properties": {
    "displayName": "Sports Chatbot",
    "subscriptionRequired": true,
    "approvalRequired": false,
    "state": "published"
  }
}
```

#### API Linking

After creating the product, the `rag-platform-api` is linked to it so that subscription keys for this product grant access to the API:

```
PUT .../products/{tenant-id}/apis/rag-platform-api?api-version=2024-05-01
```

#### Subscription + Key Retrieval

```
PUT  .../subscriptions/{tenant-id}-subscription  (create)
POST .../subscriptions/{tenant-id}-subscription/listSecrets  (get primary key)
```

The `listSecrets` endpoint is the only way to retrieve APIM subscription keys — the `az` CLI does not have a `list-secrets` subcommand for APIM subscriptions.

#### Named Value Creation

The subscription key is stored as a secret named value (`openai-key-{tenant-id}`), which can be referenced in APIM policies using `{{openai-key-{tenant-id}}}`:

```
PUT .../namedValues/openai-key-{tenant-id}?api-version=2024-05-01

Body:
{
  "properties": {
    "displayName": "openai-key-sports-chatbot",
    "value": "<the-actual-subscription-key>",
    "secret": true
  }
}
```

#### Policy XML Update

The OpenAI-compatible API (`rag-openai-api`) uses a `<choose>` block to map bearer tokens to tenant IDs. When a new tenant is created, the admin portal:

1. **GET** the current policy XML with its ETag
2. **Parse** the XML using `xml.etree.ElementTree`
3. **Find** the `<choose>` block containing `openai-key-*` conditions
4. **Append** a new `<when>` element:

```xml
<when condition="@((string)context.Variables[&quot;apiKey&quot;] == &quot;{{openai-key-sports-chatbot}}&quot;)">
    <set-variable name="resolvedAppId" value="sports-chatbot" />
</when>
```

5. **PUT** the updated XML back with the `If-Match` ETag header to prevent concurrent modification conflicts

### 2. Cosmos DB (azure-cosmos SDK)

Uses the async `azure.cosmos.aio` SDK — same pattern as the main backend's `CosmosDBChatHistory` class.

- **Container**: `chatbot-config`
- **Partition key**: `/chatbotId`
- **Operations**: `upsert_item` (create), `read_item` (get), `replace_item` (update), `delete_item` (delete), `query_items` with `enable_cross_partition_query=True` (list)

### 3. Blob Storage (azure-storage-blob SDK)

Uses the async `azure.storage.blob.aio` SDK with `DefaultAzureCredential` (shared key access is disabled on the storage account).

- **Container**: `documents`
- **Blob path**: `{tenant-id}/{filename}`
- **Metadata**: `app_scope={tenant-id}` — this is the field the AI Search indexer maps to the `app_scope` index field for tenant isolation

### 4. AI Search (REST API)

Uses `aiohttp` with a bearer token scoped to `https://search.azure.com/.default`.

- **Trigger indexer**: `POST {endpoint}/indexers/documents-indexer/run?api-version=2024-07-01`
- **Get status**: `GET {endpoint}/indexers/documents-indexer/status?api-version=2024-07-01`

## RBAC Requirements

The admin portal's managed identity needs these roles:

| Role | Role Definition ID | Scope | Why |
|------|-------------------|-------|-----|
| API Management Service Contributor | `312a565d-c81f-4fd8-895a-4e21e48d571c` | APIM resource | Create/modify products, subscriptions, named values, policies |
| Cosmos DB Built-in Data Contributor | `00000000-0000-0000-0000-000000000002` | Cosmos DB account | CRUD on chatbot-config container |
| Storage Blob Data Contributor | `ba92f5b4-2d11-453d-a403-e96b0029c9fe` | Storage account | Upload/delete document blobs |
| Search Service Contributor | `7ca78c08-252a-4471-8644-bb5ff32d4ba0` | AI Search service | Trigger indexer runs |

The first role (APIM Service Contributor) is new and is added by the updated `infra/modules/apim.bicep`. The other three roles already exist from the main platform deployment.

## How the OpenAI-Compatible API Policy Works

The `rag-openai-api` serves OpenAI-compatible endpoints (`/v1/chat/completions`, `/v1/models`) for third-party clients like Open WebUI and LibreChat that expect OpenAI API format.

Since these clients send `Authorization: Bearer <key>` headers (not APIM subscription headers), the policy manually maps keys to tenants:

```xml
<set-variable name="apiKey" value="@{
    string authHeader = context.Request.Headers.GetValueOrDefault("Authorization", "");
    if (authHeader.StartsWith("Bearer ")) {
        return authHeader.Substring(7).Trim();
    }
    return context.Request.Headers.GetValueOrDefault("Ocp-Apim-Subscription-Key", "");
}" />

<choose>
    <when condition="@(apiKey == {{openai-key-hr-chatbot}})">
        <set-variable name="resolvedAppId" value="hr-chatbot" />
    </when>
    <when condition="@(apiKey == {{openai-key-legal-chatbot}})">
        <set-variable name="resolvedAppId" value="legal-chatbot" />
    </when>
    <!-- New tenants get added here by the admin portal -->
</choose>
```

The `{{openai-key-*}}` syntax references APIM named values, which are resolved at runtime. When the admin portal creates a new tenant, it creates the named value and adds the corresponding `<when>` block.
