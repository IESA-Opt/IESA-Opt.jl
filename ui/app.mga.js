(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const state = { options: null, preview: null, campaignId: null, results: [] };

  function escapeHtml(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  function populateForm(options) {
    state.options = options || {};
    const select = $("mgaInputWorkbook");
    if (select && !select.options.length) {
      const inputs = Array.isArray(state.options.scenarios) ? state.options.scenarios : [];
      inputs.forEach((item) => {
        const opt = document.createElement("option");
        opt.value = item.path || item;
        opt.textContent = item.label || item.path || item;
        select.appendChild(opt);
      });
    }
    bind();
    updateSummaries();
  }

  function bind() {
    const form = $("mgaForm");
    if (form && !form.dataset.bound) {
      form.dataset.bound = "1";
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        runMga().catch((err) => renderError(err));
      });
    }
    const preview = $("mgaPreviewBtn");
    if (preview && !preview.dataset.bound) {
      preview.dataset.bound = "1";
      preview.addEventListener("click", () => previewMga().catch((err) => renderError(err)));
    }
    ["mgaCostSlack", "mgaDirections", "mgaWorkers"].forEach((id) => {
      const el = $(id);
      if (el && !el.dataset.bound) {
        el.dataset.bound = "1";
        el.addEventListener("input", updateSummaries);
      }
    });
  }

  function collectConfig() {
    return {
      name: ($("mgaName") && $("mgaName").value) || "mga_campaign",
      inputWorkbook: ($("mgaInputWorkbook") && $("mgaInputWorkbook").value) || "data/default_data.xlsx",
      costSlack: Number(($("mgaCostSlack") && $("mgaCostSlack").value) || 5),
      directions: Number(($("mgaDirections") && $("mgaDirections").value) || 24),
      workers: Number(($("mgaWorkers") && $("mgaWorkers").value) || 4),
      threads: Number(($("mgaThreads") && $("mgaThreads").value) || 0),
    };
  }

  function updateSummaries() {
    const cfg = collectConfig();
    const slack = $("mgaSlackSummary");
    const dirs = $("mgaDirectionSummary");
    const workers = $("mgaWorkerSummary");
    if (slack) slack.textContent = `${cfg.costSlack}%`;
    if (dirs) dirs.textContent = String(cfg.directions);
    if (workers) workers.textContent = String(cfg.workers);
  }

  async function postJson(url, body) {
    const response = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || payload.ok === false) throw new Error(payload.error || response.statusText || "Request failed");
    return payload;
  }

  async function previewMga() {
    setTitle("Planning MGA design", "Loading workbook and sector groups.");
    const payload = await postJson("/api/mga/preview", collectConfig());
    state.preview = payload;
    setTitle("MGA design ready", "Review directions, then run the campaign.");
    renderPreview(payload);
  }

  async function runMga() {
    setTitle("Running MGA", "Dispatching parallel directions.");
    const payload = await postJson("/api/mga/run", collectConfig());
    state.campaignId = payload.campaign_id;
    await pollResult(state.campaignId);
  }

  async function pollResult(id) {
    for (let attempt = 0; attempt < 40; attempt += 1) {
      const response = await fetch("/api/mga/status/" + encodeURIComponent(id));
      const payload = await response.json().catch(() => ({}));
      if (!response.ok || payload.ok === false) throw new Error(payload.error || response.statusText || "Could not load MGA status");
      const campaign = payload.campaign || {};
      setTitle("Running MGA", `${Number(campaign.completed || 0)}/${Number(campaign.total || 0)} alternatives prepared.`);
      if (payload.done || campaign.state === "completed") {
        await loadResult(id);
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 350));
    }
    await loadResult(id);
  }

  async function loadResult(id) {
    const response = await fetch("/api/mga/result/" + encodeURIComponent(id));
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || payload.ok === false) throw new Error(payload.error || response.statusText || "Could not load MGA result");
    state.results = Array.isArray(payload.results) ? payload.results : [];
    renderResults(payload);
    setTitle("MGA complete", `${state.results.length} alternatives prepared.`);
  }

  function setTitle(title, hint) {
    const t = $("mgaTitle");
    const h = $("mgaHint");
    if (t) t.textContent = title;
    if (h) h.textContent = hint;
  }

  function renderPreview(payload) {
    const directions = Array.isArray(payload.directions) ? payload.directions : [];
    const method = $("mgaMethodText");
    if (method) method.textContent = payload.description || "Efficient directional MGA design loaded.";
    renderDirectionChart("mgaPreviewChart", directions, "Direction weight", "MGA direction weights");
    renderDirectionTable("mgaPreviewTable", directions);
  }

  function renderDirectionTable(id, directions) {
    const el = $(id);
    if (!el) return;
    if (!directions.length) {
      el.className = "table-wrap explorer-table empty-state";
      el.textContent = "No MGA directions loaded.";
      return;
    }
    el.className = "table-wrap explorer-table";
    const rows = directions.map((d) => {
      const weights = Array.isArray(d.weights) ? d.weights.slice().sort((a, b) => Math.abs(Number(b.weight)) - Math.abs(Number(a.weight))).slice(0, 3) : [];
      const summary = weights.map((w) => `${escapeHtml(w.group)} ${Number(w.weight).toFixed(2)}`).join(", ");
      return `<tr><td>${escapeHtml(d.id)}</td><td>${escapeHtml(d.dominantGroup)}</td><td>${summary}</td></tr>`;
    }).join("");
    el.innerHTML = `<table><thead><tr><th>Direction</th><th>Dominant group</th><th>Largest weights</th></tr></thead><tbody>${rows}</tbody></table>`;
  }

  function renderDirectionChart(id, directions, xTitle, title) {
    const el = $(id);
    if (!el) return;
    if (!window.Plotly || !directions.length) {
      el.className = "atlas-chart empty-state";
      el.textContent = directions.length ? "Plotly is not loaded." : "No MGA directions loaded.";
      return;
    }
    const top = directions.slice(0, 12);
    el.className = "atlas-chart plotly-chart";
    window.Plotly.react(el, [{
      type: "bar",
      orientation: "h",
      y: top.map((d) => `Direction ${d.id}`),
      x: top.map((d) => {
        const weights = Array.isArray(d.weights) ? d.weights : [];
        return weights.reduce((acc, w) => Math.max(acc, Math.abs(Number(w.weight) || 0)), 0);
      }),
      text: top.map((d) => d.dominantGroup || "System"),
      hovertemplate: "%{y}<br>Dominant: %{text}<br>Max |weight|: %{x:.3f}<extra></extra>",
      marker: { color: "#007a78" },
    }], {
      title: { text: title, font: { size: 13 } },
      margin: { l: 100, r: 20, t: 38, b: 45 },
      paper_bgcolor: "rgba(0,0,0,0)",
      plot_bgcolor: "rgba(0,0,0,0)",
      xaxis: { title: xTitle, gridcolor: "#dbe4ec" },
      yaxis: { automargin: true },
      showlegend: false,
    }, { responsive: true, displaylogo: false });
  }

  function renderResults(payload) {
    const rows = Array.isArray(payload.results) ? payload.results : [];
    const summary = $("mgaResultsSummary");
    if (summary) summary.textContent = rows.length ? `${rows.length} MGA alternatives available within ${payload.config.costSlack}% cost slack.` : "No MGA results loaded.";
    renderResultChart(rows);
    renderResultTable(rows);
  }

  function renderResultChart(rows) {
    const el = $("mgaResultsChart");
    if (!el) return;
    if (!window.Plotly || !rows.length) {
      el.className = "atlas-chart empty-state";
      el.textContent = rows.length ? "Plotly is not loaded." : "No MGA results loaded.";
      return;
    }
    el.className = "atlas-chart plotly-chart";
    window.Plotly.react(el, [{
      type: "scatter",
      mode: "markers",
      x: rows.map((r) => Number(r.slackUsed)),
      y: rows.map((r) => Number(r.diversityScore)),
      text: rows.map((r) => r.label),
      customdata: rows.map((r) => [r.dominantGroup, r.worker]),
      hovertemplate: "%{text}<br>Slack used: %{x:.2f}%<br>Diversity: %{y:.3f}<br>Dominant: %{customdata[0]}<br>Worker: %{customdata[1]}<extra></extra>",
      marker: { size: 10, color: rows.map((r) => Number(r.worker)), colorscale: "Viridis", opacity: 0.82, line: { color: "#0f2436", width: 0.5 } },
    }], {
      margin: { l: 64, r: 18, t: 16, b: 52 },
      paper_bgcolor: "rgba(0,0,0,0)",
      plot_bgcolor: "rgba(0,0,0,0)",
      xaxis: { title: "System-cost slack used (%)", gridcolor: "#dbe4ec" },
      yaxis: { title: "Diversity score", gridcolor: "#dbe4ec" },
      showlegend: false,
  }, { responsive: true, displaylogo: false });
  }

  function renderResultTable(rows) {
    const el = $("mgaResultsTable");
    if (!el) return;
    if (!rows.length) {
      el.className = "table-wrap explorer-table empty-state";
      el.textContent = "No MGA results loaded.";
      return;
    }
    el.className = "table-wrap explorer-table";
    const body = rows.map((r) => `<tr><td>${escapeHtml(r.direction)}</td><td>${escapeHtml(r.dominantGroup)}</td><td>${Number(r.costIndex).toFixed(3)}</td><td>${Number(r.slackUsed).toFixed(3)}</td><td>${Number(r.diversityScore).toFixed(3)}</td><td>${escapeHtml(r.worker)}</td></tr>`).join("");
    el.innerHTML = `<table><thead><tr><th>Direction</th><th>Dominant group</th><th>Cost index</th><th>Slack used</th><th>Diversity</th><th>Worker</th></tr></thead><tbody>${body}</tbody></table>`;
  }

  function renderError(err) {
    setTitle("MGA error", err && err.message ? err.message : String(err));
  }

  window.IESAMGA = { populateForm, previewMga };
})();
