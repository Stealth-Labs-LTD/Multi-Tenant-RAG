// ============================================================================
// Module: apim.bicep
// Description: Azure API Management with multi-tenant RAG policies
//
// Two API patterns for the demo:
//   1. rag-platform-api (/api) — built-in subscription key validation
//   2. rag-openai-api (/v1)   — bearer token validation in policy (OpenAI-compat)
// ============================================================================

@description('Azure region for resource deployment')
param location string

@description('Naming prefix for resources')
param prefix string

@description('Deployment environment')
@allowed(['dev', 'staging', 'prod'])
param environment string

@description('Resource ID of the user-assigned managed identity')
param identityId string

@description('Client ID of the user-assigned managed identity')
#disable-next-line no-unused-params
param identityClientId string

@description('Key Vault URI')
#disable-next-line no-unused-params
param keyVaultUri string

@description('Application Insights instrumentation key')
param appInsightsInstrumentationKey string

@description('Prompt Flow scoring endpoint URL')
param promptFlowEndpoint string

@description('Publisher name for APIM')
param publisherName string

@description('Publisher email for APIM')
param publisherEmail string

@description('Tags to apply to resources')
param tags object

var skuName = environment == 'dev' ? 'Developer' : 'Standard'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: '${prefix}-apim'
  location: location
  tags: tags
  sku: {
    name: skuName
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    publisherName: publisherName
    publisherEmail: publisherEmail
  }
}

// Named value for prompt flow endpoint
resource namedValueEndpoint 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'prompt-flow-endpoint'
  properties: {
    displayName: 'prompt-flow-endpoint'
    value: promptFlowEndpoint
    secret: false
  }
}

// Named values for OpenAI bearer token → tenant mapping.
// Populated after deployment by scripts/sync-apim-keys.sh which reads
// each product's subscription key and writes it here.
resource namedValueKeyHr 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'openai-key-hr-chatbot'
  properties: {
    displayName: 'openai-key-hr-chatbot'
    value: 'placeholder-hr'
    secret: true
  }
}

resource namedValueKeyLegal 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'openai-key-legal-chatbot'
  properties: {
    displayName: 'openai-key-legal-chatbot'
    value: 'placeholder-legal'
    secret: true
  }
}

resource namedValueKeyExec 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'openai-key-exec-chatbot'
  properties: {
    displayName: 'openai-key-exec-chatbot'
    value: 'placeholder-exec'
    secret: true
  }
}

// Application Insights logger
resource apimLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'app-insights-logger'
  properties: {
    loggerType: 'applicationInsights'
    credentials: {
      instrumentationKey: appInsightsInstrumentationKey
    }
  }
}

// ============================================================================
// API 1: RAG Platform API (subscription key auth)
// ============================================================================

resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'rag-platform-api'
  properties: {
    displayName: 'RAG Platform API'
    path: '/api'
    protocols: ['https']
    subscriptionRequired: true
    subscriptionKeyParameterNames: {
      header: 'Ocp-Apim-Subscription-Key'
      query: 'subscription-key'
    }
  }
}

// POST /chat operation
resource chatOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'chat'
  properties: {
    displayName: 'Chat'
    method: 'POST'
    urlTemplate: '/chat'
  }
}

// Inbound policy for the subscription-key API.
//
// Tenant resolution flow:
//   1. APIM validates subscription key and resolves the Product
//   2. context.Product.Id gives the resource name (e.g. "hr-chatbot")
//   3. Policy injects this as context.app_id in the request body
//   4. Backend uses app_id for:
//      - AI Search filter: search.in(app_scope, '<app_id>')
//      - Cosmos DB config lookup: chatbot-config/<app_id>
resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '''<policies>
    <inbound>
        <base />
        <cors allow-credentials="false">
            <allowed-origins><origin>*</origin></allowed-origins>
            <allowed-methods><method>*</method></allowed-methods>
            <allowed-headers><header>*</header></allowed-headers>
        </cors>
        <rate-limit calls="20" renewal-period="60" />
        <!-- Tenant resolution: Product.Id is the resource name (e.g. "hr-chatbot") -->
        <set-variable name="appScope" value="@(context.Product.Id)" />
        <set-variable name="requestBody" value="@(context.Request.Body.As<JObject>())" />
        <!-- Inject app_id into request body for backend tenant isolation -->
        <set-body>@{
            var body = (JObject)context.Variables["requestBody"];
            var ctx = body["context"] as JObject ?? new JObject();
            ctx["app_id"] = (string)context.Variables["appScope"];
            body["context"] = ctx;
            return body.ToString();
        }</set-body>
        <set-backend-service base-url="{{prompt-flow-endpoint}}" />
    </inbound>
    <backend><base /></backend>
    <outbound><base /></outbound>
    <on-error><base /></on-error>
</policies>'''
  }
  dependsOn: [namedValueEndpoint]
}

// ============================================================================
// API 2: OpenAI-Compatible API (bearer token auth in policy)
//
// Open WebUI / LibreChat send: Authorization: Bearer <key>
// This API has subscriptionRequired=false and validates the bearer token
// manually against known subscription keys stored as named values.
// Demonstrates a second APIM auth pattern alongside built-in subscription keys.
// ============================================================================

resource openaiApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'rag-openai-api'
  properties: {
    displayName: 'RAG OpenAI-Compatible API'
    path: '/v1'
    protocols: ['https']
    subscriptionRequired: false
  }
}

