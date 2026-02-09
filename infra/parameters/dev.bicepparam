using '../main.bicep'

param environmentName = 'dev'
param location = 'australiaeast'
param publisherName = 'Dev Team'
param publisherEmail = 'dev@example.com'
param tags = {
  environment: 'dev'
  project: 'multi-tenant-rag'
}
