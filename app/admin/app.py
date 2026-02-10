import logging
import os

from azure.cosmos.aio import CosmosClient
from azure.identity.aio import DefaultAzureCredential
from quart import Quart, Response, jsonify, request, send_from_directory
from quart_cors import cors

from services.apim import ApimService
from services.cosmos import TenantConfigService
from services.search import SearchService
from services.storage import StorageService

logger = logging.getLogger(__name__)

app = Quart(__name__, static_folder="static", static_url_path="/static")
app = cors(app, allow_origin="*")

COSMOS_ENDPOINT = os.environ.get("COSMOS_ENDPOINT", "")
COSMOS_DATABASE = os.environ.get("COSMOS_DATABASE", "rag-platform")
AZURE_SUBSCRIPTION_ID = os.environ.get("AZURE_SUBSCRIPTION_ID", "")
RESOURCE_GROUP = os.environ.get("RESOURCE_GROUP", "")
APIM_NAME = os.environ.get("APIM_NAME", "")
STORAGE_ACCOUNT_NAME = os.environ.get("STORAGE_ACCOUNT_NAME", "")
AZURE_SEARCH_ENDPOINT = os.environ.get("AZURE_SEARCH_ENDPOINT", "")
AZURE_CLIENT_ID = os.environ.get("AZURE_CLIENT_ID", "")

credential = None
cosmos_client = None
tenant_service = None
apim_service = None
storage_service = None
search_service = None


@app.before_serving
async def setup_clients():
    global credential, cosmos_client, tenant_service, apim_service, storage_service, search_service

    credential_kwargs = {}
    if AZURE_CLIENT_ID:
        credential_kwargs["managed_identity_client_id"] = AZURE_CLIENT_ID

    credential = DefaultAzureCredential(**credential_kwargs)
    cosmos_client = CosmosClient(url=COSMOS_ENDPOINT, credential=credential)

    tenant_service = TenantConfigService(
        cosmos_client=cosmos_client,
        database_name=COSMOS_DATABASE,
    )

    apim_service = ApimService(
        subscription_id=AZURE_SUBSCRIPTION_ID,
        resource_group=RESOURCE_GROUP,
        apim_name=APIM_NAME,
        credential=credential,
    )

    storage_service = StorageService(
        storage_account_name=STORAGE_ACCOUNT_NAME,
        credential=credential,
    )

    search_service = SearchService(
        search_endpoint=AZURE_SEARCH_ENDPOINT,
        credential=credential,
    )


@app.after_serving
async def close_clients():
    if cosmos_client:
        await cosmos_client.close()
    if credential:
        await credential.close()


# ── Tenant CRUD ──────────────────────────────────────────────────────────────


@app.route("/api/tenants", methods=["GET"])
async def list_tenants():
    tenants = await tenant_service.list_tenants()
    return jsonify(tenants)


@app.route("/api/tenants", methods=["POST"])
async def create_tenant():
    body = await request.get_json()
    tenant_id = body.get("tenantId", "").strip()
    display_name = body.get("displayName", "").strip()
    system_prompt = body.get("system_prompt", "").strip()

    if not tenant_id or not display_name:
        return jsonify({"error": "tenantId and displayName are required"}), 400

    steps_completed = []
    subscription_key = None

    try:
        # 1. Create Cosmos DB config
        await tenant_service.create_tenant(
            tenant_id=tenant_id,
            display_name=display_name,
            system_prompt=system_prompt,
            temperature=body.get("temperature", 0.3),
            max_tokens=body.get("max_tokens", 1024),
            welcome_message=body.get("welcomeMessage", ""),
            primary_color=body.get("primaryColor", "#0078D4"),
        )
        steps_completed.append("cosmos_config")

        # 2. Create APIM product
        await apim_service.create_product(tenant_id, display_name)
        steps_completed.append("apim_product")

        # 3. Link rag-platform-api to product
        await apim_service.link_api_to_product(tenant_id)
        steps_completed.append("apim_api_link")

        # 4. Create APIM subscription
        await apim_service.create_subscription(tenant_id, display_name)
        steps_completed.append("apim_subscription")

        # 5. Get subscription primary key
        subscription_key = await apim_service.get_subscription_key(tenant_id)
        steps_completed.append("subscription_key")

        # 6. Create named value with the key
        await apim_service.create_named_value(tenant_id, subscription_key)
        steps_completed.append("apim_named_value")

        # 7. Update OpenAI API policy with new <when> block
        await apim_service.update_openai_policy(tenant_id)
        steps_completed.append("apim_policy_updated")

    except Exception as e:
        logger.exception("Tenant creation failed at step after %s", steps_completed)
        return jsonify({
            "error": str(e),
            "tenantId": tenant_id,
            "stepsCompleted": steps_completed,
            "subscriptionKey": subscription_key,
            "status": "partial",
        }), 500

    return jsonify({
        "tenantId": tenant_id,
        "displayName": display_name,
        "subscriptionKey": subscription_key,
        "stepsCompleted": steps_completed,
        "status": "created",
    }), 201


