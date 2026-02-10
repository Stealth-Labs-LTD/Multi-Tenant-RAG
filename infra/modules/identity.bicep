// ============================================================================
// Module: identity.bicep
// Description: User-assigned managed identity for the RAG platform
// ============================================================================

@description('Azure region for resource deployment')
param location string

@description('Naming prefix for resources')
param prefix string

@description('Tags to apply to resources')
param tags object

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-identity'
  location: location
  tags: tags
}

@description('Resource ID of the managed identity')
output identityId string = managedIdentity.id

@description('Principal ID of the managed identity')
output identityPrincipalId string = managedIdentity.properties.principalId

@description('Client ID of the managed identity')
output identityClientId string = managedIdentity.properties.clientId

@description('Name of the managed identity')
output identityName string = managedIdentity.name
