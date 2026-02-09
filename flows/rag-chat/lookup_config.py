"""Look up chatbot configuration from Cosmos DB for a given app_id."""

import logging
import os
from typing import Any

from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential
from promptflow.core import tool

logger = logging.getLogger(__name__)

_DEFAULT_CONFIG: dict[str, Any] = {
    "system_prompt": (
        "You are a helpful AI assistant. Answer questions based on the provided context. "
        "If the context does not contain the answer, say so."
    ),
    "temperature": 0.7,
    "max_tokens": 1024,
    "chatbot_name": "Default Assistant",
}


@tool
def lookup_config(app_id: str) -> dict[str, Any]:
    """Retrieve chatbot configuration from Cosmos DB.

    Args:
        app_id: The application/tenant identifier used as partition key.

    Returns:
        Dict with keys: system_prompt, temperature, max_tokens, chatbot_name.
        Falls back to defaults if the config document is not found.
    """
    endpoint = os.environ["COSMOS_ENDPOINT"]
    database_name = os.environ["COSMOS_DATABASE_NAME"]

    credential = DefaultAzureCredential()
    client = CosmosClient(url=endpoint, credential=credential)

    database = client.get_database_client(database_name)
    container = database.get_container_client("chatbot-config")

    try:
        item = container.read_item(item=app_id, partition_key=app_id)
        return {
            "system_prompt": item.get("system_prompt", _DEFAULT_CONFIG["system_prompt"]),
            "temperature": item.get("temperature", _DEFAULT_CONFIG["temperature"]),
            "max_tokens": item.get("max_tokens", _DEFAULT_CONFIG["max_tokens"]),
            "chatbot_name": item.get("chatbot_name", _DEFAULT_CONFIG["chatbot_name"]),
        }
    except Exception:
        logger.warning(
            "Config not found for app_id '%s', using defaults.", app_id
        )
        return dict(_DEFAULT_CONFIG)
