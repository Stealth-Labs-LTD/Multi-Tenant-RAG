using '../main.bicep'

param environmentName = 'staging'
param location = 'australiaeast'
param publisherName = 'Staging Team'
param publisherEmail = 'staging@example.com'
param tags = {
  environment: 'staging'
  project: 'multi-tenant-rag'
}
