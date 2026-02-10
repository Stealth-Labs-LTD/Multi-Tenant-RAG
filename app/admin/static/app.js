/* Tenant Admin Portal — vanilla JS SPA */

// ── API helper ──

async function api(method, path, body) {
  const opts = {
    method,
    headers: {},
  };
  if (body instanceof FormData) {
    opts.body = body;
  } else if (body !== undefined) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(path, opts);
  if (!res.ok && res.status !== 207) {
    let msg;
    try {
      const data = await res.json();
      msg = data.error || data.message || res.statusText;
    } catch {
      msg = res.statusText;
    }
    throw new Error(msg);
  }
  if (res.status === 204) return null;
  return res.json();
}

// ── Toast notifications ──

function showToast(message, type = "info") {
  const container = document.getElementById("toast-container");
  const el = document.createElement("div");
  el.className = `toast toast-${type}`;
  el.textContent = message;
  container.appendChild(el);
  setTimeout(() => {
    el.classList.add("toast-exit");
    el.addEventListener("animationend", () => el.remove());
  }, 3500);
}

// ── Utilities ──

function formatBytes(bytes) {
  if (!bytes) return "—";
  const units = ["B", "KB", "MB", "GB"];
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  return (bytes / Math.pow(1024, i)).toFixed(i === 0 ? 0 : 1) + " " + units[i];
}

function escapeHtml(str) {
  if (str == null) return "";
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}

// ── Confirmation dialog ──

function confirmAction(title, message) {
  return new Promise((resolve) => {
    const overlay = document.createElement("div");
    overlay.className = "overlay";
    overlay.innerHTML = `
      <div class="dialog">
        <h3>${escapeHtml(title)}</h3>
        <p>${escapeHtml(message)}</p>
        <div class="dialog-actions">
          <button class="btn btn-secondary" data-action="cancel">Cancel</button>
          <button class="btn btn-danger" data-action="confirm">Confirm</button>
        </div>
      </div>
    `;
    overlay.querySelector('[data-action="cancel"]').onclick = () => {
      overlay.remove();
      resolve(false);
    };
    overlay.querySelector('[data-action="confirm"]').onclick = () => {
      overlay.remove();
      resolve(true);
    };
    document.body.appendChild(overlay);
  });
}

// ── Router ──

function getRoute() {
  const hash = location.hash || "#/";
  return hash.slice(1);
}

function router() {
  const path = getRoute();

  if (path === "/usage") {
    renderUsageOverview();
  } else if (path === "/tenants/new") {
    renderCreateTenant();
  } else if (path.startsWith("/tenants/") && path !== "/tenants/new") {
    const id = decodeURIComponent(path.split("/tenants/")[1]);
    renderTenantDetail(id);
  } else {
    renderTenantList();
  }
}

window.addEventListener("hashchange", router);

// ── Usage helpers ──

function formatNumber(n) {
  if (n == null) return "0";
  return n.toLocaleString();
}

function formatCost(n) {
  if (n == null || n === 0) return "$0.00";
  if (n < 0.01) return "<$0.01";
  return "$" + n.toFixed(2);
}

