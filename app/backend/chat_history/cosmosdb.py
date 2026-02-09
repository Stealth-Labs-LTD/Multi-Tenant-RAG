import uuid
from datetime import datetime, timezone

from azure.cosmos.aio import CosmosClient


class CosmosDBChatHistory:
    def __init__(self, cosmos_client: CosmosClient, database_name: str):
        self.cosmos_client = cosmos_client
        self.database_name = database_name
        self.container_name = "chat-history"

    def _get_container(self):
        database = self.cosmos_client.get_database_client(self.database_name)
        return database.get_container_client(self.container_name)

    async def create_session(self, app_id: str, user_id: str) -> str:
        container = self._get_container()
        session_id = str(uuid.uuid4())

        session_doc = {
            "id": session_id,
            "sessionId": session_id,
            "appId": app_id,
            "userId": user_id,
            "type": "session",
            "title": "New Chat",
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

        await container.create_item(body=session_doc)
        return session_id

    async def add_message(self, session_id: str, role: str, content: str) -> None:
        container = self._get_container()
        message_id = str(uuid.uuid4())

        message_doc = {
            "id": message_id,
            "sessionId": session_id,
            "type": "message",
            "role": role,
            "content": content,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

        await container.create_item(body=message_doc)

    async def get_messages(self, session_id: str) -> list[dict]:
        container = self._get_container()

        query = (
            "SELECT * FROM c WHERE c.sessionId = @sessionId "
            "AND c.type = 'message' ORDER BY c.timestamp ASC"
        )
        parameters = [{"name": "@sessionId", "value": session_id}]

        messages = []
        async for item in container.query_items(
            query=query,
            parameters=parameters,
            partition_key=session_id,
        ):
            messages.append(
                {
                    "id": item["id"],
                    "sessionId": item["sessionId"],
                    "role": item["role"],
                    "content": item["content"],
                    "timestamp": item["timestamp"],
                }
            )

        return messages

    async def list_sessions(self, app_id: str, user_id: str) -> list[dict]:
        container = self._get_container()

        query = (
            "SELECT * FROM c WHERE c.appId = @appId "
            "AND c.userId = @userId AND c.type = 'session' "
            "ORDER BY c.timestamp DESC"
        )
        parameters = [
            {"name": "@appId", "value": app_id},
            {"name": "@userId", "value": user_id},
        ]

        sessions = []
        async for item in container.query_items(
            query=query,
            parameters=parameters,
            enable_cross_partition_query=True,
        ):
            sessions.append(
                {
                    "id": item["id"],
                    "sessionId": item["sessionId"],
                    "appId": item["appId"],
                    "userId": item["userId"],
                    "title": item.get("title", "New Chat"),
                    "timestamp": item["timestamp"],
                }
            )

        return sessions

    async def delete_session(self, session_id: str) -> None:
        container = self._get_container()

        query = "SELECT * FROM c WHERE c.sessionId = @sessionId"
        parameters = [{"name": "@sessionId", "value": session_id}]

        async for item in container.query_items(
            query=query,
            parameters=parameters,
            partition_key=session_id,
        ):
            await container.delete_item(item=item["id"], partition_key=session_id)