@app.route("/api/tenants/<tenant_id>", methods=["GET"])
async def get_tenant(tenant_id: str):
    try:
        tenant = await tenant_service.get_tenant(tenant_id)
        return jsonify(tenant)
    except Exception as e:
        return jsonify({"error": f"Tenant not found: {e}"}), 404


@app.route("/api/tenants/<tenant_id>", methods=["PUT"])
async def update_tenant(tenant_id: str):
    body = await request.get_json()
    try:
        tenant = await tenant_service.update_tenant(tenant_id, body)
        return jsonify(tenant)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/tenants/<tenant_id>", methods=["DELETE"])
async def delete_tenant(tenant_id: str):
    errors = []

    # Delete APIM resources first
    try:
        apim_errors = await apim_service.delete_tenant_resources(tenant_id)
        errors.extend(apim_errors)
    except Exception as e:
        errors.append(f"APIM cleanup failed: {e}")

    # Delete Cosmos DB config
    try:
        await tenant_service.delete_tenant(tenant_id)
    except Exception as e:
        errors.append(f"Cosmos delete failed: {e}")

    if errors:
        return jsonify({"status": "partial", "errors": errors}), 207

    return jsonify({"status": "deleted", "tenantId": tenant_id})


# ── Document management ──────────────────────────────────────────────────────


@app.route("/api/tenants/<tenant_id>/documents", methods=["POST"])
async def upload_documents(tenant_id: str):
    files = await request.files
    if not files:
        return jsonify({"error": "No files provided"}), 400

    results = []
    for key in files:
        file = files[key]
        data = file.read()
        result = await storage_service.upload_document(
            tenant_id=tenant_id,
            filename=file.filename,
            data=data,
            content_type=file.content_type or "application/octet-stream",
        )
        results.append(result)

    return jsonify({"uploaded": results}), 201


@app.route("/api/tenants/<tenant_id>/documents", methods=["GET"])
async def list_documents(tenant_id: str):
    documents = await storage_service.list_documents(tenant_id)
    return jsonify(documents)


@app.route("/api/tenants/<tenant_id>/documents/<path:blob_name>", methods=["DELETE"])
async def delete_document(tenant_id: str, blob_name: str):
    full_name = f"{tenant_id}/{blob_name}"
    try:
        await storage_service.delete_document(full_name)
        return jsonify({"status": "deleted", "blob_name": full_name})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ── Indexer ───────────────────────────────────────────────────────────────────


@app.route("/api/reindex", methods=["POST"])
async def reindex():
    result = await search_service.trigger_indexer()
    status_code = 202 if result["status"] == "accepted" else 500
    return jsonify(result), status_code


@app.route("/api/indexer/status", methods=["GET"])
async def indexer_status():
    result = await search_service.get_indexer_status()
    return jsonify(result)


# ── Health + SPA ──────────────────────────────────────────────────────────────


@app.route("/health", methods=["GET"])
async def health():
    return jsonify({"status": "ok"})


@app.route("/")
async def serve_spa():
    return await send_from_directory(app.static_folder, "index.html")
