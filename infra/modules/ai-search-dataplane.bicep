// ============================================================================
// Module: ai-search-dataplane.bicep
// Description: AI Search data-plane resources via deployment script (REST API)
//              Creates data source, skillset, index, and indexer
// ============================================================================

@description('Azure region for resource deployment')
param location string

@description('Azure AI Search endpoint URL')
param searchEndpoint string

@description('Azure AI Search resource name')
param searchName string

@description('Azure AI Search admin key')
@secure()
param searchAdminKey string

@description('Azure OpenAI endpoint URL')
param openaiEndpoint string

@description('Azure OpenAI resource name')
#disable-next-line no-unused-params
param openaiName string

@description('Embedding model deployment name')
param embeddingDeploymentName string

@description('Storage account name')
param storageAccountName string

@description('Documents blob container name')
param documentsContainerName string

@description('Resource ID of the user-assigned managed identity for the deployment script')
param identityId string

@description('Tags to apply to resources')
param tags object

@description('Subscription ID for resource ID construction')
param subscriptionId string

@description('Resource group name for resource ID construction')
param resourceGroupName string

var searchApiVersion = '2024-07-01'
var dataSourceName = 'documents-datasource'
var skillsetName = 'documents-skillset'
var indexName = 'documents-index'
var indexerName = 'documents-indexer'
var storageResourceId = '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroupName}/providers/Microsoft.Storage/storageAccounts/${storageAccountName}'

