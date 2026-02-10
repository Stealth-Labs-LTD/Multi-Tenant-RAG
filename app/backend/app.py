import asyncio
import json
import logging
import os
import time
import uuid

from azure.cosmos.aio import CosmosClient
from azure.identity.aio import DefaultAzureCredential, get_bearer_token_provider
from azure.search.documents.aio import SearchClient
from openai import AsyncAzureOpenAI
from quart import Quart, Response, jsonify, request
from quart_cors import cors

from approaches.chatreadretrieveread import ChatReadRetrieveRead
from chat_history.cosmosdb import CosmosDBChatHistory
from usage.cosmosdb import UsageLogger

logger = logging.getLogger(__name__)

app = Quart(__name__)
app = cors(app, allow_origin="*")

AZURE_OPENAI_ENDPOINT = os.environ.get("AZURE_OPENAI_ENDPOINT", "")
AZURE_SEARCH_ENDPOINT = os.environ.get("AZURE_SEARCH_ENDPOINT", "")
AZURE_SEARCH_INDEX = os.environ.get("AZURE_SEARCH_INDEX", "")
COSMOS_ENDPOINT = os.environ.get("COSMOS_ENDPOINT", "")
COSMOS_DATABASE = os.environ.get("COSMOS_DATABASE", "rag-platform")
APIM_ENDPOINT = os.environ.get("APIM_ENDPOINT", "")
AZURE_OPENAI_DEPLOYMENT = os.environ.get("AZURE_OPENAI_DEPLOYMENT", "gpt-4o")

credential = None
search_client = None
openai_client = None
cosmos_client = None
chat_approach = None
chat_history = None
usage_logger = None


@app.before_serving
async def setup_clients():
    global credential, search_client, openai_client, cosmos_client, chat_approach, chat_history, usage_logger

    credential = DefaultAzureCredential()

    search_client = SearchClient(
        endpoint=AZURE_SEARCH_ENDPOINT,
        index_name=AZURE_SEARCH_INDEX,
        credential=credential,
    )

    token_provider = get_bearer_token_provider(
        credential, "https://cognitiveservices.azure.com/.default"
    )

    openai_client = AsyncAzureOpenAI(
        azure_endpoint=AZURE_OPENAI_ENDPOINT,
        azure_ad_token_provider=token_provider,
        api_version="2024-06-01",
    )

    cosmos_client = CosmosClient(url=COSMOS_ENDPOINT, credential=credential)

    chat_approach = ChatReadRetrieveRead(
        search_client=search_client,
        openai_client=openai_client,
        cosmos_client=cosmos_client,
        search_index=AZURE_SEARCH_INDEX,
        deployment_name=AZURE_OPENAI_DEPLOYMENT,
    )

    chat_history = CosmosDBChatHistory(
        cosmos_client=cosmos_client,
        database_name=COSMOS_DATABASE,
    )

    usage_logger = UsageLogger(
        cosmos_client=cosmos_client,
        database_name=COSMOS_DATABASE,
    )


@app.after_serving
async def close_clients():
    if search_client:
        await search_client.close()
    if cosmos_client:
        await cosmos_client.close()
    if credential:
        await credential.close()


async def _log_usage_fire_and_forget(app_id: str, usage: dict) -> None:
    try:
        await usage_logger.log(
            app_id=app_id,
            prompt_tokens=usage.get("prompt_tokens", 0),
            completion_tokens=usage.get("completion_tokens", 0),
            total_tokens=usage.get("total_tokens", 0),
        )
    except Exception:
        logger.exception("Failed to log usage for %s", app_id)


@app.route("/chat", methods=["POST"])
async def chat():
    body = await request.get_json()
    messages = body.get("messages", [])
    context = body.get("context", {})
    app_id = context.get("app_id", "")

    if not messages or not app_id:
        return jsonify({"error": "messages and context.app_id are required"}), 400

    async def stream():
        usage = None
        async for chunk in chat_approach.run_with_streaming(messages, app_id):
            if chunk.get("usage"):
                usage = chunk["usage"]
            yield json.dumps(chunk) + "\n"
        if usage:
            asyncio.create_task(_log_usage_fire_and_forget(app_id, usage))

    return Response(stream(), mimetype="application/x-ndjson")


@app.route("/config/<app_id>", methods=["GET"])
async def get_config(app_id: str):
    try:
        database = cosmos_client.get_database_client(COSMOS_DATABASE)
        container = database.get_container_client("chatbot-config")
        item = await container.read_item(item=app_id, partition_key=app_id)
        return jsonify(
            {
                "chatbotId": item.get("chatbotId", app_id),
                "chatbotName": item.get("chatbotName", "AI Assistant"),
                "welcomeMessage": item.get(
                    "welcomeMessage", "Hello! How can I help you today?"
                ),
                "primaryColor": item.get("primaryColor", "#0078D4"),
                "logoUrl": item.get("logoUrl"),
            }
        )
    except Exception:
        return jsonify(
            {
                "chatbotId": app_id,
                "chatbotName": "AI Assistant",
                "welcomeMessage": "Hello! How can I help you today?",
                "primaryColor": "#0078D4",
            }
        )


