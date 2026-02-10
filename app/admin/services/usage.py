import asyncio
from collections import defaultdict
from datetime import datetime, timedelta, timezone

from azure.cosmos.aio import CosmosClient


class UsageService:
    def __init__(self, cosmos_client: CosmosClient, database_name: str):
        self.cosmos_client = cosmos_client
        self.database_name = database_name
        self.usage_container = "usage-analytics"
        self.config_container = "chatbot-config"

    def _get_container(self, name: str | None = None):
        database = self.cosmos_client.get_database_client(self.database_name)
        return database.get_container_client(name or self.usage_container)

    async def _fetch_raw_usage(self, tenant_id: str, cutoff: str) -> list[dict]:
        """Fetch raw usage records for a single tenant (single partition)."""
        container = self._get_container()
        query = (
            "SELECT c.timestamp, c.prompt_tokens, c.completion_tokens, c.total_tokens "
            "FROM c WHERE c.chatbotId = @appId AND c.timestamp >= @since"
        )
        parameters = [
            {"name": "@appId", "value": tenant_id},
            {"name": "@since", "value": cutoff},
        ]
        rows = []
        async for item in container.query_items(query=query, parameters=parameters):
            rows.append(item)
        return rows

    async def get_tenant_usage(self, tenant_id: str, days: int = 30) -> dict:
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
        rows = await self._fetch_raw_usage(tenant_id, cutoff)

        total_prompt = sum(r.get("prompt_tokens", 0) or 0 for r in rows)
        total_completion = sum(r.get("completion_tokens", 0) or 0 for r in rows)
        total_tokens = sum(r.get("total_tokens", 0) or 0 for r in rows)

        return {
            "tenant_id": tenant_id,
            "period_days": days,
            "total_requests": len(rows),
            "total_prompt_tokens": total_prompt,
            "total_completion_tokens": total_completion,
            "total_tokens": total_tokens,
        }

    async def get_tenant_daily_usage(self, tenant_id: str, days: int = 30) -> list[dict]:
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
        rows = await self._fetch_raw_usage(tenant_id, cutoff)

        daily: dict[str, dict] = defaultdict(lambda: {
            "requests": 0, "prompt_tokens": 0,
            "completion_tokens": 0, "total_tokens": 0,
        })
        for item in rows:
            date = (item.get("timestamp") or "")[:10]
            if not date:
                continue
            daily[date]["requests"] += 1
            daily[date]["prompt_tokens"] += item.get("prompt_tokens", 0) or 0
            daily[date]["completion_tokens"] += item.get("completion_tokens", 0) or 0
            daily[date]["total_tokens"] += item.get("total_tokens", 0) or 0

        result = [{"date": d, **v} for d, v in daily.items()]
        result.sort(key=lambda r: r["date"])
        return result

    async def get_all_tenants_usage(self, days: int = 30) -> list[dict]:
        config_container = self._get_container(self.config_container)
        tenant_ids = []
        async for item in config_container.read_all_items():
            tenant_ids.append(item["id"])

        results = await asyncio.gather(
            *[self.get_tenant_usage(tid, days) for tid in tenant_ids]
        )

        rows = []
        for r in results:
            rows.append({
                "tenant_id": r["tenant_id"],
                "requests": r["total_requests"],
                "prompt_tokens": r["total_prompt_tokens"],
                "completion_tokens": r["total_completion_tokens"],
                "total_tokens": r["total_tokens"],
            })

        rows.sort(key=lambda r: r.get("total_tokens", 0), reverse=True)
        return rows
