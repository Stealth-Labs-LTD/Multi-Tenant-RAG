import json
import os

from azure.cosmos.aio import CosmosClient
from azure.identity.aio import DefaultAzureCredential, get_bearer_token_provider
from azure.search.documents.aio import SearchClient
from openai import AsyncAzureOpenAI
from quart import Quart, Response, jsonify, request
from quart_cors import cors

from approaches.chatreadretrieveread import ChatReadRetrieveRead
from chat_history.cosmosdb import CosmosDBChatHistory

app = Quart(__name__, static_folder="static", static_url_path="")
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


@app.before_serving
async def setup_clients():
    global credential, search_client, openai_client, cosmos_client, chat_approach, chat_history

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


@app.after_serving
async def close_clients():
    if search_client:
        await search_client.close()
    if cosmos_client:
        await cosmos_client.close()
    if credential:
        await credential.close()


@app.route("/chat", methods=["POST"])
async def chat():
    body = await request.get_json()
    messages = body.get("messages", [])
    context = body.get("context", {})
    app_id = context.get("app_id", "")

    if not messages or not app_id:
        return jsonify({"error": "messages and context.app_id are required"}), 400

    async def stream():
        async for chunk in chat_approach.run_with_streaming(messages, app_id):
            yield json.dumps(chunk) + "\n"

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


@app.route("/")
async def index():
    return await app.send_static_file("index.html")


@app.route("/<path:path>")
async def static_files(path: str):
    return await app.send_static_file(path)
