"""Search documents in Azure AI Search using hybrid search with semantic ranking."""

import os
from typing import Any

from azure.identity import DefaultAzureCredential
from azure.search.documents import SearchClient
from azure.search.documents.models import VectorizableTextQuery
from promptflow.core import tool


@tool
def search_documents(query: str, filter: str) -> list[dict[str, Any]]:
    """Perform hybrid search with semantic ranking against Azure AI Search.

    Args:
        query: The rewritten search query string.
        filter: OData filter expression for tenant scoping (e.g. "app_scope eq 'hr-chatbot'").

    Returns:
        List of search result dicts with keys: chunk, title, source_file.
    """
    endpoint = os.environ["AZURE_SEARCH_ENDPOINT"]
    index_name = os.environ["AZURE_SEARCH_INDEX_NAME"]

    credential = DefaultAzureCredential()
    client = SearchClient(
        endpoint=endpoint,
        index_name=index_name,
        credential=credential,
    )

    vector_query = VectorizableTextQuery(
        text=query,
        k_nearest_neighbors=50,
        fields="text_vector",
        exhaustive=True,
    )

    results = client.search(
        search_text=query,
        vector_queries=[vector_query],
        filter=filter,
        query_type="semantic",
        semantic_configuration_name="default-semantic-config",
        top=5,
        select=["chunk", "title", "source_file"],
    )

    documents: list[dict[str, Any]] = []
    for result in results:
        documents.append(
            {
                "chunk": result.get("chunk", ""),
                "title": result.get("title", ""),
                "source_file": result.get("source_file", ""),
            }
        )

    return documents
