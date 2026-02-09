using '../main.bicep'

param environmentName = 'prod'
param location = 'australiaeast'
param publisherName = 'Platform Team'
param publisherEmail = 'platform@example.com'
param tags = {
  environment: 'prod'
  project: 'multi-tenant-rag'
}
