from typing import Any, AsyncGenerator

from azure.cosmos.aio import CosmosClient
from azure.search.documents.aio import SearchClient
from azure.search.documents.models import VectorizableTextQuery
from openai import AsyncAzureOpenAI


class ChatReadRetrieveRead:
    def __init__(
        self,
        search_client: SearchClient,
        openai_client: AsyncAzureOpenAI,
        cosmos_client: CosmosClient,
        search_index: str,
        deployment_name: str,
    ):
        self.search_client = search_client
        self.openai_client = openai_client
        self.cosmos_client = cosmos_client
        self.search_index = search_index
        self.deployment_name = deployment_name

    async def _get_chatbot_config(self, app_id: str) -> dict[str, Any]:
        try:
            database = self.cosmos_client.get_database_client("rag-platform")
            container = database.get_container_client("chatbot-config")
            item = await container.read_item(item=app_id, partition_key=app_id)
            return item
        except Exception:
            return {
                "chatbotId": app_id,
                "chatbotName": "AI Assistant",
                "system_prompt": (
                    "You are a helpful AI assistant. Answer questions based on the "
                    "provided context. If you cannot find the answer in the context, "
                    "say so clearly. Always cite your sources using [doc1], [doc2] etc."
                ),
            }

    async def _search(
        self, query: str, app_id: str, top: int = 5
    ) -> list[dict[str, Any]]:
        filter_expression = f"app_scope/any(s: search.in(s, '{app_id}'))"

        vector_query = VectorizableTextQuery(
            text=query,
            k_nearest_neighbors=50,
            fields="text_vector",
        )

        results = await self.search_client.search(
            search_text=query,
            vector_queries=[vector_query],
            filter=filter_expression,
            query_type="semantic",
            semantic_configuration_name="default-semantic-config",
            top=top,
            select=["chunk_id", "title", "chunk", "source_file"],
        )

        documents = []
        async for result in results:
            documents.append(
                {
                    "id": result.get("chunk_id", ""),
                    "title": result.get("title", ""),
                    "content": result.get("chunk", ""),
                    "source_file": result.get("source_file", ""),
                    "score": result.get("@search.score", 0),
                }
            )

        return documents

    def _format_context(
        self, documents: list[dict[str, Any]]
    ) -> tuple[str, list[dict[str, Any]]]:
        context_parts = []
        citations = []

        for i, doc in enumerate(documents):
            doc_ref = f"[doc{i + 1}]"
            context_parts.append(
                f"{doc_ref}: {doc['title']}\n{doc['content']}"
            )
            citations.append(
                {
                    "index": i + 1,
                    "title": doc["title"],
                    "source_file": doc["source_file"],
                    "content": doc["content"][:500],
                }
            )

        return "\n\n---\n\n".join(context_parts), citations

    async def run_with_streaming(
        self, messages: list[dict[str, str]], app_id: str
    ) -> AsyncGenerator[dict[str, Any], None]:
        user_query = messages[-1]["content"] if messages else ""

        search_results = await self._search(user_query, app_id)
        config = await self._get_chatbot_config(app_id)

        context_text, citations = self._format_context(search_results)

        system_prompt = config.get(
            "system_prompt",
            (
                "You are a helpful AI assistant. Answer questions based on the "
                "provided context. If you cannot find the answer in the context, "
                "say so clearly. Always cite your sources using [doc1], [doc2] etc."
            ),
        )

        system_message = (
            f"{system_prompt}\n\n"
            f"## Source Documents\n\n{context_text}"
        )

        openai_messages = [{"role": "system", "content": system_message}]

        for msg in messages:
            openai_messages.append({"role": msg["role"], "content": msg["content"]})

        temperature = config.get("temperature", 0.3)
        max_tokens = config.get("max_tokens", 1024)

        response = await self.openai_client.chat.completions.create(
            model=self.deployment_name,
            messages=openai_messages,
            temperature=temperature,
            max_tokens=max_tokens,
            stream=True,
        )

        async for event in response:
            if event.choices and len(event.choices) > 0:
                choice = event.choices[0]
                if choice.delta and choice.delta.content:
                    yield {
                        "delta": {
                            "content": choice.delta.content,
                            "role": "assistant",
                        }
                    }

        yield {
            "delta": {"content": "", "role": "assistant"},
            "citations": citations,
        }
