// ============================================================================
// Module: container-apps.bicep
// Description: Container Apps Environment + all 3 Container Apps
//
// Apps:
//   1. rag-app       — Python Quart backend (RAG platform API)
//   2. open-webui    — Open WebUI (Executive Briefing chatbot)
//   3. librechat     — LibreChat (Legal chatbot) with MongoDB sidecar
// ============================================================================

@description('Azure region for resource deployment')
param location string

@description('Naming prefix for resources')
param prefix string

@description('Deployment environment')
@allowed(['dev', 'staging', 'prod'])
param environment string

@description('Tags to apply to resources')
param tags object

@description('Resource ID of the user-assigned managed identity')
param identityId string

@description('Client ID of the user-assigned managed identity')
param identityClientId string

@description('ACR resource name')
param acrName string

@description('ACR login server')
param acrLoginServer string

@description('Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Azure OpenAI endpoint')
param openaiEndpoint string

@description('Azure AI Search endpoint')
param searchEndpoint string

@description('Cosmos DB endpoint')
param cosmosEndpoint string

@description('APIM gateway URL')
param apimGatewayUrl string

@description('OpenAI chat deployment name')
param openaiDeploymentName string

// Deterministic secrets from uniqueString (stable across redeploys, unique per env)
var jwtSecret = uniqueString(resourceGroup().id, 'jwt-secret', environment)
var jwtRefreshSecret = uniqueString(resourceGroup().id, 'jwt-refresh', environment)
var credsKey = uniqueString(resourceGroup().id, 'creds-key', environment)
var credsIv = uniqueString(resourceGroup().id, 'creds-iv', environment)

// Get ACR credentials for image pull
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// Log Analytics workspace reference for environment
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: last(split(logAnalyticsWorkspaceId, '/'))
}

// ============================================================================
// Container Apps Environment
// ============================================================================

resource containerAppEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${prefix}-env'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// ============================================================================
// Container App: rag-app (backend)
// ============================================================================

resource ragApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'rag-app'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
      }
      registries: [
        {
          server: acrLoginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'rag-app'
          image: '${acrLoginServer}/rag-platform:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'AZURE_OPENAI_ENDPOINT', value: openaiEndpoint }
            { name: 'AZURE_SEARCH_ENDPOINT', value: searchEndpoint }
            { name: 'AZURE_SEARCH_INDEX', value: 'documents-index' }
            { name: 'COSMOS_ENDPOINT', value: cosmosEndpoint }
            { name: 'COSMOS_DATABASE', value: 'rag-platform' }
            { name: 'AZURE_OPENAI_DEPLOYMENT', value: openaiDeploymentName }
            { name: 'AZURE_CLIENT_ID', value: identityClientId }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

// ============================================================================
// Container App: open-webui (Executive Briefing chatbot)
// ============================================================================

resource openWebui 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'open-webui'
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
      }
    }
    template: {
      containers: [
        {
          name: 'open-webui'
          image: 'ghcr.io/open-webui/open-webui:main'
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
          env: [
            { name: 'OPENAI_API_BASE_URL', value: '${apimGatewayUrl}/v1' }
            { name: 'OPENAI_API_KEY', value: 'placeholder' }
            { name: 'ENABLE_OLLAMA_API', value: 'false' }
            { name: 'WEBUI_AUTH', value: 'true' }
            { name: 'WEBUI_NAME', value: 'Executive Briefing' }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// ============================================================================
// Container App: librechat (Legal chatbot) with MongoDB sidecar
// ============================================================================

resource librechat 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'librechat'
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 3080
      }
      registries: [
        {
          server: acrLoginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'acr-password'
        }
      ]
      secrets: [
        {
          name: 'acr-password'
          value: acr.listCredentials().passwords[0].value
        }
      ]
    }
    template: {
      volumes: [
        {
          name: 'mongo-data'
          storageType: 'EmptyDir'
        }
      ]
      containers: [
        {
          name: 'librechat'
          image: '${acrLoginServer}/librechat-rag:latest'
          resources: {
            cpu: json('0.75')
            memory: '1.5Gi'
          }
          env: [
            { name: 'MONGO_URI', value: 'mongodb://localhost:27017/librechat' }
            { name: 'APIM_SUBSCRIPTION_KEY', value: 'placeholder' }
            { name: 'CREDS_KEY', value: credsKey }
            { name: 'CREDS_IV', value: credsIv }
            { name: 'JWT_SECRET', value: jwtSecret }
            { name: 'JWT_REFRESH_SECRET', value: jwtRefreshSecret }
            // DOMAIN_SERVER and DOMAIN_CLIENT set post-deploy via sync-apim-keys.sh
            // (cannot self-reference the FQDN during resource creation)
            { name: 'NO_INDEX', value: 'true' }
          ]
        }
        {
          name: 'mongo'
          image: 'mongo:7'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          volumeMounts: [
            {
              volumeName: 'mongo-data'
              mountPath: '/data/db'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

@description('RAG app FQDN')
output ragAppFqdn string = ragApp.properties.configuration.ingress.fqdn

@description('Open WebUI FQDN')
output openWebuiFqdn string = openWebui.properties.configuration.ingress.fqdn

@description('LibreChat FQDN')
output librechatFqdn string = librechat.properties.configuration.ingress.fqdn
