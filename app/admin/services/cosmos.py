from azure.cosmos.aio import CosmosClient


class TenantConfigService:
    def __init__(self, cosmos_client: CosmosClient, database_name: str):
        self.cosmos_client = cosmos_client
        self.database_name = database_name
        self.container_name = "chatbot-config"

    def _get_container(self):
        database = self.cosmos_client.get_database_client(self.database_name)
        return database.get_container_client(self.container_name)

    async def create_tenant(
        self,
        tenant_id: str,
        display_name: str,
        system_prompt: str,
        temperature: float = 0.3,
        max_tokens: int = 1024,
        welcome_message: str = "",
        primary_color: str = "#0078D4",
    ) -> dict:
        container = self._get_container()
        doc = {
            "id": tenant_id,
            "chatbotId": tenant_id,
            "chatbotName": display_name,
            "system_prompt": system_prompt,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "welcomeMessage": welcome_message or f"Hello! I'm your {display_name}. How can I help?",
            "primaryColor": primary_color,
            "app_scopes": [tenant_id],
        }
        await container.upsert_item(body=doc)
        return doc

    async def list_tenants(self) -> list[dict]:
        container = self._get_container()
        tenants = []
        async for item in container.read_all_items():
            tenants.append({
                "id": item["id"],
                "chatbotId": item.get("chatbotId", item["id"]),
                "chatbotName": item.get("chatbotName", ""),
                "primaryColor": item.get("primaryColor", "#0078D4"),
                "temperature": item.get("temperature", 0.3),
                "max_tokens": item.get("max_tokens", 1024),
            })
        return tenants

    async def get_tenant(self, tenant_id: str) -> dict:
        container = self._get_container()
        item = await container.read_item(item=tenant_id, partition_key=tenant_id)
        return {
            "id": item["id"],
            "chatbotId": item.get("chatbotId", item["id"]),
            "chatbotName": item.get("chatbotName", ""),
            "system_prompt": item.get("system_prompt", ""),
            "temperature": item.get("temperature", 0.3),
            "max_tokens": item.get("max_tokens", 1024),
            "welcomeMessage": item.get("welcomeMessage", ""),
            "primaryColor": item.get("primaryColor", "#0078D4"),
            "app_scopes": item.get("app_scopes", [item["id"]]),
        }

    async def update_tenant(self, tenant_id: str, updates: dict) -> dict:
        container = self._get_container()
        item = await container.read_item(item=tenant_id, partition_key=tenant_id)
        for key, value in updates.items():
            if key not in ("id", "chatbotId"):
                item[key] = value
        await container.replace_item(item=tenant_id, body=item)
        return await self.get_tenant(tenant_id)

    async def delete_tenant(self, tenant_id: str) -> None:
        container = self._get_container()
        await container.delete_item(item=tenant_id, partition_key=tenant_id)
