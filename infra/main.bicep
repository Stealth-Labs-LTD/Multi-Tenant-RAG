// ============================================================================
// Main Bicep orchestration for Multi-Tenant RAG Platform
// ============================================================================

targetScope = 'subscription'

@description('Deployment environment')
@allowed(['dev', 'staging', 'prod'])
param environmentName string

@description('Azure region for all resources')
param location string

@description('Publisher name for API Management')
param publisherName string

@description('Publisher email for API Management')
param publisherEmail string

@description('Tags to apply to all resources')
param tags object = {}

var prefix = 'rag-${environmentName}'

// Resource Group
resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${prefix}'
  location: location
  tags: tags
}

// 1. Identity (no deps)
module identity 'modules/identity.bicep' = {
  name: 'identity-deployment'
  scope: rg
  params: {
    location: location
    prefix: prefix
  }
}

// 2. Monitoring (no deps)
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring-deployment'
  scope: rg
  params: {
    location: location
    prefix: prefix
  }
}

// 3. OpenAI (depends on identity)
module openai 'modules/openai.bicep' = {
  name: 'openai-deployment'
  scope: rg
  params: {
    location: location
    prefix: prefix
    identityId: identity.outputs.identityId
  }
}

// 4. Storage (depends on identity)
module storage 'modules/storage.bicep' = {
  name: 'storage-deployment'
  scope: rg
  params: {
    location: location
    prefix: prefix
    identityPrincipalId: identity.outputs.identityPrincipalId
    environment: environmentName
  }
}

// 5. Key Vault (depends on identity)
module keyvault 'modules/keyvault.bicep' = {
  name: 'keyvault-deployment'
  scope: rg
  params: {
    location: location
    prefix: prefix
    identityPrincipalId: identity.outputs.identityPrincipalId
  }
}

// 6. AI Search (depends on identity, storage)
module aiSearch 'modules/ai-search.bicep' = {
  name: 'ai-search-deployment'
  scope: rg
  params: {
    location: location
    prefix: prefix
    environment: environmentName
    identityPrincipalId: identity.outputs.identityPrincipalId
    storageAccountId: storage.outputs.storageAccountId
  }
}

// 7. Cosmos DB (depends on identity)
module cosmosDb 'modules/cosmos-db.bicep' = {
  name: 'cosmos-db-deployment'
  scope: rg
  params: {
    location: location
    prefix: prefix
    environment: environmentName
    identityPrincipalId: identity.outputs.identityPrincipalId
  }
}

// 8. AI Foundry (depends on identity, openai, storage, keyvault, monitoring, ai-search)
module aiFoundry 'modules/ai-foundry.bicep' = {
  name: 'ai-foundry-deployment'
  scope: rg
  params: {
    location: location
    prefix: prefix
    identityId: identity.outputs.identityId
    identityPrincipalId: identity.outputs.identityPrincipalId
    openaiName: openai.outputs.openaiName
    openaiEndpoint: openai.outputs.openaiEndpoint
    searchName: aiSearch.outputs.searchName
    searchEndpoint: aiSearch.outputs.searchEndpoint
    storageAccountId: storage.outputs.storageAccountId
    keyVaultUri: keyvault.outputs.keyVaultUri
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

// 9. APIM (depends on identity, keyvault, ai-foundry, monitoring)
module apim 'modules/apim.bicep' = {
  name: 'apim-deployment'
  scope: rg
  params: {
    location: location
    prefix: prefix
    environment: environmentName
    identityId: identity.outputs.identityId
    identityClientId: identity.outputs.identityClientId
    keyVaultUri: keyvault.outputs.keyVaultUri
    appInsightsInstrumentationKey: monitoring.outputs.appInsightsInstrumentationKey
    promptFlowEndpoint: aiFoundry.outputs.scoringUri
    publisherName: publisherName
    publisherEmail: publisherEmail
  }
}

// 10. AI Search Data-Plane (depends on ai-search, openai, storage) - last
module aiSearchDataplane 'modules/ai-search-dataplane.bicep' = {
  name: 'ai-search-dataplane-deployment'
  scope: rg
  params: {
    location: location
    searchEndpoint: aiSearch.outputs.searchEndpoint
    searchName: aiSearch.outputs.searchName
    searchAdminKey: aiSearch.outputs.searchAdminKey
    openaiEndpoint: openai.outputs.openaiEndpoint
    openaiName: openai.outputs.openaiName
    embeddingDeploymentName: openai.outputs.embeddingDeploymentName
    storageAccountName: storage.outputs.storageAccountName
    documentsContainerName: storage.outputs.documentsContainerName
    identityId: identity.outputs.identityId
  }
}