function exportCSV(headers, rows, filename) {
  const csv = [headers.join(",")]
    .concat(rows.map((r) => r.map((c) => '"' + String(c).replace(/"/g, '""') + '"').join(",")))
    .join("\n");
  const blob = new Blob([csv], { type: "text/csv" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = filename;
  a.click();
  URL.revokeObjectURL(a.href);
}

// ── Views ──

// -- Tenant List --

async function renderTenantList() {
  const app = document.getElementById("app");
  app.innerHTML = `
    <div class="page-header">
      <h2>Tenants</h2>
      <div>
        <a href="#/usage" class="btn btn-secondary" style="margin-right:8px">Usage Overview</a>
        <a href="#/tenants/new" class="btn btn-primary">+ Create Tenant</a>
      </div>
    </div>
    <div class="card">
      <div class="card-body loading-center">
        <span class="spinner"></span> Loading tenants...
      </div>
    </div>
  `;

  try {
    const tenants = await api("GET", "/api/tenants");
    const card = app.querySelector(".card");

    if (!tenants.length) {
      card.innerHTML = `
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Tenant ID</th>
                <th>Display Name</th>
                <th>Color</th>
                <th>Temperature</th>
                <th>Max Tokens</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr class="empty-row">
                <td colspan="6">No tenants yet. Create one to get started.</td>
              </tr>
            </tbody>
          </table>
        </div>
      `;
      return;
    }

    const rows = tenants
      .map(
        (t) => `
      <tr>
        <td><code>${escapeHtml(t.chatbotId)}</code></td>
        <td>${escapeHtml(t.chatbotName)}</td>
        <td><span class="color-swatch" style="background:${escapeHtml(t.primaryColor || "#0078D4")}"></span></td>
        <td>${t.temperature}</td>
        <td>${t.max_tokens}</td>
        <td><a href="#/tenants/${encodeURIComponent(t.chatbotId)}" class="btn btn-secondary btn-sm">View</a></td>
      </tr>
    `
      )
      .join("");

    card.innerHTML = `
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Tenant ID</th>
              <th>Display Name</th>
              <th>Color</th>
              <th>Temperature</th>
              <th>Max Tokens</th>
              <th></th>
            </tr>
          </thead>
          <tbody>${rows}</tbody>
        </table>
      </div>
    `;
  } catch (err) {
    showToast("Failed to load tenants: " + err.message, "error");
  }
}

// -- Create Tenant --

function renderCreateTenant() {
  const app = document.getElementById("app");
  app.innerHTML = `
    <div class="breadcrumb"><a href="#/">Tenants</a> / New</div>
    <div class="page-header">
      <h2>Create Tenant</h2>
    </div>
    <div class="card">
      <div class="card-body">
        <form id="create-form">
          <div class="form-group">
            <label for="tenantId">Tenant ID</label>
            <input type="text" id="tenantId" required
              pattern="[a-z0-9][a-z0-9\\-]*[a-z0-9]"
              placeholder="e.g. sports-chatbot">
            <div class="hint">Lowercase letters, numbers, and hyphens only.</div>
          </div>
          <div class="form-group">
            <label for="displayName">Display Name</label>
            <input type="text" id="displayName" required
              placeholder="e.g. Sports Assistant">
          </div>
          <div class="form-group">
            <label for="systemPrompt">System Prompt</label>
            <textarea id="systemPrompt" rows="4"
              placeholder="You are a helpful assistant..."></textarea>
          </div>
          <div class="form-row">
            <div class="form-group">
              <label for="temperature">Temperature</label>
              <input type="number" id="temperature"
                min="0" max="1" step="0.1" value="0.3">
            </div>
            <div class="form-group">
              <label for="maxTokens">Max Tokens</label>
              <input type="number" id="maxTokens"
                min="256" max="4096" step="256" value="1024">
            </div>
          </div>
          <div class="form-group">
            <label for="welcomeMessage">Welcome Message</label>
            <input type="text" id="welcomeMessage"
              placeholder="Hello! How can I help you today?">
          </div>
          <div class="form-group">
            <label for="primaryColor">Primary Color</label>
            <input type="color" id="primaryColor" value="#0078D4">
          </div>
          <div class="form-actions">
            <button type="submit" class="btn btn-primary">Create Tenant</button>
            <a href="#/" class="btn btn-secondary">Cancel</a>
          </div>
        </form>
        <div id="create-result" style="display:none"></div>
      </div>
    </div>
  `;

  document.getElementById("create-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const form = e.target;
    const submitBtn = form.querySelector('button[type="submit"]');
    submitBtn.disabled = true;
    submitBtn.textContent = "Creating...";

    const payload = {
      tenantId: document.getElementById("tenantId").value.trim(),
      displayName: document.getElementById("displayName").value.trim(),
      system_prompt: document.getElementById("systemPrompt").value.trim(),
      temperature: parseFloat(document.getElementById("temperature").value),
      max_tokens: parseInt(document.getElementById("maxTokens").value, 10),
      welcomeMessage: document.getElementById("welcomeMessage").value.trim(),
      primaryColor: document.getElementById("primaryColor").value,
    };

    try {
      const result = await api("POST", "/api/tenants", payload);
      form.style.display = "none";

      const resultDiv = document.getElementById("create-result");
      resultDiv.style.display = "block";
      resultDiv.innerHTML = `
        <h3 style="margin-bottom:12px">Tenant created successfully</h3>
        ${
          result.subscriptionKey
            ? `
          <div class="key-box">
            <p>APIM Subscription Key — save this now, it will not be shown again.</p>
            <div class="key-value">
              <code id="sub-key">${escapeHtml(result.subscriptionKey)}</code>
              <button class="btn btn-secondary btn-sm" id="copy-key-btn">Copy</button>
            </div>
          </div>
        `
            : ""
        }
        <div class="form-actions">
          <a href="#/tenants/${encodeURIComponent(payload.tenantId)}" class="btn btn-primary">Go to Tenant</a>
          <a href="#/" class="btn btn-secondary">Back to List</a>
        </div>
      `;

      const copyBtn = document.getElementById("copy-key-btn");
      if (copyBtn) {
        copyBtn.addEventListener("click", () => {
          navigator.clipboard.writeText(result.subscriptionKey).then(() => {
            copyBtn.textContent = "Copied!";
            setTimeout(() => (copyBtn.textContent = "Copy"), 2000);
          });
        });
      }

      showToast("Tenant created", "success");
    } catch (err) {
      showToast("Failed to create tenant: " + err.message, "error");
      submitBtn.disabled = false;
      submitBtn.textContent = "Create Tenant";
    }
  });
}

// -- Tenant Detail --

async function renderTenantDetail(tenantId) {
  const app = document.getElementById("app");
  app.innerHTML = `
    <div class="breadcrumb"><a href="#/">Tenants</a> / ${escapeHtml(tenantId)}</div>
    <div class="page-header">
      <h2>${escapeHtml(tenantId)}</h2>
    </div>
    <div class="loading-center"><span class="spinner"></span> Loading...</div>
  `;

  try {
    const tenant = await api("GET", `/api/tenants/${encodeURIComponent(tenantId)}`);
    app.innerHTML = `
      <div class="breadcrumb"><a href="#/">Tenants</a> / ${escapeHtml(tenantId)}</div>
      <div class="page-header">
        <h2>${escapeHtml(tenant.chatbotName || tenantId)}</h2>
        <button class="btn btn-danger" id="delete-tenant-btn">Delete Tenant</button>
      </div>
      <div class="card" id="usage-panel" style="margin-bottom:20px">
        <div class="card-header">
          <h2>Usage</h2>
          <div class="period-selector" id="usage-period">
            <button data-days="7">7d</button>
            <button data-days="30" class="active">30d</button>
            <button data-days="90">90d</button>
          </div>
        </div>
        <div class="card-body" id="usage-content">
          <div class="loading-center"><span class="spinner"></span> Loading usage...</div>
        </div>
      </div>
      <div class="panel-grid">
        <div class="card" id="config-panel">
          <div class="card-header"><h2>Configuration</h2></div>
          <div class="card-body">
            ${buildConfigForm(tenant)}
          </div>
        </div>
        <div class="card" id="docs-panel">
          <div class="card-header">
            <h2>Documents</h2>
            <button class="btn btn-secondary btn-sm" id="reindex-btn">Reindex</button>
          </div>
          <div class="card-body">
            <div id="doc-upload"></div>
            <div id="doc-list"><div class="loading-center"><span class="spinner"></span></div></div>
            <div id="indexer-status"></div>
          </div>
        </div>
      </div>
    `;

    setupConfigForm(tenantId);
    setupDeleteTenant(tenantId);
    setupDocUpload(tenantId);
    loadDocuments(tenantId);
    setupReindex();
    loadIndexerStatus();
    loadTenantUsage(tenantId, 30);
    setupUsagePeriodSelector(tenantId);
  } catch (err) {
    showToast("Failed to load tenant: " + err.message, "error");
    app.innerHTML = `
      <div class="breadcrumb"><a href="#/">Tenants</a> / ${escapeHtml(tenantId)}</div>
      <p>Could not load tenant. <a href="#/">Go back</a></p>
    `;
  }
}

function buildConfigForm(tenant) {
  return `
    <form id="config-form">
      <div class="form-group">
        <label for="cfg-chatbotName">Display Name</label>
        <input type="text" id="cfg-chatbotName" value="${escapeHtml(tenant.chatbotName)}">
      </div>
      <div class="form-group">
        <label for="cfg-system_prompt">System Prompt</label>
        <textarea id="cfg-system_prompt" rows="4">${escapeHtml(tenant.system_prompt)}</textarea>
      </div>
      <div class="form-row">
        <div class="form-group">
          <label for="cfg-temperature">Temperature</label>
          <input type="number" id="cfg-temperature" min="0" max="1" step="0.1" value="${tenant.temperature}">
        </div>
        <div class="form-group">
          <label for="cfg-max_tokens">Max Tokens</label>
          <input type="number" id="cfg-max_tokens" min="256" max="4096" step="256" value="${tenant.max_tokens}">
        </div>
      </div>
      <div class="form-group">
        <label for="cfg-welcomeMessage">Welcome Message</label>
        <input type="text" id="cfg-welcomeMessage" value="${escapeHtml(tenant.welcomeMessage)}">
      </div>
      <div class="form-group">
        <label for="cfg-primaryColor">Primary Color</label>
        <input type="color" id="cfg-primaryColor" value="${escapeHtml(tenant.primaryColor)}">
      </div>
      <div class="form-actions">
        <button type="submit" class="btn btn-primary">Save Changes</button>
      </div>
    </form>
  `;
}

function setupConfigForm(tenantId) {
  document.getElementById("config-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const btn = e.target.querySelector('button[type="submit"]');
    btn.disabled = true;
    btn.textContent = "Saving...";

    const payload = {
      chatbotName: document.getElementById("cfg-chatbotName").value.trim(),
      system_prompt: document.getElementById("cfg-system_prompt").value.trim(),
      temperature: parseFloat(document.getElementById("cfg-temperature").value),
      max_tokens: parseInt(document.getElementById("cfg-max_tokens").value, 10),
      welcomeMessage: document.getElementById("cfg-welcomeMessage").value.trim(),
      primaryColor: document.getElementById("cfg-primaryColor").value,
    };

    try {
      await api("PUT", `/api/tenants/${encodeURIComponent(tenantId)}`, payload);
      showToast("Configuration saved", "success");
    } catch (err) {
      showToast("Failed to save: " + err.message, "error");
    } finally {
      btn.disabled = false;
      btn.textContent = "Save Changes";
    }
  });
}

function setupDeleteTenant(tenantId) {
  document.getElementById("delete-tenant-btn").addEventListener("click", async () => {
    const ok = await confirmAction(
      "Delete Tenant",
      `Are you sure you want to delete "${tenantId}"? This will remove the configuration and APIM resources.`
    );
    if (!ok) return;

    try {
      await api("DELETE", `/api/tenants/${encodeURIComponent(tenantId)}`);
      showToast("Tenant deleted", "success");
      location.hash = "#/";
    } catch (err) {
      showToast("Failed to delete: " + err.message, "error");
    }
  });
}

// -- Documents --

function setupDocUpload(tenantId) {
  const container = document.getElementById("doc-upload");
  container.innerHTML = `
    <div class="dropzone" id="dropzone">
      <input type="file" id="file-input" multiple>
      <div class="dropzone-label">Drop files here or click to browse</div>
    </div>
    <div class="file-list" id="staged-files"></div>
    <div class="form-actions" id="upload-actions" style="display:none">
      <button class="btn btn-primary btn-sm" id="upload-btn">Upload</button>
      <button class="btn btn-secondary btn-sm" id="clear-btn">Clear</button>
    </div>
  `;

  const dropzone = document.getElementById("dropzone");
  const fileInput = document.getElementById("file-input");
  const stagedEl = document.getElementById("staged-files");
  const actionsEl = document.getElementById("upload-actions");
  let stagedFiles = [];

  function renderStaged() {
    if (!stagedFiles.length) {
      stagedEl.innerHTML = "";
      actionsEl.style.display = "none";
      return;
    }
    actionsEl.style.display = "flex";
    stagedEl.innerHTML = stagedFiles
      .map(
        (f, i) => `
      <div class="file-list-item">
        <div class="file-info">
          <span class="file-name">${escapeHtml(f.name)}</span>
          <span class="file-size">${formatBytes(f.size)}</span>
        </div>
        <button class="btn btn-secondary btn-sm" data-remove="${i}">Remove</button>
      </div>
    `
      )
      .join("");

    stagedEl.querySelectorAll("[data-remove]").forEach((btn) => {
      btn.addEventListener("click", () => {
        stagedFiles.splice(parseInt(btn.dataset.remove, 10), 1);
        renderStaged();
      });
    });
  }

  function addFiles(files) {
    stagedFiles.push(...Array.from(files));
    renderStaged();
  }

  dropzone.addEventListener("click", () => fileInput.click());
  fileInput.addEventListener("change", () => {
    if (fileInput.files.length) addFiles(fileInput.files);
    fileInput.value = "";
  });

  dropzone.addEventListener("dragover", (e) => {
    e.preventDefault();
    dropzone.classList.add("dragover");
  });
  dropzone.addEventListener("dragleave", () => dropzone.classList.remove("dragover"));
  dropzone.addEventListener("drop", (e) => {
    e.preventDefault();
    dropzone.classList.remove("dragover");
    if (e.dataTransfer.files.length) addFiles(e.dataTransfer.files);
  });

  document.getElementById("clear-btn").addEventListener("click", () => {
    stagedFiles = [];
    renderStaged();
  });

  document.getElementById("upload-btn").addEventListener("click", async () => {
    if (!stagedFiles.length) return;
    const btn = document.getElementById("upload-btn");
    btn.disabled = true;
    btn.textContent = "Uploading...";

    const fd = new FormData();
    stagedFiles.forEach((f) => fd.append("files", f));

    try {
      await api("POST", `/api/tenants/${encodeURIComponent(tenantId)}/documents`, fd);
      showToast(`${stagedFiles.length} file(s) uploaded`, "success");
      stagedFiles = [];
      renderStaged();
      loadDocuments(tenantId);
    } catch (err) {
      showToast("Upload failed: " + err.message, "error");
    } finally {
      btn.disabled = false;
      btn.textContent = "Upload";
    }
  });
}

async function loadDocuments(tenantId) {
  const container = document.getElementById("doc-list");
  try {
    const docs = await api("GET", `/api/tenants/${encodeURIComponent(tenantId)}/documents`);
    if (!docs.length) {
      container.innerHTML = `<p style="color:var(--color-text-muted);font-size:13px;padding:8px 0;">No documents uploaded yet.</p>`;
      return;
    }
    container.innerHTML = docs
      .map(
        (d) => `
      <div class="file-list-item">
        <div class="file-info">
          <span class="file-name">${escapeHtml(d.filename)}</span>
          <span class="file-size">${formatBytes(d.size || 0)}</span>
        </div>
        <button class="btn btn-danger btn-sm" data-delete-doc="${escapeHtml(d.filename)}">Delete</button>
      </div>
    `
      )
      .join("");

    container.querySelectorAll("[data-delete-doc]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        const filename = btn.dataset.deleteDoc;
        const ok = await confirmAction("Delete Document", `Delete "${filename}"?`);
        if (!ok) return;
        btn.disabled = true;
        try {
          await api(
            "DELETE",
            `/api/tenants/${encodeURIComponent(tenantId)}/documents/${encodeURIComponent(filename)}`
          );
          showToast("Document deleted", "success");
          loadDocuments(tenantId);
        } catch (err) {
          showToast("Delete failed: " + err.message, "error");
          btn.disabled = false;
        }
      });
    });
  } catch {
    container.innerHTML = `<p style="color:var(--color-error);font-size:13px;">Failed to load documents.</p>`;
  }
}

function setupReindex() {
  document.getElementById("reindex-btn").addEventListener("click", async () => {
    const btn = document.getElementById("reindex-btn");
    btn.disabled = true;
    btn.textContent = "Reindexing...";
    try {
      await api("POST", "/api/reindex");
      showToast("Reindex triggered", "success");
      setTimeout(() => loadIndexerStatus(), 2000);
    } catch (err) {
      showToast("Reindex failed: " + err.message, "error");
    } finally {
      btn.disabled = false;
      btn.textContent = "Reindex";
    }
  });
}

async function loadIndexerStatus() {
  const container = document.getElementById("indexer-status");
  if (!container) return;
  try {
    const status = await api("GET", "/api/indexer/status");
    const badgeClass =
      status.lastRunStatus === "success"
        ? "badge-success"
        : status.lastRunStatus === "inProgress"
        ? "badge-pending"
        : "badge-error";
    container.innerHTML = `
      <div class="indexer-status">
        <span class="label">Indexer:</span>
        <span class="badge ${badgeClass}">${escapeHtml(status.lastRunStatus)}</span>
        <span>${status.itemsProcessed} processed, ${status.itemsFailed} failed</span>
        ${status.lastRunTime ? `<span>Last: ${new Date(status.lastRunTime).toLocaleString()}</span>` : ""}
      </div>
    `;
  } catch {
    container.innerHTML = `
      <div class="indexer-status">
        <span class="label">Indexer:</span>
        <span class="badge badge-pending">unavailable</span>
      </div>
    `;
  }
}

// ── Tenant Usage ──

function setupUsagePeriodSelector(tenantId) {
  const container = document.getElementById("usage-period");
  if (!container) return;
  container.querySelectorAll("button").forEach((btn) => {
    btn.addEventListener("click", () => {
      container.querySelectorAll("button").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      loadTenantUsage(tenantId, parseInt(btn.dataset.days, 10));
    });
  });
}

async function loadTenantUsage(tenantId, days) {
  const container = document.getElementById("usage-content");
  if (!container) return;
  container.innerHTML = `<div class="loading-center"><span class="spinner"></span> Loading usage...</div>`;

  try {
    const data = await api("GET", `/api/tenants/${encodeURIComponent(tenantId)}/usage?days=${days}`);
    const s = data.summary;
    const daily = data.daily || [];

    container.innerHTML = `
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Requests</div>
          <div class="stat-value">${formatNumber(s.total_requests)}</div>
          <div class="stat-sub">Last ${days} days</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Prompt Tokens</div>
          <div class="stat-value">${formatNumber(s.total_prompt_tokens)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Completion Tokens</div>
          <div class="stat-value">${formatNumber(s.total_completion_tokens)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Estimated Cost</div>
          <div class="stat-value cost">${formatCost(s.estimated_cost_usd)}</div>
          <div class="stat-sub">${formatNumber(s.total_tokens)} total tokens</div>
        </div>
      </div>
      ${daily.length ? buildBarChart(daily) : '<p style="color:var(--color-text-muted);font-size:13px;">No usage data for this period.</p>'}
    `;
  } catch (err) {
    container.innerHTML = `<p style="color:var(--color-error);font-size:13px;">Failed to load usage data: ${escapeHtml(err.message)}</p>`;
  }
}

function buildBarChart(daily) {
  const maxTokens = Math.max(...daily.map((d) => d.total_tokens || 0), 1);
  const bars = daily
    .map((d) => {
      const pct = Math.max(((d.total_tokens || 0) / maxTokens) * 100, 1);
      const label = d.date.slice(5); // MM-DD
      return `
        <div class="chart-bar-group">
          <div class="chart-bar" style="height:${pct}%">
            <div class="chart-tooltip">${d.date}: ${formatNumber(d.total_tokens)} tokens, ${formatNumber(d.requests)} req, ${formatCost(d.estimated_cost_usd)}</div>
          </div>
          <div class="chart-label">${label}</div>
        </div>
      `;
    })
    .join("");

  return `
    <div class="chart-container">
      <div style="font-size:13px;color:var(--color-text-secondary);margin-bottom:8px;">Daily token usage</div>
      <div class="chart-bars">${bars}</div>
    </div>
  `;
}

// ── Usage Overview ──

async function renderUsageOverview() {
  const app = document.getElementById("app");
  app.innerHTML = `
    <div class="breadcrumb"><a href="#/">Tenants</a> / Usage Overview</div>
    <div class="page-header">
      <h2>Usage Overview</h2>
      <div style="display:flex;gap:8px;align-items:center;">
        <div class="period-selector" id="overview-period">
          <button data-days="7">7d</button>
          <button data-days="30" class="active">30d</button>
          <button data-days="90">90d</button>
        </div>
      </div>
    </div>
    <div id="overview-content">
      <div class="loading-center"><span class="spinner"></span> Loading usage data...</div>
    </div>
  `;

  loadUsageOverview(30);

  document.getElementById("overview-period").querySelectorAll("button").forEach((btn) => {
    btn.addEventListener("click", () => {
      document.getElementById("overview-period").querySelectorAll("button").forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      loadUsageOverview(parseInt(btn.dataset.days, 10));
    });
  });
}

async function loadUsageOverview(days) {
  const container = document.getElementById("overview-content");
  if (!container) return;
  container.innerHTML = `<div class="loading-center"><span class="spinner"></span> Loading usage data...</div>`;

  try {
    const data = await api("GET", `/api/usage/overview?days=${days}`);
    const g = data.grand_total;
    const tenants = data.tenants || [];
    const rates = data.cost_rates || {};

    const rows = tenants
      .map(
        (t) => `
      <tr>
        <td><a href="#/tenants/${encodeURIComponent(t.tenant_id)}">${escapeHtml(t.tenant_id)}</a></td>
        <td class="number">${formatNumber(t.requests)}</td>
        <td class="number">${formatNumber(t.prompt_tokens)}</td>
        <td class="number">${formatNumber(t.completion_tokens)}</td>
        <td class="number">${formatNumber(t.total_tokens)}</td>
        <td class="number"><strong>${formatCost(t.estimated_cost_usd)}</strong></td>
      </tr>
    `
      )
      .join("");

    container.innerHTML = `
      <div class="stats-grid">
        <div class="stat-card">
          <div class="stat-label">Total Requests</div>
          <div class="stat-value">${formatNumber(g.total_requests)}</div>
          <div class="stat-sub">Last ${days} days</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Total Prompt Tokens</div>
          <div class="stat-value">${formatNumber(g.total_prompt_tokens)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Total Completion Tokens</div>
          <div class="stat-value">${formatNumber(g.total_completion_tokens)}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Total Estimated Cost</div>
          <div class="stat-value cost">${formatCost(g.estimated_cost_usd)}</div>
          <div class="stat-sub">${formatNumber(g.total_tokens)} total tokens</div>
        </div>
      </div>
      <div class="card">
        <div class="card-header">
          <h2>Per-Tenant Breakdown</h2>
          <button class="btn btn-secondary btn-sm export-btn" id="export-csv-btn">Export CSV</button>
        </div>
        <div class="card-body">
          <div class="table-wrap">
            <table class="usage-table">
              <thead>
                <tr>
                  <th>Tenant</th>
                  <th class="number">Requests</th>
                  <th class="number">Prompt Tokens</th>
                  <th class="number">Completion Tokens</th>
                  <th class="number">Total Tokens</th>
                  <th class="number">Est. Cost</th>
                </tr>
              </thead>
              <tbody>
                ${rows || '<tr class="empty-row"><td colspan="6">No usage data for this period.</td></tr>'}
              </tbody>
              <tfoot>
                <tr style="font-weight:600">
                  <td>Total</td>
                  <td class="number">${formatNumber(g.total_requests)}</td>
                  <td class="number">${formatNumber(g.total_prompt_tokens)}</td>
                  <td class="number">${formatNumber(g.total_completion_tokens)}</td>
                  <td class="number">${formatNumber(g.total_tokens)}</td>
                  <td class="number">${formatCost(g.estimated_cost_usd)}</td>
                </tr>
              </tfoot>
            </table>
          </div>
          <p style="font-size:12px;color:var(--color-text-muted);margin-top:12px;">
            Cost estimates based on GPT-4o rates: $${rates.prompt_per_1k}/1K prompt tokens, $${rates.completion_per_1k}/1K completion tokens (${rates.currency}).
          </p>
        </div>
      </div>
    `;

    document.getElementById("export-csv-btn").addEventListener("click", () => {
      const csvHeaders = ["Tenant", "Requests", "Prompt Tokens", "Completion Tokens", "Total Tokens", "Estimated Cost (USD)"];
      const csvRows = tenants.map((t) => [
        t.tenant_id,
        t.requests,
        t.prompt_tokens,
        t.completion_tokens,
        t.total_tokens,
        t.estimated_cost_usd,
      ]);
      csvRows.push(["TOTAL", g.total_requests, g.total_prompt_tokens, g.total_completion_tokens, g.total_tokens, g.estimated_cost_usd]);
      exportCSV(csvHeaders, csvRows, `usage-${days}d-${new Date().toISOString().slice(0, 10)}.csv`);
      showToast("CSV exported", "success");
    });
  } catch (err) {
    container.innerHTML = `<p style="color:var(--color-error);">Failed to load usage: ${escapeHtml(err.message)}</p>`;
  }
}

// ── Init ──
router();
