#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Upload sample documents to Azure Blob Storage and trigger AI Search indexer.
#
# Usage:
#   ./scripts/upload-sample-docs.sh \
#     --storage-account <account-name> \
#     [--container <container-name>] \
#     [--search-endpoint <endpoint-url>] \
#     [--index-name <index-name>]
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - Storage Blob Data Contributor role on the storage account
#   - Search Service Contributor role on the AI Search service (for indexer trigger)
###############################################################################

usage() {
    cat <<EOF
Usage: $0 --storage-account <account-name> [options]

Required arguments:
  --storage-account, -s    Azure Storage account name

Optional arguments:
  --container, -c          Blob container name (default: documents)
  --search-endpoint, -e    Azure AI Search endpoint URL (to trigger indexer)
  --index-name, -i         AI Search index name (default: documents-index)

Examples:
  $0 --storage-account ragdevstor
  $0 -s ragdevstor -e https://rag-dev-search.search.windows.net -i documents-index
EOF
    exit 1
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
STORAGE_ACCOUNT=""
CONTAINER_NAME="documents"
SEARCH_ENDPOINT=""
INDEX_NAME="documents-index"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --storage-account|-s)
            STORAGE_ACCOUNT="$2"; shift 2 ;;
        --container|-c)
            CONTAINER_NAME="$2"; shift 2 ;;
        --search-endpoint|-e)
            SEARCH_ENDPOINT="$2"; shift 2 ;;
        --index-name|-i)
            INDEX_NAME="$2"; shift 2 ;;
        -h|--help)
            usage ;;
        *)
            echo "Error: Unknown argument '$1'"
            usage ;;
    esac
done

if [[ -z "$STORAGE_ACCOUNT" ]]; then
    echo "Error: --storage-account is required."
    usage
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/../data"

echo "==> Storage account:  $STORAGE_ACCOUNT"
echo "==> Container:        $CONTAINER_NAME"
echo "==> Data directory:   $DATA_DIR"
echo ""

# ---------------------------------------------------------------------------
# Verify data directory exists and has files
# ---------------------------------------------------------------------------
if [[ ! -d "$DATA_DIR" ]]; then
    echo "Error: Data directory not found at $DATA_DIR"
    exit 1
fi

# ---------------------------------------------------------------------------
# Upload files from each chatbot directory
# ---------------------------------------------------------------------------
upload_files() {
    local source_dir="$1"
    local blob_prefix="$2"
    local app_scope="$3"
    local dir_name
    dir_name=$(basename "$source_dir")

    if [[ ! -d "$source_dir" ]]; then
        echo "    Skipping $dir_name (directory not found)"
        return
    fi

    local file_count
    file_count=$(find "$source_dir" -type f -not -name '.*' | wc -l | tr -d ' ')

    if [[ "$file_count" -eq 0 ]]; then
        echo "    Skipping $dir_name (no files found)"
        return
    fi

    echo "==> Uploading $file_count file(s) from $dir_name..."

    find "$source_dir" -type f -not -name '.*' | while read -r file_path; do
        local filename
        filename=$(basename "$file_path")
        local blob_name="${blob_prefix}/${filename}"

        echo "    Uploading: $blob_name"
        az storage blob upload \
            --account-name "$STORAGE_ACCOUNT" \
            --container-name "$CONTAINER_NAME" \
            --name "$blob_name" \
            --file "$file_path" \
            --auth-mode login \
            --overwrite \
            --no-progress \
            --only-show-errors

        # Set app_scope metadata on the blob
        echo "    Setting metadata: app_scope=$app_scope"
        az storage blob metadata update \
            --account-name "$STORAGE_ACCOUNT" \
            --container-name "$CONTAINER_NAME" \
            --name "$blob_name" \
            --metadata "app_scope=$app_scope" \
            --auth-mode login \
            --only-show-errors
    done
}

# Upload HR chatbot documents
upload_files "${DATA_DIR}/hr-chatbot" "hr-chatbot" "hr-chatbot"
echo ""

# Upload Legal chatbot documents
upload_files "${DATA_DIR}/legal-chatbot" "legal-chatbot" "legal-chatbot"
echo ""

# Upload shared documents (accessible to all chatbots)
upload_files "${DATA_DIR}/shared" "shared" "hr-chatbot,legal-chatbot,exec-chatbot"
echo ""

echo "==> All documents uploaded successfully."

# ---------------------------------------------------------------------------
# Trigger AI Search indexer (if search endpoint provided)
# ---------------------------------------------------------------------------
if [[ -n "$SEARCH_ENDPOINT" ]]; then
    INDEXER_NAME="${INDEX_NAME%%-index}-indexer"
    echo ""
    echo "==> Triggering AI Search indexer: $INDEXER_NAME"

    # Get an access token for Azure Search
    SEARCH_TOKEN=$(az account get-access-token \
        --resource https://search.azure.com \
        --query accessToken -o tsv 2>/dev/null) || {
        echo "    Warning: Could not get search access token. Trying with admin key..."
    }

    if [[ -n "${SEARCH_TOKEN:-}" ]]; then
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
            -X POST "${SEARCH_ENDPOINT}/indexers/${INDEXER_NAME}/run?api-version=2024-07-01" \
            -H "Authorization: Bearer ${SEARCH_TOKEN}" \
            -H "Content-Type: application/json")
    else
        echo "    Skipping indexer trigger (no authentication method available)."
        echo "    Run the indexer manually from the Azure Portal or with:"
        echo "      az rest --method POST --url '${SEARCH_ENDPOINT}/indexers/${INDEXER_NAME}/run?api-version=2024-07-01'"
        exit 0
    fi

    if [[ "$HTTP_CODE" -eq 202 || "$HTTP_CODE" -eq 204 ]]; then
        echo "    Indexer triggered successfully (HTTP $HTTP_CODE)."
        echo "    Monitor indexer status:"
        echo "      az rest --method GET --url '${SEARCH_ENDPOINT}/indexers/${INDEXER_NAME}/status?api-version=2024-07-01'"
    else
        echo "    Warning: Indexer trigger returned HTTP $HTTP_CODE."
        echo "    You may need to run the indexer manually from the Azure Portal."
    fi
else
    echo "Tip: Pass --search-endpoint to automatically trigger the AI Search indexer after upload."
fi

echo ""
echo "==> Done."