resource openaiChatOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: openaiApi
  name: 'chat-completions'
  properties: {
    displayName: 'Chat Completions'
    method: 'POST'
    urlTemplate: '/chat/completions'
  }
}

resource openaiModelsOperation 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: openaiApi
  name: 'list-models'
  properties: {
    displayName: 'List Models'
    method: 'GET'
    urlTemplate: '/models'
  }
}

// Policy for the OpenAI-compatible API.
//
// Auth flow:
//   1. Extract bearer token from Authorization header, or fall back to
//      Ocp-Apim-Subscription-Key header (LibreChat sends this natively)
//   2. Match token against known subscription keys (stored as named values)
//   3. Map matched key → app_id (tenant identifier)
//   4. Inject app_id into request body context, same as the subscription API
//   5. Return 401 if no key matches
resource openaiApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: openaiApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: '''<policies>
    <inbound>
        <base />
        <cors allow-credentials="false">
            <allowed-origins><origin>*</origin></allowed-origins>
            <allowed-methods><method>*</method></allowed-methods>
            <allowed-headers><header>*</header></allowed-headers>
        </cors>
        <rate-limit calls="20" renewal-period="60" />
        <!-- Extract API key from Authorization: Bearer <key> or Ocp-Apim-Subscription-Key header -->
        <set-variable name="apiKey" value="@{
            string authHeader = context.Request.Headers.GetValueOrDefault("Authorization", "");
            if (authHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase)) {
                return authHeader.Substring(7).Trim();
            }
            return context.Request.Headers.GetValueOrDefault("Ocp-Apim-Subscription-Key", "");
        }" />
        <!-- Match the key against known subscription keys and resolve tenant -->
        <set-variable name="resolvedAppId" value="" />
        <choose>
            <when condition="@((string)context.Variables["apiKey"] == "{{openai-key-hr-chatbot}}")">
                <set-variable name="resolvedAppId" value="hr-chatbot" />
            </when>
            <when condition="@((string)context.Variables["apiKey"] == "{{openai-key-legal-chatbot}}")">
                <set-variable name="resolvedAppId" value="legal-chatbot" />
            </when>
            <when condition="@((string)context.Variables["apiKey"] == "{{openai-key-exec-chatbot}}")">
                <set-variable name="resolvedAppId" value="exec-chatbot" />
            </when>
        </choose>
        <!-- Reject if no tenant matched -->
        <choose>
            <when condition="@(string.IsNullOrEmpty((string)context.Variables["resolvedAppId"]))">
                <return-response>
                    <set-status code="401" reason="Unauthorized" />
                    <set-header name="Content-Type" exists-action="override">
                        <value>application/json</value>
                    </set-header>
                    <set-body>{"error": {"message": "Invalid API key", "type": "invalid_request_error", "code": "invalid_api_key"}}</set-body>
                </return-response>
            </when>
        </choose>
        <!-- Inject app_id into request body (same pattern as subscription API) -->
        <choose>
            <when condition="@(context.Request.Method == "POST")">
                <set-variable name="requestBody" value="@(context.Request.Body.As<JObject>())" />
                <set-body>@{
                    var body = (JObject)context.Variables["requestBody"];
                    var ctx = body["context"] as JObject ?? new JObject();
                    ctx["app_id"] = (string)context.Variables["resolvedAppId"];
                    body["context"] = ctx;
                    return body.ToString();
                }</set-body>
            </when>
        </choose>
        <set-backend-service base-url="{{prompt-flow-endpoint}}/v1" />
    </inbound>
    <backend><base /></backend>
    <outbound><base /></outbound>
    <on-error><base /></on-error>
</policies>'''
  }
  dependsOn: [namedValueEndpoint, namedValueKeyHr, namedValueKeyLegal, namedValueKeyExec]
}

// ============================================================================
// Products — one per tenant chatbot
// ============================================================================

// Product: hr-chatbot
resource hrProduct 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'hr-chatbot'
  properties: {
    displayName: 'HR Chatbot'
    description: 'HR Chatbot product for multi-tenant RAG platform'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

// Product: legal-chatbot
resource legalProduct 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'legal-chatbot'
  properties: {
    displayName: 'Legal Chatbot'
    description: 'Legal Chatbot product for multi-tenant RAG platform'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

// Product: exec-chatbot
resource execProduct 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'exec-chatbot'
  properties: {
    displayName: 'Executive Chatbot'
    description: 'Executive Briefing Chatbot product for multi-tenant RAG platform'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

// Link subscription API to products
resource hrProductApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: hrProduct
  name: api.name
}

resource legalProductApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: legalProduct
  name: api.name
}

resource execProductApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: execProduct
  name: api.name
}

// ============================================================================
// Subscriptions — one per product
// ============================================================================

resource hrSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'hr-chatbot-subscription'
  properties: {
    displayName: 'HR Chatbot Subscription'
    scope: hrProduct.id
    state: 'active'
  }
}

resource legalSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'legal-chatbot-subscription'
  properties: {
    displayName: 'Legal Chatbot Subscription'
    scope: legalProduct.id
    state: 'active'
  }
}

resource execSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'exec-chatbot-subscription'
  properties: {
    displayName: 'Executive Chatbot Subscription'
    scope: execProduct.id
    state: 'active'
  }
}

@description('APIM gateway URL')
output apimGatewayUrl string = apim.properties.gatewayUrl

@description('APIM resource name')
output apimName string = apim.name
