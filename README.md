# Multi-Tenant RAG Platform

A multi-tenant Retrieval-Augmented Generation (RAG) platform built on Azure. Deploy a single shared infrastructure to serve multiple isolated chatbot tenants, each with its own documents, system prompt, and branding.

## Architecture

Each tenant (chatbot) gets its own document corpus, configuration, and API subscription while sharing underlying Azure resources. Tenant isolation is enforced through `app_scope` filtering at the Azure AI Search and API Management layers.

Key components:

- **Azure AI Search** -- Hybrid (keyword + vector) search with semantic ranking and per-tenant `app_scope` filtering
- **Azure OpenAI** -- GPT-4o for chat and text-embedding-3-large for vectorization
- **Cosmos DB** -- Stores chatbot configuration, chat history, and usage analytics
- **Prompt Flow** -- RAG orchestration pipeline (query rewrite, search, context formatting, answer generation)
- **Container Apps** -- Hosts the Python backend, React frontend, and Tenant Admin Portal
- **API Management** -- Per-tenant subscription keys with server-side filter injection

For detailed architecture diagrams and data flow descriptions, see [docs/architecture.md](docs/architecture.md).

## Prerequisites

- An Azure subscription with Contributor access
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) v2.50+
- [Node.js](https://nodejs.org/) 18+ and npm
- [Python](https://www.python.org/) 3.11+
- [Docker](https://www.docker.com/) (for container builds)

## Quick Start

### 1. Deploy Infrastructure

```bash
az login
az account set --subscription <your-subscription-id>

az deployment sub create \
  --name deploy-dev \
  --location australiaeast \
  --template-file infra/main.bicep \
  --parameters infra/parameters/dev.bicepparam
```

### 2. Seed Chatbot Configurations

```bash
chmod +x scripts/seed-chatbot-config.sh

./scripts/seed-chatbot-config.sh \
  --cosmos-endpoint https://<your-cosmos-account>.documents.azure.com:443/
```

This creates three default chatbot configurations in Cosmos DB: `hr-chatbot`, `legal-chatbot`, and `exec-chatbot`.

### 3. Upload Sample Documents

```bash
chmod +x scripts/upload-sample-docs.sh

./scripts/upload-sample-docs.sh \
  --storage-account <your-storage-account> \
  --search-endpoint https://<your-search-service>.search.windows.net
```

### 4. Deploy Prompt Flow

```bash
chmod +x scripts/deploy-promptflow.sh

./scripts/deploy-promptflow.sh \
  --resource-group <your-resource-group> \
  --workspace-name <your-ml-workspace> \
  --endpoint-name rag-chat-endpoint
```

### 5. Run the Application Locally

**Backend:**

```bash
cd app/backend
pip install -r requirements.txt

export AZURE_OPENAI_ENDPOINT="https://<your-openai>.openai.azure.com/"
export AZURE_SEARCH_ENDPOINT="https://<your-search>.search.windows.net"
export AZURE_SEARCH_INDEX="documents-index"
export COSMOS_ENDPOINT="https://<your-cosmos>.documents.azure.com:443/"

python app.py
```

**Frontend (in a separate terminal):**

```bash
cd app/frontend
npm install
npm run dev
```

## Configuration Reference

### Environment Variables (Backend)

| Variable | Description | Default |
|---|---|---|
| `AZURE_OPENAI_ENDPOINT` | Azure OpenAI endpoint URL | (required) |
| `AZURE_OPENAI_DEPLOYMENT` | GPT model deployment name | `gpt-4o` |
| `AZURE_SEARCH_ENDPOINT` | Azure AI Search endpoint URL | (required) |
| `AZURE_SEARCH_INDEX` | Search index name | (required) |
| `COSMOS_ENDPOINT` | Cosmos DB endpoint URL | (required) |
| `COSMOS_DATABASE` | Cosmos DB database name | `rag-platform` |
| `APIM_ENDPOINT` | API Management endpoint URL | (optional) |

### Environment Variables (Frontend)

| Variable | Description |
|---|---|
| `VITE_APP_ID` | Chatbot tenant identifier (e.g., `hr-chatbot`) |
| `VITE_APIM_KEY` | APIM subscription key for the tenant |
| `VITE_APIM_ENDPOINT` | APIM gateway endpoint URL |

### Chatbot Configuration (Cosmos DB)

Each chatbot is configured via a document in the `chatbot-config` container:

```json
{
  "id": "hr-chatbot",
  "chatbotId": "hr-chatbot",
  "chatbotName": "HR Assistant",
  "system_prompt": "You are an HR assistant...",
  "temperature": 0.3,
  "max_tokens": 1024,
  "welcomeMessage": "Hello! I'm your HR assistant.",
  "primaryColor": "#2563EB",
  "app_scopes": ["hr-chatbot"]
}
```

## Adding a New Chatbot

The **Tenant Admin Portal** automates tenant onboarding. See [docs/admin-portal.md](docs/admin-portal.md) for the full design.

From the admin portal UI, you can create a tenant, configure it, upload documents, and trigger reindexing — all in one place. The portal handles APIM product/subscription/named value creation, Cosmos DB config, blob uploads with `app_scope` metadata, and policy XML updates automatically.

For the manual CLI-based approach, see [docs/adding-a-chatbot.md](docs/adding-a-chatbot.md).

### Admin Portal Documentation

- [High-Level Design](docs/admin-portal.md) — Architecture, API routes, frontend views, file structure
- [Azure Setup Details](docs/admin-portal-azure-setup.md) — How each Azure service is managed, RBAC requirements, policy XML mechanics
- [Verification Guide](docs/admin-portal-verification.md) — Step-by-step instructions for checking the deployment and testing end-to-end

## CI/CD

The project includes three GitHub Actions workflows:

| Workflow | Trigger | Description |
|---|---|---|
| [deploy-infra.yml](.github/workflows/deploy-infra.yml) | `infra/**` changes | Validates, previews, and deploys Bicep infrastructure across dev/staging/prod |
| [deploy-app.yml](.github/workflows/deploy-app.yml) | `app/**` changes | Builds container image, pushes to ACR, deploys to Container Apps |
| [deploy-promptflow.yml](.github/workflows/deploy-promptflow.yml) | `flows/**` changes | Registers the Prompt Flow model and deploys to a managed online endpoint |

All workflows use OIDC-based Azure authentication (no stored secrets). Staging and production environments require manual approval.

### Required GitHub Configuration

Set these as GitHub repository variables (`vars`):

- `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` -- for OIDC login
- `ACR_NAME` -- Azure Container Registry name
- `CONTAINER_APP_NAME` -- Container Apps resource name
- `RESOURCE_GROUP` -- Azure resource group name
- `WORKSPACE_NAME` -- Azure ML workspace name
- `ENDPOINT_NAME` -- Prompt Flow endpoint name
- `VITE_APP_ID` -- Default chatbot ID for the frontend build

Configure GitHub environments (`dev`, `staging`, `production`) with required reviewers for staging and production.

## Project Structure

```
multi_tenant_rag/
  .github/workflows/       # CI/CD pipelines
  app/
    admin/                 # Tenant Admin Portal (Quart + vanilla JS)
      services/            # Azure service integrations (APIM, Cosmos, Storage, Search)
      static/              # SPA frontend (HTML/CSS/JS)
    backend/               # Python Quart API server
      approaches/          # RAG chat approach implementation
      chat_history/        # Cosmos DB chat history manager
    frontend/              # React + Vite SPA
      src/
        api/               # API client
        pages/chat/        # Chat page components
        components/        # Shared UI components
  data/                    # Sample documents per tenant
    hr-chatbot/
    legal-chatbot/
    shared/
  docs/                    # Architecture and runbook documentation
  flows/
    rag-chat/              # Prompt Flow RAG pipeline
  infra/
    modules/               # Bicep modules (AI Search, Cosmos, OpenAI, etc.)
    parameters/            # Environment-specific parameter files
  scripts/                 # Operational scripts
```

## Contributing

1. Create a feature branch from `main`
2. Make changes and test locally
3. Open a pull request -- the infrastructure workflow will run validation and what-if analysis
4. After review and approval, merge to `main` to trigger deployment

## License

MIT