@app.route("/chat/history", methods=["GET"])
async def list_chat_history():
    app_id = request.args.get("app_id", "")
    user_id = request.args.get("user_id", "anonymous")

    if not app_id:
        return jsonify({"error": "app_id is required"}), 400

    sessions = await chat_history.list_sessions(app_id, user_id)
    return jsonify(sessions)


@app.route("/chat/history", methods=["POST"])
async def create_chat_session():
    body = await request.get_json()
    app_id = body.get("app_id", "")
    user_id = body.get("user_id", "anonymous")

    if not app_id:
        return jsonify({"error": "app_id is required"}), 400

    session_id = await chat_history.create_session(app_id, user_id)
    return jsonify({"sessionId": session_id}), 201


@app.route("/chat/history/<session_id>", methods=["DELETE"])
async def delete_chat_session(session_id: str):
    await chat_history.delete_session(session_id)
    return jsonify({"status": "deleted"}), 200


@app.route("/health", methods=["GET"])
async def health():
    return jsonify({"status": "ok"})


@app.route("/api/usage", methods=["GET"])
async def get_usage():
    app_id = request.args.get("app_id", "")
    days = request.args.get("days", "30")

    if not app_id:
        return jsonify({"error": "app_id is required"}), 400

    try:
        days = int(days)
    except ValueError:
        return jsonify({"error": "days must be an integer"}), 400

    result = await usage_logger.get_usage(app_id, days)
    return jsonify(result)


async def _list_chatbot_configs() -> list[dict]:
    database = cosmos_client.get_database_client(COSMOS_DATABASE)
    container = database.get_container_client("chatbot-config")
    configs = []
    async for item in container.query_items(
        query="SELECT c.chatbotId, c.chatbotName FROM c",
        enable_cross_partition_query=True,
    ):
        configs.append(item)
    return configs


@app.route("/v1/models", methods=["GET"])
async def list_models():
    configs = await _list_chatbot_configs()
    models = [
        {
            "id": config["chatbotId"],
            "object": "model",
            "created": 1700000000,
            "owned_by": "rag-platform",
        }
        for config in configs
    ]
    return jsonify({"object": "list", "data": models})


@app.route("/v1/chat/completions", methods=["POST"])
async def openai_chat_completions():
    body = await request.get_json()
    messages = body.get("messages", [])
    context = body.get("context", {})
    model = body.get("model", "")
    stream = body.get("stream", False)

    # Tenant resolved by APIM inbound policy (injected as context.app_id)
    app_id = context.get("app_id", "")

    if not messages or not app_id:
        return (
            jsonify(
                {
                    "error": {
                        "message": "messages are required and context.app_id must be provided by APIM",
                        "type": "invalid_request_error",
                    }
                }
            ),
            400,
        )

    completion_id = f"chatcmpl-{uuid.uuid4().hex[:24]}"
    created = int(time.time())

    if stream:

        async def sse_stream():
            usage = None
            async for chunk in chat_approach.run_with_streaming(messages, app_id):
                delta_content = chunk.get("delta", {}).get("content", "")
                citations = chunk.get("citations")
                if chunk.get("usage"):
                    usage = chunk["usage"]

                sse_chunk = {
                    "id": completion_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": model or "rag-platform",
                    "choices": [
                        {
                            "index": 0,
                            "delta": {"content": delta_content}
                            if delta_content
                            else {},
                            "finish_reason": None,
                        }
                    ],
                }

                if citations:
                    sse_chunk["citations"] = citations
                    sse_chunk["choices"][0]["finish_reason"] = "stop"
                    if usage:
                        sse_chunk["usage"] = usage

                yield f"data: {json.dumps(sse_chunk)}\n\n"

            if usage:
                asyncio.create_task(_log_usage_fire_and_forget(app_id, usage))

            yield "data: [DONE]\n\n"

        return Response(sse_stream(), mimetype="text/event-stream")

    # Non-streaming: collect full response
    full_content = ""
    citations = None
    usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
    async for chunk in chat_approach.run_with_streaming(messages, app_id):
        delta_content = chunk.get("delta", {}).get("content", "")
        full_content += delta_content
        if chunk.get("citations"):
            citations = chunk["citations"]
        if chunk.get("usage"):
            usage = chunk["usage"]

    result = {
        "id": completion_id,
        "object": "chat.completion",
        "created": created,
        "model": "rag-platform",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": full_content},
                "finish_reason": "stop",
            }
        ],
        "usage": usage,
    }
    if citations:
        result["citations"] = citations

    if usage.get("total_tokens", 0) > 0:
        asyncio.create_task(_log_usage_fire_and_forget(app_id, usage))

    return jsonify(result)
