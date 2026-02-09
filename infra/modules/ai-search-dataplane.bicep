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
param openaiName string

@description('Embedding model deployment name')
param embeddingDeploymentName string

@description('Storage account name')
param storageAccountName string

@description('Documents blob container name')
param documentsContainerName string

@description('Resource ID of the user-assigned managed identity for the deployment script')
param identityId string

var searchApiVersion = '2024-07-01'
var dataSourceName = 'documents-datasource'
var skillsetName = 'documents-skillset'
var indexName = 'documents-index'
var indexerName = 'documents-indexer'

resource deploymentScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${searchName}-dataplane-setup'
  location: location
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
      { name: 'OPENAI_NAME', value: openaiName }
      { name: 'EMBEDDING_DEPLOYMENT', value: embeddingDeploymentName }
      { name: 'STORAGE_ACCOUNT', value: storageAccountName }
      { name: 'CONTAINER_NAME', value: documentsContainerName }
      { name: 'DATASOURCE_NAME', value: dataSourceName }
      { name: 'SKILLSET_NAME', value: skillsetName }
      { name: 'INDEX_NAME', value: indexName }
      { name: 'INDEXER_NAME', value: indexerName }
    ]
    scriptContent: '''
      #!/bin/bash
      set -e

      HEADERS="Content-Type: application/json
      api-key: $SEARCH_ADMIN_KEY"

      # ---- Data Source ----
      echo "Creating data source..."
      curl -s -X PUT "$SEARCH_ENDPOINT/datasources/$DATASOURCE_NAME?api-version=$SEARCH_API_VERSION" \
        -H "Content-Type: application/json" \
        -H "api-key: $SEARCH_ADMIN_KEY" \
        -d '{
          "name": "'"$DATASOURCE_NAME"'",
          "type": "azureblob",
          "credentials": {
            "connectionString": "ResourceId=/subscriptions/'$(az account show --query id -o tsv)'/resourceGroups/'$(az group list --query "[?contains(name, '\'rag-\'')].name | [0]" -o tsv)'/providers/Microsoft.Storage/storageAccounts/'"$STORAGE_ACCOUNT"';"
          },
          "container": {
            "name": "'"$CONTAINER_NAME"'"
          },
          "identity": {
            "@odata.type": "#Microsoft.Azure.Search.DataUserAssignedIdentity",
            "userAssignedIdentity": ""
          }
        }' || true

      # Use managed identity for the data source (system-assigned on search service)
      curl -s -X PUT "$SEARCH_ENDPOINT/datasources/$DATASOURCE_NAME?api-version=$SEARCH_API_VERSION" \
        -H "Content-Type: application/json" \
        -H "api-key: $SEARCH_ADMIN_KEY" \
        -d '{
          "name": "'"$DATASOURCE_NAME"'",
          "type": "azureblob",
          "credentials": {
            "connectionString": "ResourceId=/subscriptions/'$(az account show --query id -o tsv)'/resourceGroups/'$(az group list --query "[?contains(name, '\'rag-\'')].name | [0]" -o tsv)'/providers/Microsoft.Storage/storageAccounts/'"$STORAGE_ACCOUNT"';"
          },
          "container": {
            "name": "'"$CONTAINER_NAME"'"
          },
          "identity": null
        }'
      echo "Data source created."

      # ---- Skillset ----
      echo "Creating skillset..."
      curl -s -X PUT "$SEARCH_ENDPOINT/skillsets/$SKILLSET_NAME?api-version=$SEARCH_API_VERSION" \
        -H "Content-Type: application/json" \
        -H "api-key: $SEARCH_ADMIN_KEY" \
        -d '{
          "name": "'"$SKILLSET_NAME"'",
          "skills": [
            {
              "@odata.type": "#Microsoft.Skills.Text.SplitSkill",
              "name": "split-skill",
              "description": "Split documents into chunks",
              "context": "/document",
              "textSplitMode": "pages",
              "maximumPageLength": 2000,
              "pageOverlapLength": 500,
              "inputs": [
                { "name": "text", "source": "/document/content" }
              ],
              "outputs": [
                { "name": "textItems", "targetName": "pages" }
              ]
            },
            {
              "@odata.type": "#Microsoft.Skills.Custom.AzureOpenAIEmbeddingSkill",
              "name": "embedding-skill",
              "description": "Generate embeddings",
              "context": "/document/pages/*",
              "resourceUri": "'"$OPENAI_ENDPOINT"'",
              "deploymentId": "'"$EMBEDDING_DEPLOYMENT"'",
              "modelName": "text-embedding-3-large",
              "inputs": [
                { "name": "text", "source": "/document/pages/*" }
              ],
              "outputs": [
                { "name": "embedding", "targetName": "text_vector" }
              ]
            }
          ],
          "indexProjections": {
            "selectors": [
              {
                "targetIndexName": "'"$INDEX_NAME"'",
                "parentKeyFieldName": "parent_id",
                "sourceContext": "/document/pages/*",
                "mappings": [
                  { "name": "chunk", "source": "/document/pages/*" },
                  { "name": "text_vector", "source": "/document/pages/*/text_vector" },
                  { "name": "title", "source": "/document/metadata_storage_name" }
                ]
              }
            ],
            "parameters": {
              "projectionMode": "generatedKeyAsId"
            }
          }
        }'
      echo "Skillset created."

      # ---- Index ----
      echo "Creating index..."
      curl -s -X PUT "$SEARCH_ENDPOINT/indexes/$INDEX_NAME?api-version=$SEARCH_API_VERSION" \
        -H "Content-Type: application/json" \
        -H "api-key: $SEARCH_ADMIN_KEY" \
        -d '{
          "name": "'"$INDEX_NAME"'",
          "fields": [
            { "name": "chunk_id", "type": "Edm.String", "key": true, "searchable": true, "filterable": true, "sortable": false, "facetable": false, "retrievable": true },
            { "name": "parent_id", "type": "Edm.String", "searchable": true, "filterable": true, "sortable": false, "facetable": false, "retrievable": true },
            { "name": "title", "type": "Edm.String", "searchable": true, "filterable": false, "sortable": false, "facetable": false, "retrievable": true },
            { "name": "chunk", "type": "Edm.String", "searchable": true, "filterable": false, "sortable": false, "facetable": false, "retrievable": true },
            { "name": "text_vector", "type": "Collection(Edm.Single)", "searchable": true, "filterable": false, "sortable": false, "facetable": false, "retrievable": false, "dimensions": 3072, "vectorSearchProfile": "hnsw-profile" },
            { "name": "source_file", "type": "Edm.String", "searchable": false, "filterable": true, "sortable": false, "facetable": false, "retrievable": true },
            { "name": "app_scope", "type": "Collection(Edm.String)", "searchable": false, "filterable": true, "sortable": false, "facetable": false, "retrievable": false }
          ],
          "vectorSearch": {
            "algorithms": [
              {
                "name": "hnsw-algorithm",
                "kind": "hnsw",
                "hnswParameters": {
                  "metric": "cosine",
                  "m": 4,
                  "efConstruction": 400,
                  "efSearch": 500
                }
              }
            ],
            "vectorizers": [
              {
                "name": "openai-vectorizer",
                "kind": "azureOpenAI",
                "azureOpenAIParameters": {
                  "resourceUri": "'"$OPENAI_ENDPOINT"'",
                  "deploymentId": "'"$EMBEDDING_DEPLOYMENT"'",
                  "modelName": "text-embedding-3-large"
                }
              }
            ],
            "profiles": [
              {
                "name": "hnsw-profile",
                "algorithm": "hnsw-algorithm",
                "vectorizer": "openai-vectorizer"
              }
            ]
          },
          "semantic": {
            "defaultConfiguration": "default-semantic-config",
            "configurations": [
              {
                "name": "default-semantic-config",
                "prioritizedFields": {
                  "titleField": { "fieldName": "title" },
                  "contentFields": [
                    { "fieldName": "chunk" }
                  ]
                }
              }
            ]
          }
        }'
      echo "Index created."

      # ---- Indexer ----
      echo "Creating indexer..."
      curl -s -X PUT "$SEARCH_ENDPOINT/indexers/$INDEXER_NAME?api-version=$SEARCH_API_VERSION" \
        -H "Content-Type: application/json" \
        -H "api-key: $SEARCH_ADMIN_KEY" \
        -d '{
          "name": "'"$INDEXER_NAME"'",
          "dataSourceName": "'"$DATASOURCE_NAME"'",
          "skillsetName": "'"$SKILLSET_NAME"'",
          "targetIndexName": "'"$INDEX_NAME"'",
          "schedule": {
            "interval": "PT5M"
          },
          "fieldMappings": [
            { "sourceFieldName": "metadata_storage_path", "targetFieldName": "parent_id", "mappingFunction": { "name": "base64Encode" } },
            { "sourceFieldName": "metadata_storage_name", "targetFieldName": "title" }
          ],
          "outputFieldMappings": [
            { "sourceFieldName": "/document/pages/*/text_vector", "targetFieldName": "text_vector" },
            { "sourceFieldName": "/document/pages/*", "targetFieldName": "chunk" }
          ],
          "parameters": {
            "configuration": {
              "dataToExtract": "contentAndMetadata",
              "parsingMode": "default"
            }
          }
        }'
      echo "Indexer created."
      echo "All AI Search data-plane resources created successfully."
    '''
  }
}
