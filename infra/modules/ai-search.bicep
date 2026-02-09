// ============================================================================
// Module: ai-search.bicep
// Description: Azure AI Search with RBAC and system-assigned identity
// ============================================================================

@description('Azure region for resource deployment')
param location string

@description('Naming prefix for resources')
param prefix string

@description('Deployment environment')
@allowed(['dev', 'staging', 'prod'])
param environment string

@description('Principal ID of the platform managed identity')
param identityPrincipalId string

@description('Resource ID of the storage account (for search service blob reader role)')
param storageAccountId string

resource searchService 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: '${prefix}-search'
  location: location
  sku: {
    name: environment == 'prod' ? 'standard' : 'basic'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    semanticSearch: 'standard'
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
  }
}

// Search Index Data Contributor role for platform identity
resource searchIndexDataContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, identityPrincipalId, '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
    principalId: identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Search Service Contributor role for platform identity
resource searchServiceContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(searchService.id, identityPrincipalId, '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
  scope: searchService
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
    principalId: identityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Blob Data Reader role for search service system identity on storage account
resource storageBlobReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountId, searchService.id, '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
    principalId: searchService.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Reference the existing storage account for scoping the role assignment
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: last(split(storageAccountId, '/'))
}

@description('Azure AI Search endpoint URL')
output searchEndpoint string = 'https://${searchService.name}.search.windows.net'

@description('Azure AI Search resource name')
output searchName string = searchService.name

@description('Azure AI Search resource ID')
output searchId string = searchService.id

@description('Azure AI Search admin key')
#disable-next-line outputs-should-not-contain-secrets
output searchAdminKey string = searchService.listAdminKeys().primaryKey
