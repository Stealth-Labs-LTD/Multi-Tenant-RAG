// ============================================================================
// Module: monitoring.bicep
// Description: Log Analytics workspace and Application Insights
// ============================================================================

@description('Azure region for resource deployment')
param location string

@description('Naming prefix for resources')
param prefix string

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-log'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${prefix}-appi'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

@description('Application Insights connection string')
output appInsightsConnectionString string = appInsights.properties.ConnectionString

@description('Application Insights instrumentation key')
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey

@description('Log Analytics workspace resource ID')
output logAnalyticsWorkspaceId string = logAnalytics.id

@description('Log Analytics workspace name')
output logAnalyticsWorkspaceName string = logAnalytics.name
