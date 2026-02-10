import xml.etree.ElementTree as ET

import aiohttp


class ApimService:
    def __init__(self, subscription_id: str, resource_group: str, apim_name: str, credential):
        self.base_url = (
            f"https://management.azure.com/subscriptions/{subscription_id}"
            f"/resourceGroups/{resource_group}"
            f"/providers/Microsoft.ApiManagement/service/{apim_name}"
        )
        self.credential = credential
        self.api_version = "2024-05-01"

    async def _get_token(self) -> str:
        token = await self.credential.get_token("https://management.azure.com/.default")
        return token.token

    def _headers(self, token: str) -> dict:
        return {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        }

    async def create_product(self, tenant_id: str, display_name: str) -> dict:
        token = await self._get_token()
        url = f"{self.base_url}/products/{tenant_id}?api-version={self.api_version}"
        body = {
            "properties": {
                "displayName": display_name,
                "description": f"{display_name} product for multi-tenant RAG platform",
                "subscriptionRequired": True,
                "approvalRequired": False,
                "state": "published",
            }
        }
        async with aiohttp.ClientSession() as session:
            async with session.put(url, json=body, headers=self._headers(token)) as resp:
                data = await resp.json()
                if resp.status not in (200, 201):
                    raise Exception(f"Failed to create product: {resp.status} {data}")
                return data

    async def link_api_to_product(self, tenant_id: str) -> None:
        token = await self._get_token()
        url = (
            f"{self.base_url}/products/{tenant_id}/apis/rag-platform-api"
            f"?api-version={self.api_version}"
        )
        async with aiohttp.ClientSession() as session:
            async with session.put(url, headers=self._headers(token)) as resp:
                if resp.status not in (200, 201):
                    body = await resp.text()
                    raise Exception(f"Failed to link API to product: {resp.status} {body}")

    async def create_subscription(self, tenant_id: str, display_name: str) -> dict:
        token = await self._get_token()
        sub_id = f"{tenant_id}-subscription"
        url = f"{self.base_url}/subscriptions/{sub_id}?api-version={self.api_version}"
        body = {
            "properties": {
                "displayName": f"{display_name} Subscription",
                "scope": f"{self.base_url}/products/{tenant_id}",
                "state": "active",
            }
        }
        async with aiohttp.ClientSession() as session:
            async with session.put(url, json=body, headers=self._headers(token)) as resp:
                data = await resp.json()
                if resp.status not in (200, 201):
                    raise Exception(f"Failed to create subscription: {resp.status} {data}")
                return data

    async def get_subscription_key(self, tenant_id: str) -> str:
        token = await self._get_token()
        sub_id = f"{tenant_id}-subscription"
        url = f"{self.base_url}/subscriptions/{sub_id}/listSecrets?api-version={self.api_version}"
        async with aiohttp.ClientSession() as session:
            async with session.post(url, headers=self._headers(token)) as resp:
                data = await resp.json()
                if resp.status != 200:
                    raise Exception(f"Failed to get subscription key: {resp.status} {data}")
                return data["primaryKey"]

    async def create_named_value(self, tenant_id: str, key: str) -> dict:
        token = await self._get_token()
        nv_name = f"openai-key-{tenant_id}"
        url = f"{self.base_url}/namedValues/{nv_name}?api-version={self.api_version}"
        body = {
            "properties": {
                "displayName": nv_name,
                "value": key,
                "secret": True,
            }
        }
        async with aiohttp.ClientSession() as session:
            async with session.put(url, json=body, headers=self._headers(token)) as resp:
                data = await resp.json()
                if resp.status not in (200, 201, 202):
                    raise Exception(f"Failed to create named value: {resp.status} {data}")
                return data

    async def update_openai_policy(self, tenant_id: str) -> None:
        token = await self._get_token()
        policy_url = (
            f"{self.base_url}/apis/rag-openai-api/policies/policy"
            f"?api-version={self.api_version}"
        )

        # GET current policy with ETag
        async with aiohttp.ClientSession() as session:
            async with session.get(policy_url, headers=self._headers(token)) as resp:
                if resp.status != 200:
                    body = await resp.text()
                    raise Exception(f"Failed to get policy: {resp.status} {body}")
                data = await resp.json()
                etag = resp.headers.get("ETag", "*")
                policy_xml = data["properties"]["value"]

        # Parse and inject new <when> block
        nv_ref = f"{{{{openai-key-{tenant_id}}}}}"
        new_when = (
            f'<when condition="@((string)context.Variables[&quot;apiKey&quot;] '
            f'== &quot;{nv_ref}&quot;)">'
            f'\n                <set-variable name="resolvedAppId" value="{tenant_id}" />'
            f"\n            </when>"
        )

        # Check if this tenant already exists in the policy
        if f"openai-key-{tenant_id}" in policy_xml:
            return  # Already present

        # Find the first <choose> block that contains key-matching <when> elements
        # and insert the new <when> before </choose>
        root = ET.fromstring(policy_xml)
        inbound = root.find("inbound")
        if inbound is None:
            raise Exception("No <inbound> section found in policy")

        target_choose = None
        for choose in inbound.findall("choose"):
            for when in choose.findall("when"):
                condition = when.get("condition", "")
                if "apiKey" in condition and "openai-key-" in condition:
                    target_choose = choose
                    break
            if target_choose is not None:
                break

        if target_choose is None:
            raise Exception("Could not find the key-matching <choose> block in policy")

        new_when_elem = ET.fromstring(
            f'<when condition="@((string)context.Variables[&quot;apiKey&quot;] '
            f'== &quot;{nv_ref}&quot;)">'
            f'<set-variable name="resolvedAppId" value="{tenant_id}" />'
            f"</when>"
        )
        target_choose.append(new_when_elem)

        # Serialize back — ET doesn't preserve XML declaration or formatting well,
        # so we reconstruct the policy value from the modified tree
        updated_xml = ET.tostring(root, encoding="unicode", xml_declaration=False)

        # PUT updated policy
        put_body = {
            "properties": {
                "format": "rawxml",
                "value": updated_xml,
            }
        }
        headers = self._headers(token)
        headers["If-Match"] = etag

        async with aiohttp.ClientSession() as session:
            async with session.put(policy_url, json=put_body, headers=headers) as resp:
                if resp.status not in (200, 201):
                    body = await resp.text()
                    raise Exception(f"Failed to update policy: {resp.status} {body}")

    async def delete_tenant_resources(self, tenant_id: str) -> list[str]:
        token = await self._get_token()
        errors = []

        # Delete in reverse order of creation
        resources = [
            ("named value", f"namedValues/openai-key-{tenant_id}"),
            ("subscription", f"subscriptions/{tenant_id}-subscription"),
            ("API link", f"products/{tenant_id}/apis/rag-platform-api"),
            ("product", f"products/{tenant_id}"),
        ]

        async with aiohttp.ClientSession() as session:
            for name, path in resources:
                url = f"{self.base_url}/{path}?api-version={self.api_version}"
                async with session.delete(url, headers=self._headers(token)) as resp:
                    if resp.status in (200, 204, 404):
                        continue
                    body = await resp.text()
                    errors.append(f"Failed to delete {name}: {resp.status} {body}")

        return errors
