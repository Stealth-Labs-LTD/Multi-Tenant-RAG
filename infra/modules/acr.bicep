// ============================================================================
// Module: acr.bicep
// Description: Azure Container Registry for container image storage
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

var acrName = replace('${prefix}acr', '-', '')
var skuName = environment == 'dev' ? 'Basic' : 'Standard'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  properties: {
    adminUserEnabled: true
  }
}

@description('ACR resource name')
output acrName string = acr.name

@description('ACR login server')
output acrLoginServer string = acr.properties.loginServer
