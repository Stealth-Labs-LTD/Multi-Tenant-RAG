// ============================================================================
// Module: apim.bicep
// Description: Azure API Management with multi-tenant RAG policies
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

// API definition
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

// Inbound policy for the API
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
        <set-variable name="appScope" value="@(context.Product.Name)" />
        <set-variable name="requestBody" value="@(context.Request.Body.As<JObject>())" />
        <set-body>@{
            var body = (JObject)context.Variables["requestBody"];
            body["filter"] = $"app_scope/any(s: search.in(s, '{(string)context.Variables["appScope"]}'))";
            body["app_id"] = (string)context.Variables["appScope"];
            return body.ToString();
        }</set-body>
        <set-header name="Authorization" exists-action="override">
            <value>@("Bearer " + context.Request.Headers.GetValueOrDefault("Authorization",""))</value>
        </set-header>
        <set-backend-service base-url="{{prompt-flow-endpoint}}" />
    </inbound>
    <backend><base /></backend>
    <outbound><base /></outbound>
    <on-error><base /></on-error>
</policies>'''
  }
  dependsOn: [namedValueEndpoint]
}

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

// Link API to products
resource hrProductApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: hrProduct
  name: api.name
}

resource legalProductApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: legalProduct
  name: api.name
}

// Subscription for hr-chatbot product
resource hrSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'hr-chatbot-subscription'
  properties: {
    displayName: 'HR Chatbot Subscription'
    scope: hrProduct.id
    state: 'active'
  }
}

// Subscription for legal-chatbot product
resource legalSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'legal-chatbot-subscription'
  properties: {
    displayName: 'Legal Chatbot Subscription'
    scope: legalProduct.id
    state: 'active'
  }
}

@description('APIM gateway URL')
output apimGatewayUrl string = apim.properties.gatewayUrl

@description('APIM resource name')
output apimName string = apim.name
