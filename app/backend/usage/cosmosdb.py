import uuid
from datetime import datetime, timedelta, timezone

from azure.cosmos.aio import CosmosClient


class UsageLogger:
    def __init__(self, cosmos_client: CosmosClient, database_name: str):
        self.cosmos_client = cosmos_client
        self.database_name = database_name
        self.container_name = "usage-analytics"

    def _get_container(self):
        database = self.cosmos_client.get_database_client(self.database_name)
        return database.get_container_client(self.container_name)

    async def log(
        self,
        app_id: str,
        prompt_tokens: int,
        completion_tokens: int,
        total_tokens: int,
    ) -> None:
        container = self._get_container()
        doc = {
            "id": str(uuid.uuid4()),
            "chatbotId": app_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": total_tokens,
        }
        await container.create_item(body=doc)

    async def get_usage(self, app_id: str, days: int = 30) -> dict:
        container = self._get_container()
        query = (
            "SELECT VALUE {"
            "  'total_requests': COUNT(1),"
            "  'total_prompt_tokens': SUM(c.prompt_tokens),"
            "  'total_completion_tokens': SUM(c.completion_tokens),"
            "  'total_tokens': SUM(c.total_tokens)"
            "} FROM c WHERE c.chatbotId = @appId "
            "AND c.timestamp >= @since"
        )
        cutoff = datetime.now(timezone.utc) - timedelta(days=days)

        parameters = [
            {"name": "@appId", "value": app_id},
            {"name": "@since", "value": cutoff.isoformat()},
        ]

        result = {"total_requests": 0, "total_prompt_tokens": 0, "total_completion_tokens": 0, "total_tokens": 0}
        async for item in container.query_items(
            query=query,
            parameters=parameters,
            enable_cross_partition_query=True,
        ):
            result = item
            break

        return {
            "app_id": app_id,
            "period_days": days,
            "total_requests": result.get("total_requests", 0) or 0,
            "total_prompt_tokens": result.get("total_prompt_tokens", 0) or 0,
            "total_completion_tokens": result.get("total_completion_tokens", 0) or 0,
            "total_tokens": result.get("total_tokens", 0) or 0,
        }
