import aiohttp


class SearchService:
    def __init__(self, search_endpoint: str, credential):
        self.search_endpoint = search_endpoint.rstrip("/")
        self.credential = credential
        self.indexer_name = "documents-indexer"
        self.api_version = "2024-07-01"

    async def _get_token(self) -> str:
        token = await self.credential.get_token("https://search.azure.com/.default")
        return token.token

    async def trigger_indexer(self) -> dict:
        token = await self._get_token()
        url = f"{self.search_endpoint}/indexers/{self.indexer_name}/run?api-version={self.api_version}"
        async with aiohttp.ClientSession() as session:
            async with session.post(
                url, headers={"Authorization": f"Bearer {token}"}
            ) as resp:
                if resp.status == 202:
                    return {"status": "accepted", "message": "Indexer run triggered"}
                body = await resp.text()
                return {"status": "error", "code": resp.status, "message": body}

    async def get_indexer_status(self) -> dict:
        token = await self._get_token()
        url = f"{self.search_endpoint}/indexers/{self.indexer_name}/status?api-version={self.api_version}"
        async with aiohttp.ClientSession() as session:
            async with session.get(
                url, headers={"Authorization": f"Bearer {token}"}
            ) as resp:
                data = await resp.json()
                last_result = data.get("lastResult", {})
                return {
                    "status": data.get("status", "unknown"),
                    "lastRunStatus": last_result.get("status", "unknown"),
                    "lastRunTime": last_result.get("endTime"),
                    "itemsProcessed": last_result.get("itemsProcessed", 0),
                    "itemsFailed": last_result.get("itemsFailed", 0),
                }