resource deploymentScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${searchName}-dataplane-setup'
  location: location
  tags: tags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    azCliVersion: '2.52.0'
    retentionInterval: 'PT1H'
    timeout: 'PT30M'
    cleanupPreference: 'OnSuccess'
    environmentVariables: [
      { name: 'SEARCH_ENDPOINT', value: searchEndpoint }
      { name: 'SEARCH_ADMIN_KEY', secureValue: searchAdminKey }
      { name: 'SEARCH_API_VERSION', value: searchApiVersion }
      { name: 'OPENAI_ENDPOINT', value: openaiEndpoint }
      { name: 'EMBEDDING_DEPLOYMENT', value: embeddingDeploymentName }
      { name: 'STORAGE_RESOURCE_ID', value: storageResourceId }
      { name: 'CONTAINER_NAME', value: documentsContainerName }
      { name: 'DATASOURCE_NAME', value: dataSourceName }
      { name: 'SKILLSET_NAME', value: skillsetName }
      { name: 'INDEX_NAME', value: indexName }
      { name: 'INDEXER_NAME', value: indexerName }
    ]
    scriptContent: '''
      #!/bin/bash
      set -e

      api_call() {
        local method=$1 path=$2 body=$3
        local url="${SEARCH_ENDPOINT}${path}?api-version=${SEARCH_API_VERSION}"
        local status
        status=$(curl -s -w "%{http_code}" -o /tmp/response.json -X "$method" "$url" \
          -H "Content-Type: application/json" -H "api-key: ${SEARCH_ADMIN_KEY}" \
          ${body:+-d "$body"})
        echo "  HTTP $status"
        if [ "$status" -ge 400 ]; then
          cat /tmp/response.json
          echo ""
        fi
      }

      echo "=== Creating data source ==="
      api_call PUT "/datasources/${DATASOURCE_NAME}" '{
        "name": "'"${DATASOURCE_NAME}"'",
        "type": "azureblob",
        "credentials": {
          "connectionString": "ResourceId='"${STORAGE_RESOURCE_ID}"';"
        },
        "container": { "name": "'"${CONTAINER_NAME}"'" },
        "identity": null
      }'

      echo "=== Creating index ==="
      api_call PUT "/indexes/${INDEX_NAME}" '{
        "name": "'"${INDEX_NAME}"'",
        "fields": [
          { "name": "chunk_id", "type": "Edm.String", "key": true, "filterable": true, "sortable": false, "searchable": true, "analyzer": "keyword" },
          { "name": "parent_id", "type": "Edm.String", "filterable": true, "sortable": false, "searchable": false },
          { "name": "title", "type": "Edm.String", "searchable": true, "filterable": false, "retrievable": true },
          { "name": "chunk", "type": "Edm.String", "searchable": true, "filterable": false, "retrievable": true },
          { "name": "text_vector", "type": "Collection(Edm.Single)", "searchable": true, "retrievable": false, "dimensions": 3072, "vectorSearchProfile": "default-vector-profile" },
          { "name": "source_file", "type": "Edm.String", "searchable": false, "filterable": true, "retrievable": true },
          { "name": "app_scope", "type": "Edm.String", "filterable": true, "retrievable": false, "searchable": false }
        ],
        "vectorSearch": {
          "algorithms": [{ "name": "default-hnsw", "kind": "hnsw", "hnswParameters": { "metric": "cosine", "m": 4, "efConstruction": 400, "efSearch": 500 } }],
          "profiles": [{ "name": "default-vector-profile", "algorithm": "default-hnsw" }]
        },
        "semantic": {
          "configurations": [{
            "name": "default-semantic-config",
            "prioritizedFields": {
              "prioritizedContentFields": [{ "fieldName": "chunk" }],
              "titleField": { "fieldName": "title" }
            }
          }]
        }
      }'

      echo "=== Creating skillset ==="
      api_call PUT "/skillsets/${SKILLSET_NAME}" '{
        "name": "'"${SKILLSET_NAME}"'",
        "description": "Skillset for chunking and vectorizing documents",
        "skills": [
          {
            "@odata.type": "#Microsoft.Skills.Text.SplitSkill",
            "name": "split-skill",
            "context": "/document",
            "inputs": [{ "name": "text", "source": "/document/content" }],
            "outputs": [{ "name": "textItems", "targetName": "chunks" }],
            "textSplitMode": "pages",
            "maximumPageLength": 2000,
            "pageOverlapLength": 500
          },
          {
            "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
            "name": "embedding-skill",
            "context": "/document/chunks/*",
            "inputs": [{ "name": "text", "source": "/document/chunks/*" }],
            "outputs": [{ "name": "embedding", "targetName": "text_vector" }],
            "resourceUri": "'"${OPENAI_ENDPOINT}"'",
            "deploymentId": "'"${EMBEDDING_DEPLOYMENT}"'",
            "modelName": "text-embedding-3-large",
            "authIdentity": null
          }
        ],
        "indexProjections": {
          "selectors": [{
            "targetIndexName": "'"${INDEX_NAME}"'",
            "parentKeyFieldName": "parent_id",
            "sourceContext": "/document/chunks/*",
            "mappings": [
              { "name": "chunk", "source": "/document/chunks/*" },
              { "name": "text_vector", "source": "/document/chunks/*/text_vector" },
              { "name": "title", "source": "/document/metadata_storage_name" },
              { "name": "source_file", "source": "/document/metadata_storage_path" },
              { "name": "app_scope", "source": "/document/app_scope" }
            ]
          }],
          "parameters": { "projectionMode": "skipIndexingParentDocuments" }
        }
      }'

      echo "=== Creating indexer ==="
      api_call PUT "/indexers/${INDEXER_NAME}" '{
        "name": "'"${INDEXER_NAME}"'",
        "dataSourceName": "'"${DATASOURCE_NAME}"'",
        "targetIndexName": "'"${INDEX_NAME}"'",
        "skillsetName": "'"${SKILLSET_NAME}"'",
        "schedule": { "interval": "PT5M" },
        "parameters": {
          "configuration": {
            "dataToExtract": "contentAndMetadata",
            "parsingMode": "default",
            "imageAction": "none"
          }
        },
        "fieldMappings": [
          { "sourceFieldName": "metadata_storage_path", "targetFieldName": "chunk_id", "mappingFunction": { "name": "base64Encode" } }
        ]
      }'

      echo "=== All AI Search data-plane resources created ==="
    '''
  }
}
