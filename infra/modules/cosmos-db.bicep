// ============================================================================
// Module: cosmos-db.bicep
// Description: Azure Cosmos DB with serverless/provisioned modes and containers
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

@description('Tags to apply to resources')
param tags object

var isProduction = environment == 'prod'
var databaseName = 'rag-platform'

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: '${prefix}-cosmos'
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    capabilities: isProduction ? [] : [
      {
        name: 'EnableServerless'
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
  }
}

resource database 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: cosmosAccount
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
  }
}

resource chatHistoryContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: database
  name: 'chat-history'
  properties: {
    resource: {
      id: 'chat-history'
      partitionKey: {
        paths: ['/sessionId']
        kind: 'Hash'
      }
      defaultTtl: 2592000
      indexingPolicy: {
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/chatbotId/?' }
          { path: '/userId/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
      }
    }
    options: isProduction ? {
      autoscaleSettings: {
        maxThroughput: 1000
      }
    } : {}
  }
}

resource chatbotConfigContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: database
  name: 'chatbot-config'
  properties: {
    resource: {
      id: 'chatbot-config'
      partitionKey: {
        paths: ['/chatbotId']
        kind: 'Hash'
      }
      indexingPolicy: {
        indexingMode: 'consistent'
        includedPaths: [
          { path: '/chatbotId/?' }
        ]
        excludedPaths: [
          { path: '/*' }
        ]
      }
    }
    options: isProduction ? {
      autoscaleSettings: {
        maxThroughput: 1000
      }
    } : {}
  }
}

resource usageAnalyticsContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: database
  name: 'usage-analytics'
  properties: {
    resource: {
      id: 'usage-analytics'
      partitionKey: {
        paths: ['/chatbotId']
        kind: 'Hash'
      }
      defaultTtl: 7776000
    }
    options: isProduction ? {
      autoscaleSettings: {
        maxThroughput: 1000
      }
    } : {}
  }
}

// Cosmos DB Built-in Data Contributor role assignment
resource cosmosRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmosAccount
  name: guid(cosmosAccount.id, identityPrincipalId, '00000000-0000-0000-0000-000000000002')
  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    principalId: identityPrincipalId
    scope: cosmosAccount.id
  }
}

@description('Azure Cosmos DB endpoint URL')
output cosmosEndpoint string = cosmosAccount.properties.documentEndpoint

@description('Azure Cosmos DB account name')
output cosmosAccountName string = cosmosAccount.name

@description('Cosmos DB database name')
output databaseName string = databaseName
