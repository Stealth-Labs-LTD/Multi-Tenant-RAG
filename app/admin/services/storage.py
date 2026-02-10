from azure.storage.blob.aio import BlobServiceClient


class StorageService:
    def __init__(self, storage_account_name: str, credential):
        self.account_url = f"https://{storage_account_name}.blob.core.windows.net"
        self.credential = credential
        self.container_name = "documents"

    def _get_client(self) -> BlobServiceClient:
        return BlobServiceClient(account_url=self.account_url, credential=self.credential)

    async def upload_document(
        self, tenant_id: str, filename: str, data: bytes, content_type: str
    ) -> dict:
        async with self._get_client() as client:
            container = client.get_container_client(self.container_name)
            blob_name = f"{tenant_id}/{filename}"
            await container.upload_blob(
                name=blob_name,
                data=data,
                overwrite=True,
                content_settings={"content_type": content_type},
                metadata={"app_scope": tenant_id},
            )
            return {"blob_name": blob_name, "tenant_id": tenant_id, "filename": filename}

    async def list_documents(self, tenant_id: str) -> list[dict]:
        async with self._get_client() as client:
            container = client.get_container_client(self.container_name)
            documents = []
            async for blob in container.list_blobs(
                name_starts_with=f"{tenant_id}/", include=["metadata"]
            ):
                documents.append({
                    "name": blob.name,
                    "filename": blob.name.split("/", 1)[-1] if "/" in blob.name else blob.name,
                    "size": blob.size,
                    "last_modified": blob.last_modified.isoformat() if blob.last_modified else None,
                    "metadata": blob.metadata or {},
                })
            return documents

    async def delete_document(self, blob_name: str) -> None:
        async with self._get_client() as client:
            container = client.get_container_client(self.container_name)
            await container.delete_blob(blob_name)
