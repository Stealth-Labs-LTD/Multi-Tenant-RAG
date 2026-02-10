// ============================================================================
// Module: openai.bicep
// Description: Azure OpenAI service with GPT-4o and embedding model deployments
// ============================================================================

@description('Azure region for resource deployment')
param location string

@description('Naming prefix for resources')
param prefix string

@description('Resource ID of the user-assigned managed identity')
param identityId string

@description('Tags to apply to resources')
param tags object

var models = [
  {
    name: 'gpt-4o'
    model: 'gpt-4o'
    version: '2024-08-06'
    skuName: 'GlobalStandard'
    capacity: 30
  }
  {
    name: 'text-embedding-3-large'
    model: 'text-embedding-3-large'
    version: '1'
    skuName: 'Standard'
    capacity: 120
  }
]

resource openai 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: '${prefix}-openai'
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    customSubDomainName: '${prefix}-openai'
    publicNetworkAccess: 'Enabled'
  }
}

@batchSize(1)
resource deployments 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = [
  for model in models: {
    parent: openai
    name: model.name
    sku: {
      name: model.skuName
      capacity: model.capacity
    }
    properties: {
      model: {
        format: 'OpenAI'
        name: model.model
        version: model.version
      }
    }
  }
]

@description('Azure OpenAI endpoint URL')
output openaiEndpoint string = openai.properties.endpoint

@description('Azure OpenAI resource name')
output openaiName string = openai.name

@description('GPT-4o deployment name')
output gpt4oDeploymentName string = models[0].name

@description('Embedding model deployment name')
output embeddingDeploymentName string = models[1].name
