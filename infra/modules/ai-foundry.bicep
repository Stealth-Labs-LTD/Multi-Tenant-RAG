// ============================================================================
// Module: ai-foundry.bicep
// Description: Azure AI Foundry Hub, Project, connections, and online endpoint
// ============================================================================

@description('Azure region for resource deployment')
param location string

@description('Naming prefix for resources')
param prefix string

@description('Resource ID of the user-assigned managed identity')
param identityId string

@description('Principal ID of the platform managed identity')
#disable-next-line no-unused-params
param identityPrincipalId string

@description('Azure OpenAI resource name')
param openaiName string

@description('Azure OpenAI endpoint URL')
param openaiEndpoint string

@description('Azure AI Search resource name')
param searchName string

@description('Azure AI Search endpoint URL')
param searchEndpoint string

@description('Key Vault URI')
param keyVaultUri string

@description('Application Insights connection string')
#disable-next-line no-unused-params
param appInsightsConnectionString string

@description('Log Analytics workspace resource ID')
#disable-next-line no-unused-params
param logAnalyticsWorkspaceId string

@description('Tags to apply to resources')
param tags object

// Extract Key Vault name from URI for resource ID construction
var keyVaultName = split(replace(replace(keyVaultUri, 'https://', ''), '/', ''), '.')[0]
var appInsightsName = '${prefix}-appi'
var mlStorageName = replace('${prefix}mlstor', '-', '')

// Separate plain storage account for AI Foundry (HNS not supported)
resource mlStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: mlStorageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

resource hub 'Microsoft.MachineLearningServices/workspaces@2024-10-01' = {
  name: '${prefix}-ai-hub'
  location: location
  tags: tags
  kind: 'Hub'
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    friendlyName: '${prefix} AI Foundry Hub'
    storageAccount: mlStorage.id
    keyVault: resourceId('Microsoft.KeyVault/vaults', keyVaultName)
    applicationInsights: resourceId('Microsoft.Insights/components', appInsightsName)
    publicNetworkAccess: 'Enabled'
  }
}

resource project 'Microsoft.MachineLearningServices/workspaces@2024-10-01' = {
  name: '${prefix}-ai-project'
  location: location
  tags: tags
  kind: 'Project'
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    friendlyName: '${prefix} AI Foundry Project'
    hubResourceId: hub.id
  }
}

// Azure OpenAI connection on the hub
resource openaiConnection 'Microsoft.MachineLearningServices/workspaces/connections@2024-10-01' = {
  parent: hub
  name: 'aoai-connection'
  properties: {
    category: 'AzureOpenAI'
    target: openaiEndpoint
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: resourceId('Microsoft.CognitiveServices/accounts', openaiName)
    }
  }
}

// AI Search connection on the hub
resource searchConnection 'Microsoft.MachineLearningServices/workspaces/connections@2024-10-01' = {
  parent: hub
  name: 'search-connection'
  properties: {
    category: 'CognitiveSearch'
    target: searchEndpoint
    authType: 'AAD'
    metadata: {
      ResourceId: resourceId('Microsoft.Search/searchServices', searchName)
    }
  }
}

// NOTE: Managed online endpoint is created via scripts/deploy-promptflow.sh
// Bicep cannot deploy a model into it, so it's better managed via az ml CLI.

@description('AI Foundry Hub name')
output hubName string = hub.name

@description('AI Foundry Project name')
output projectName string = project.name

@description('Endpoint name convention for use by deploy script')
output endpointName string = '${prefix}-endpoint'

@description('Scoring URI placeholder - set after Prompt Flow deployment')
output scoringUri string = 'https://${prefix}-endpoint.uksouth.inference.ml.azure.com/score'
