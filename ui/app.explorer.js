// =============================================================================
// app.explorer.js -- Scenario Explorer section
// =============================================================================
(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const state = { options: null, graphMeta: null, modelMeta: null, graphPayload: null, modelPayload: null, atlasPayload: null, detailCenterId: "", bound: false };
  const palette = ["#1d5f8f", "#5a9f3f", "#00a3c7", "#b77800", "#ba3a2f", "#7a6a8f", "#4a7c7a", "#c45885", "#6f8a2c", "#2f6f5e"];
  const detailActivityColors = { Electricity: "#4778c4", Heat: "#c80f1e", Molecules: "#74ad45", Gas: "#f2b705", Emissions: "#8a5a2b", CO2: "#8a5a2b", "Liquid fuels": "#c56f2c", Biogenic: "#5aa06f", "Other carriers": "#7a6a8f" };

  async function fetchJson(url, options) {
    const response = await fetch(url, options);
    const payload = await response.json();
    if (!response.ok) throw new Error(payload.error || response.statusText);
    return payload;
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>'"]/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", "\"": "&quot;" }[ch]));
  }

  function fmt(value) {
    const n = Number(value);
    if (!Number.isFinite(n)) return value === undefined || value === null ? "" : String(value);
    if (Math.abs(n) >= 1000) return n.toLocaleString(undefined, { maximumFractionDigits: 0 });
    if (Math.abs(n) >= 1) return n.toLocaleString(undefined, { maximumFractionDigits: 2 });
    return n.toLocaleString(undefined, { maximumFractionDigits: 4 });
  }

  function populateForm(options) {
    state.options = options || {};
    bindOnce();
    fillWorkbookSelect("explorerAtlasWorkbook");
    fillWorkbookSelect("explorerModelWorkbook");
    fillWorkbookSelect("explorerGraphWorkbook");
    loadAtlas();
    loadModelOptions();
    loadGraphOptions().then(loadGraph).catch(error => setStatus("explorerGraphStatus", error.message, true));
  }

  function bindOnce() {
    if (state.bound) return;
    state.bound = true;
    const modelWorkbook = $("explorerModelWorkbook");
    const graphWorkbook = $("explorerGraphWorkbook");
    if (modelWorkbook) modelWorkbook.addEventListener("change", loadModelOptions);
    if (graphWorkbook) graphWorkbook.addEventListener("change", () => loadGraphOptions().then(loadGraph).catch(error => setStatus("explorerGraphStatus", error.message, true)));
    const atlasWorkbook = $("explorerAtlasWorkbook");
    if (atlasWorkbook) atlasWorkbook.addEventListener("change", loadAtlas);
    const atlasPeriod = $("explorerAtlasPeriod");
    if (atlasPeriod) atlasPeriod.addEventListener("change", loadAtlas);
    const atlasRefresh = $("explorerRefreshAtlas");
    if (atlasRefresh) atlasRefresh.addEventListener("click", loadAtlas);
    const profileSelect = $("atlasProfileSelect");
    if (profileSelect) profileSelect.addEventListener("change", () => state.atlasPayload && renderProfileSurface(state.atlasPayload.profileSurfaces || {}));
    const build = $("explorerBuildModel");
    if (build) build.addEventListener("click", loadModelBrowser);
    const refresh = $("explorerRefreshGraph");
    if (refresh) refresh.addEventListener("click", loadGraph);
    const graphPeriod = $("explorerGraphPeriod");
    if (graphPeriod) graphPeriod.addEventListener("change", loadGraph);
    const diagramDetail = $("explorerDiagramDetail");
    if (diagramDetail) diagramDetail.addEventListener("change", () => state.graphPayload && renderGraph(state.graphPayload));
    const detailSearch = $("explorerDetailSearch");
    if (detailSearch) detailSearch.addEventListener("input", () => renderDetailSearchResults(state.graphPayload));
    const maxRange = $("explorerMaxActivities");
    const maxNumber = $("explorerMaxActivitiesNumber");
    if (maxRange && maxNumber) {
      maxRange.addEventListener("input", () => { maxNumber.value = maxRange.value; });
      maxNumber.addEventListener("input", () => { maxRange.value = maxNumber.value; });
    }
    const modelKind = $("explorerModelKind");
    const modelSearch = $("explorerModelSearch");
    if (modelKind) modelKind.addEventListener("change", renderModelTable);
    if (modelSearch) modelSearch.addEventListener("input", renderModelTable);
    document.querySelectorAll('.tab-button[data-section="explorer"]').forEach(button => button.addEventListener("click", scheduleExplorerRender));
    document.querySelectorAll('.section-button[data-section="explorer"]').forEach(button => button.addEventListener("click", scheduleExplorerRender));
  }

  function scheduleExplorerRender() {
    renderActiveExplorerTab();
    if (window.requestAnimationFrame) window.requestAnimationFrame(renderActiveExplorerTab);
    setTimeout(renderActiveExplorerTab, 80);
  }

  function fillWorkbookSelect(id) {
    const select = $(id);
    if (!select) return;
    const scenarios = state.options.scenarios || [];
    const selected = state.options.defaults && state.options.defaults.inputWorkbook;
    select.innerHTML = "";
    const values = scenarios.includes(selected) ? scenarios : [selected, ...scenarios].filter(Boolean);
    values.forEach(value => {
      const option = document.createElement("option");
      option.value = value;
      option.textContent = value;
      option.selected = value === selected;
      select.appendChild(option);
    });
  }

  function currentWorkbook(id) {
    const select = $(id);
    return select && select.value ? select.value : ((state.options.defaults && state.options.defaults.inputWorkbook) || "Input/default_data.xlsx");
  }

  async function loadModelOptions() {
    setStatus("explorerModelStatus", "Loading workbook metadata.");
    try {
      const meta = await fetchJson("/api/explorer/options", postBody({ inputWorkbook: currentWorkbook("explorerModelWorkbook") }));
      state.modelMeta = meta;
      fillPeriodSelect("explorerModelPeriod", meta.periods, meta.defaultPeriod);
      setStatus("explorerModelStatus", `${fmt(meta.technologyCount)} technologies.`);
    } catch (error) {
      setStatus("explorerModelStatus", error.message, true);
    }
  }

  async function loadGraphOptions() {
    setStatus("explorerGraphStatus", "Loading workbook metadata.");
    const meta = await fetchJson("/api/explorer/options", postBody({ inputWorkbook: currentWorkbook("explorerGraphWorkbook") }));
    state.graphMeta = meta;
    fillPeriodSelect("explorerGraphPeriod", meta.periods, meta.defaultPeriod);
    renderChecks("explorerSectorFilters", meta.sectors || []);
    renderChecks("explorerSubsectorFilters", meta.subsectors || []);
    renderChecks("explorerCategoryFilters", meta.categories || []);
    setStatus("explorerGraphStatus", `${fmt(meta.technologyCount)} technologies.`);
    return meta;
  }

  function postBody(body) {
    return { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) };
  }

  function fillPeriodSelect(id, periods, selected) {
    const select = $(id);
    if (!select) return;
    const previous = select.value;
    select.innerHTML = "";
    (periods || []).forEach(period => {
      const option = document.createElement("option");
      option.value = period;
      option.textContent = period;
      option.selected = String(period) === String(previous || selected);
      select.appendChild(option);
    });
  }

  function renderChecks(id, rows) {
    const box = $(id);
    if (!box) return;
    box.innerHTML = "";
    const tools = document.createElement("div");
    tools.className = "explorer-check-tools";
    tools.innerHTML = `<button type="button" class="secondary-button">All</button><button type="button" class="secondary-button">None</button>`;
    const [all, none] = tools.querySelectorAll("button");
    all.addEventListener("click", () => setChecks(box, true));
    none.addEventListener("click", () => setChecks(box, false));
    box.appendChild(tools);
    rows.forEach(row => {
      const label = document.createElement("label");
      label.className = "explorer-check";
      label.innerHTML = `<input type="checkbox" value="${escapeHtml(row.id)}" checked><span>${escapeHtml(row.label)}</span><em>${fmt(row.count)}</em>`;
      box.appendChild(label);
    });
  }

  function setChecks(container, checked) {
    container.querySelectorAll('input[type="checkbox"]').forEach(input => { input.checked = checked; });
  }

  function checkedValues(id) {
    const box = $(id);
    if (!box) return [];
    return Array.from(box.querySelectorAll('input[type="checkbox"]:checked')).map(input => input.value);
  }

  function setStatus(id, message, isError) {
    const el = $(id);
    if (!el) return;
    el.textContent = message || "";
    el.classList.toggle("error-text", !!isError);
  }

  async function loadAtlas() {
    const button = $("explorerRefreshAtlas");
    if (button) { button.disabled = true; button.textContent = "Refreshing..."; }
    setStatus("explorerAtlasStatus", "Loading workbook atlas.");
    try {
      const body = {
        inputWorkbook: currentWorkbook("explorerAtlasWorkbook"),
        period: Number($("explorerAtlasPeriod") && $("explorerAtlasPeriod").value) || undefined,
      };
      const payload = await fetchJson("/api/explorer/inputAtlas", postBody(body));
      state.atlasPayload = payload;
      fillPeriodSelect("explorerAtlasPeriod", payload.periods || [], payload.selectedPeriod);
      setStatus("explorerAtlasStatus", `Loaded ${payload.inputWorkbook || "workbook"}.`);
      renderAtlasMetrics(payload);
      renderActiveExplorerTab();
    } catch (error) {
      setStatus("explorerAtlasStatus", error.message, true);
      setAtlasEmpty("atlasSheetBubble", error.message);
      setAtlasEmpty("atlasSetCounts", error.message);
    } finally {
      if (button) { button.disabled = false; button.textContent = "Refresh overview"; }
    }
  }

  function renderActiveExplorerTab() {
    const active = document.querySelector(".tab-panel.active");
    if (!active) return;
    if (active.id === "tab-explorer-input") renderInputOverview();
    else if (active.id === "tab-explorer-atlas") renderTechnologyAtlas();
    else if (active.id === "tab-explorer-costs") renderCostAtlas();
    else if (active.id === "tab-explorer-activity") renderActivityAtlas();
    else if (active.id === "tab-explorer-activity-deps") state.graphPayload ? renderActivityDependencyGraph(state.graphPayload) : setActivityDependencyEmpty("No coupled sectors graph loaded.");
    else if (active.id === "tab-explorer-details") renderFlowDetails();
    else if (active.id === "tab-explorer-profiles") renderProfilesAtlas();
    else if (active.id === "tab-explorer-policy") renderPolicyAtlas();
    else if (active.id === "tab-explorer-tech" && state.graphPayload) renderGraph(state.graphPayload);
    else if (active.id === "tab-explorer-model" && state.modelPayload) renderModelTable();
  }

  function renderAtlasMetrics(payload) {
    const box = $("atlasMetricCards");
    if (!box) return;
    const metrics = payload.metrics || {};
    const rows = [
      ["Sheets", metrics.sheets],
      ["Technologies", metrics.technologies],
      ["Activities", metrics.activities],
      ["Nodes", metrics.nodes],
      ["Periods", metrics.periods],
      ["Profiles", metrics.profileTypes],
    ];
    box.innerHTML = rows.map(([label, value]) => `<div class="atlas-metric"><span>${escapeHtml(label)}</span><strong>${fmt(value)}</strong></div>`).join("");
  }

  function renderInputOverview() {
    const payload = state.atlasPayload;
    if (!payload) return;
    renderSheetBubble(payload);
    renderSetCounts(payload);
    renderSheetTable(payload.sheets || []);
  }

  function renderTechnologyAtlas() {
    const payload = state.atlasPayload;
    if (!payload) return;
    renderSectorCategory(payload);
    renderTechScatter(payload);
    renderTechTable(payload.technologies || []);
  }

  function renderCostAtlas() {
    const payload = state.atlasPayload;
    if (!payload) return;
    const rows = buildCostRows(payload.technologies || []);
    renderCostStack(payload, rows);
    renderCostTable(rows);
  }

  function renderActivityAtlas() {
    const payload = state.atlasPayload;
    if (!payload) return;
    renderBalanceHeatmap(payload);
    renderDemandChart(payload.demands || []);
    renderFlowTable(((payload.balance || {}).flows) || []);
  }

  function renderProfilesAtlas() {
    const payload = state.atlasPayload;
    if (!payload) return;
    renderProfileSelector(payload.profileSurfaces || {});
    renderProfileSurface(payload.profileSurfaces || {});
    renderProfileHeatmap(payload.profiles || {});
    renderProfileTable(((payload.profileSurfaces || {}).summary) || []);
  }

  function renderPolicyAtlas() {
    const payload = state.atlasPayload;
    if (!payload) return;
    renderPolicyTable(payload.policyConstraints || []);
    renderTargetsChart(payload.targets || []);
    renderTargetTable(payload.targets || []);
  }

  function plotlyAtlas(id, traces, layout, className = "atlas-chart plotly-chart") {
    const el = $(id);
    if (!el) return;
    if (!window.Plotly) { el.textContent = "Plotly is not loaded."; return; }
    if (!traces || !traces.length) { setAtlasEmpty(id, "No data available."); return; }
    el.className = className;
    el.textContent = "";
    const base = {
      margin: { t: 22, r: 18, b: 58, l: 76 },
      paper_bgcolor: "#fbfdfe",
      plot_bgcolor: "#fbfdfe",
      font: { family: "system-ui,Segoe UI,Roboto,sans-serif", size: 12, color: "#0f2436" },
      hovermode: "closest",
      xaxis: { gridcolor: "#eef2f5", zerolinecolor: "#0f2436", tickfont: { size: 11 } },
      yaxis: { gridcolor: "#eef2f5", zerolinecolor: "#0f2436", tickfont: { size: 11 } },
      legend: { orientation: "h", x: 0, y: -0.2, font: { size: 11 } },
    };
    window.Plotly.react(el, traces, Object.assign(base, layout || {}), { responsive: true, displaylogo: false, modeBarButtonsToRemove: ["lasso2d", "select2d"] });
  }

  function setAtlasEmpty(id, message, className = "atlas-chart empty-state") {
    const el = $(id);
    if (!el) return;
    if (window.Plotly && el._fullLayout) window.Plotly.purge(el);
    el.className = className;
    el.textContent = message;
  }

  function renderSheetBubble(payload) {
    const sheets = payload.sheets || [];
    if (!sheets.length) { setAtlasEmpty("atlasSheetBubble", "No sheets loaded."); return; }
    const groups = groupBy(sheets, row => row.group || "Other");
    const traces = Object.keys(groups).sort().map((group, index) => {
      const rows = groups[group];
      return {
        type: "scatter",
        mode: "markers",
        name: group,
        x: rows.map(r => r.columns),
        y: rows.map(r => r.rows),
        text: rows.map(r => `<b>${escapeHtml(r.sheet)}</b><br>${escapeHtml(r.group)}<br>${fmt(r.rows)} rows x ${fmt(r.columns)} columns<br>${fmt(r.cells)} cells`),
        hoverinfo: "text",
        marker: { size: rows.map(r => Math.max(9, Math.min(42, Math.sqrt(Number(r.cells) || 1) / 9))), color: palette[index % palette.length], opacity: 0.78, line: { width: 1, color: "#fff" } },
      };
    });
    plotlyAtlas("atlasSheetBubble", traces, { xaxis: { title: "Columns", type: "log", gridcolor: "#eef2f5" }, yaxis: { title: "Rows", type: "log", gridcolor: "#eef2f5" } });
    const summary = $("atlasWorkbookSummary");
    if (summary) summary.textContent = `${fmt(sheets.length)} sheets, ${fmt(sheets.reduce((a, r) => a + Number(r.cells || 0), 0))} cells.`;
  }

  function renderSetCounts(payload) {
    const rows = (payload.setCounts || []).slice().sort((a, b) => Number(a.count) - Number(b.count));
    if (!rows.length) { setAtlasEmpty("atlasSetCounts", "No set counts loaded."); return; }
    plotlyAtlas("atlasSetCounts", [{ type: "bar", orientation: "h", x: rows.map(r => r.count), y: rows.map(r => r.name), text: rows.map(r => r.group), hovertemplate: "%{y}<br>%{x:,}<br>%{text}<extra></extra>", marker: { color: "#1d5f8f" } }], { margin: { t: 12, r: 18, b: 42, l: 168 }, xaxis: { title: "Count", gridcolor: "#eef2f5" }, yaxis: { automargin: true } });
  }

  function renderSheetTable(rows) {
    renderTable("atlasSheetsTable", rows, ["sheet", "group", "rows", "columns", "cells"], { limit: 80 });
  }

  function renderSectorCategory(payload) {
    const rows = payload.sectorCategories || [];
    if (!rows.length) { setAtlasEmpty("atlasSectorCategory", "No sector/category data loaded."); return; }
    const sectors = Array.from(new Set(rows.map(r => r.sector))).slice(0, 24);
    const categories = Array.from(new Set(rows.map(r => r.category))).slice(0, 12);
    const traces = categories.map((category, i) => ({
      type: "bar",
      name: category,
      x: sectors,
      y: sectors.map(sector => (rows.find(r => r.sector === sector && r.category === category) || {}).count || 0),
      marker: { color: palette[i % palette.length] },
      hovertemplate: "%{x}<br>" + escapeHtml(category) + ": %{y:,}<extra></extra>",
    }));
    plotlyAtlas("atlasSectorCategory", traces, { barmode: "stack", xaxis: { tickangle: -35, automargin: true }, yaxis: { title: "Technologies" } });
    const summary = $("atlasCompositionSummary");
    if (summary) summary.textContent = `${fmt(rows.reduce((a, r) => a + Number(r.count || 0), 0))} technologies across ${fmt(sectors.length)} sectors.`;
  }

  function renderTechScatter(payload) {
    const rows = (payload.technologies || []).filter(r => Number.isFinite(Number(r.investmentCost)) && Number(r.investmentCost) > 0 && Number.isFinite(Number(r.economicLifetime)) && Number(r.economicLifetime) > 0);
    if (!rows.length) { setAtlasEmpty("atlasTechScatter", "No technology economics loaded."); return; }
    const sectors = groupBy(rows, row => row.sector || "Unspecified");
    const traces = Object.keys(sectors).sort().map((sector, index) => {
      const sectorRows = sectors[sector];
      return {
        type: "scattergl",
        mode: "markers",
        name: sector,
        x: sectorRows.map(r => r.investmentCost),
        y: sectorRows.map(r => r.economicLifetime),
        text: sectorRows.map(r => `<b>${escapeHtml(r.name || r.id)}</b><br>${escapeHtml(r.id)}<br>${escapeHtml(r.category)} / ${escapeHtml(r.subsector)}<br>Investment: ${fmt(r.investmentCost)}<br>Lifetime: ${fmt(r.economicLifetime)}<br>WACC: ${fmt(r.wacc)}`),
        hoverinfo: "text",
        marker: { size: sectorRows.map(r => Math.max(7, Math.min(24, 8 + Number(r.wacc || 0) * 60))), color: palette[index % palette.length], opacity: 0.76, line: { width: 0.8, color: "#fff" } },
      };
    });
    plotlyAtlas("atlasTechScatter", traces, { xaxis: { title: `Investment cost (${payload.selectedPeriod})`, type: "log", gridcolor: "#eef2f5" }, yaxis: { title: "Economic lifetime", gridcolor: "#eef2f5" } });
    const summary = $("atlasTechSummary");
    if (summary) summary.textContent = `${fmt(rows.length)} technologies with investment cost and lifetime.`;
  }

  function renderTechTable(rows) {
    const filtered = rows.filter(r => Number.isFinite(Number(r.investmentCost))).sort((a, b) => Number(b.investmentCost) - Number(a.investmentCost)).slice(0, 80);
    renderTable("atlasTechTable", filtered, ["id", "name", "sector", "category", "investmentCost", "economicLifetime", "wacc", "primaryActivity"], { limit: 80 });
  }

  function annuityFactor(wacc, lifetime) {
    const r = Number(wacc);
    const n = Number(lifetime);
    if (!Number.isFinite(n) || n <= 0) return 0;
    if (!Number.isFinite(r) || Math.abs(r) < 1e-10) return 1 / n;
    const growth = Math.pow(1 + r, n);
    if (!Number.isFinite(growth) || Math.abs(growth - 1) < 1e-10) return 1 / n;
    return r * growth / (growth - 1);
  }

  function buildCostRows(rows) {
    return rows.map(row => {
      const investmentCost = Number(row.investmentCost);
      const fixedOM = Number(row.fixedOM);
      const variableOM = Number(row.variableOM);
      const lifetime = Number(row.economicLifetime);
      const wacc = Number(row.wacc);
      const factor = annuityFactor(wacc, lifetime);
      const annualizedCapex = Number.isFinite(investmentCost) && investmentCost > 0 ? investmentCost * factor : 0;
      const fixedCost = Number.isFinite(fixedOM) && fixedOM > 0 ? fixedOM : 0;
      const variableCost = Number.isFinite(variableOM) && variableOM > 0 ? variableOM : 0;
      return Object.assign({}, row, {
        annualizationFactor: factor,
        annualizedCapex,
        fixedCost,
        variableCost,
        annualizedTotal: annualizedCapex + fixedCost + variableCost,
      });
    }).filter(row => row.annualizedTotal > 0 || Number(row.investmentCost) > 0 || Number(row.fixedOM) > 0 || Number(row.variableOM) > 0);
  }

  function renderCostStack(payload, rows) {
    const ranked = rows.slice().sort((a, b) => Number(b.annualizedTotal) - Number(a.annualizedTotal));
    const top = ranked.slice(0, 32).reverse();
    if (!top.length) { setAtlasEmpty("atlasCostStack", "No cost data loaded.", "atlas-chart tall empty-state"); return; }
    const labels = top.map(row => row.name || row.id);
    const hover = top.map(row => `<b>${escapeHtml(row.name || row.id)}</b><br>${escapeHtml(row.id)}<br>${escapeHtml(row.sector)} / ${escapeHtml(row.category)}<br>Investment: ${fmt(row.investmentCost)}<br>Lifetime: ${fmt(row.economicLifetime)}<br>WACC: ${fmt(row.wacc)}<br>Annualization: ${fmt(row.annualizationFactor)}`);
    const traces = [
      { type: "bar", orientation: "h", name: "Annualized CAPEX", x: top.map(row => row.annualizedCapex), y: labels, customdata: hover, hovertemplate: "%{customdata}<br>Annualized CAPEX: %{x}<extra></extra>", marker: { color: "#1d5f8f" } },
      { type: "bar", orientation: "h", name: "Fixed O&M", x: top.map(row => row.fixedCost), y: labels, customdata: hover, hovertemplate: "%{customdata}<br>Fixed O&M: %{x}<extra></extra>", marker: { color: "#5a9f3f" } },
      { type: "bar", orientation: "h", name: "Variable O&M", x: top.map(row => row.variableCost), y: labels, customdata: hover, hovertemplate: "%{customdata}<br>Variable O&M: %{x}<extra></extra>", marker: { color: "#b77800" } },
    ];
    plotlyAtlas("atlasCostStack", traces, { barmode: "stack", margin: { t: 18, r: 30, b: 54, l: 230 }, xaxis: { title: `Annualized cost (${payload.selectedPeriod})`, gridcolor: "#eef2f5", automargin: true }, yaxis: { automargin: true } }, "atlas-chart tall plotly-chart");
    const summary = $("atlasCostSummary");
    if (summary) summary.textContent = `${fmt(rows.length)} technologies with cost assumptions; showing top ${fmt(top.length)} by annualized total.`;
  }

  function renderCostTable(rows) {
    const ranked = rows.slice().sort((a, b) => Number(b.annualizedTotal) - Number(a.annualizedTotal));
    renderTable("atlasCostTable", ranked, ["id", "name", "sector", "category", "investmentCost", "economicLifetime", "wacc", "annualizationFactor", "annualizedCapex", "fixedCost", "variableCost", "annualizedTotal"], { limit: 500 });
  }

  function renderBalanceHeatmap(payload) {
    const balance = payload.balance || {};
    if (!balance.sectors || !balance.sectors.length || !balance.activities || !balance.activities.length) { setAtlasEmpty("atlasBalanceHeatmap", "No balance data loaded.", "atlas-chart tall empty-state"); return; }
    plotlyAtlas("atlasBalanceHeatmap", [{ type: "heatmap", x: balance.activities, y: balance.sectors, z: balance.z, colorscale: [[0, "#ba3a2f"], [0.5, "#f7f9fb"], [1, "#1d5f8f"]], zmid: 0, hovertemplate: "%{y}<br>%{x}<br>Net coefficient: %{z}<extra></extra>" }], { margin: { t: 16, r: 20, b: 170, l: 170 }, xaxis: { tickangle: -45, automargin: true }, yaxis: { automargin: true } }, "atlas-chart tall plotly-chart");
    const summary = $("atlasBalanceSummary");
    if (summary) summary.textContent = `${fmt(balance.sectors.length)} sectors x ${fmt(balance.activities.length)} high-signal activities.`;
  }

  function renderDemandChart(rows) {
    const top = rows.slice(0, 24).reverse();
    if (!top.length) { setAtlasEmpty("atlasDemandChart", "No demand data loaded."); return; }
    plotlyAtlas("atlasDemandChart", [{ type: "bar", orientation: "h", x: top.map(r => r.value), y: top.map(r => r.activity), text: top.map(r => `${r.type} ${r.node}`), hovertemplate: "%{y}<br>%{x}<br>%{text}<extra></extra>", marker: { color: top.map(r => Number(r.value) >= 0 ? "#1d5f8f" : "#b77800") } }], { margin: { t: 12, r: 18, b: 42, l: 190 }, xaxis: { title: "Net volume", gridcolor: "#eef2f5" }, yaxis: { automargin: true } });
  }

  function renderFlowTable(rows) {
    renderTable("atlasFlowTable", rows, ["sector", "activity", "output", "input", "net"], { limit: 80, emptyClass: "table-wrap atlas-small-table empty-state", tableClass: "table-wrap atlas-small-table" });
  }

  function renderProfileSelector(surfacePayload) {
    const select = $("atlasProfileSelect");
    if (!select) return;
    const profiles = surfacePayload.profiles || [];
    const previous = select.value;
    select.innerHTML = "";
    profiles.forEach(profile => {
      const option = document.createElement("option");
      option.value = profile;
      option.textContent = profile;
      option.selected = profile === previous;
      select.appendChild(option);
    });
    if (profiles.length && !profiles.includes(previous)) {
      const ranked = (surfacePayload.summary || []).slice().sort((a, b) => Number(b.spread) - Number(a.spread));
      const renewable = profiles.find(profile => /sun|solar|wind/i.test(profile));
      select.value = renewable || (ranked[0] && ranked[0].profile) || profiles[0];
    }
  }

  function renderProfileSurface(surfacePayload) {
    const profiles = surfacePayload.profiles || [];
    const surfaces = surfacePayload.surfaces || {};
    const select = $("atlasProfileSelect");
    const selected = select && select.value ? select.value : profiles[0];
    const z = selected ? surfaces[selected] : null;
    if (!selected || !z || !z.length) { setAtlasEmpty("atlasProfileSurface", "No profile surface loaded.", "atlas-chart tall empty-state"); return; }
    const days = surfacePayload.days || [];
    const hours = surfacePayload.hours || [];
    const traces = [{
      type: "surface",
      x: days,
      y: hours,
      z,
      colorscale: "Viridis",
      contours: { z: { show: true, usecolormap: true, highlightcolor: "#ffffff", project: { z: true } } },
      hovertemplate: "Day %{x}<br>Hour %{y}<br>Profile: %{z}<extra></extra>",
      colorbar: { title: "Level", len: 0.72, thickness: 12 },
      showscale: true,
    }];
    plotlyAtlas("atlasProfileSurface", traces, {
      margin: { t: 10, r: 8, b: 8, l: 8 },
      scene: {
        domain: { x: [0, 0.96], y: [0, 1] },
        xaxis: { title: "Day of year", gridcolor: "#dfe7ec", zerolinecolor: "#dfe7ec" },
        yaxis: { title: "Hour of day", gridcolor: "#dfe7ec", zerolinecolor: "#dfe7ec", dtick: 4 },
        zaxis: { title: "Profile level", gridcolor: "#dfe7ec", zerolinecolor: "#dfe7ec" },
        camera: { eye: { x: 1.45, y: -1.65, z: 1.35 }, center: { x: 0, y: 0, z: -0.12 } },
        aspectratio: { x: 2.05, y: 0.9, z: 0.95 },
      },
    }, "atlas-chart tall plotly-chart");
    const el = $("atlasProfileSurface");
    if (el && el._fullData && el._fullData[0] && el._fullData[0].type !== "surface") {
      renderProfileSurfaceFallback(surfacePayload, selected, z);
    }
    const summary = $("atlasProfileSurfaceSummary");
    if (summary) {
      const row = (surfacePayload.summary || []).find(item => item.profile === selected) || {};
      summary.textContent = `${selected}: min ${fmt(row.min)}, max ${fmt(row.max)}, average ${fmt(row.average)}.`;
    }
  }

  function renderProfileSurfaceFallback(surfacePayload, selected, z) {
    const days = surfacePayload.days || [];
    const hours = surfacePayload.hours || [];
    const traces = hours.filter(hour => Number(hour) % 2 === 0).map(hour => ({
      type: "scatter",
      mode: "lines",
      x: days,
      y: days.map((_, dayIndex) => Number((z[Number(hour) - 1] || [])[dayIndex] || 0) + Number(hour) * 0.00003),
      text: days.map((day, dayIndex) => `Day ${day}<br>Hour ${hour}<br>${escapeHtml(selected)}: ${fmt(Number((z[Number(hour) - 1] || [])[dayIndex] || 0))}`),
      hoverinfo: "text",
      name: `Hour ${hour}`,
      line: { width: 1.2 },
    }));
    plotlyAtlas("atlasProfileSurface", traces, { xaxis: { title: "Day of year" }, yaxis: { title: "Profile level by hour band" } }, "atlas-chart tall plotly-chart");
  }

  function renderProfileTable(rows) {
    const ranked = rows.slice().sort((a, b) => Number(b.spread) - Number(a.spread));
    renderTable("atlasProfileTable", ranked, ["profile", "min", "max", "average", "spread"], { limit: 80 });
  }

  function renderProfileHeatmap(profilePayload) {
    if (!profilePayload.profiles || !profilePayload.profiles.length) { setAtlasEmpty("atlasProfileHeatmap", "No profile data loaded.", "atlas-chart tall empty-state"); return; }
    plotlyAtlas("atlasProfileHeatmap", [{ type: "heatmap", x: profilePayload.months, y: profilePayload.profiles, z: profilePayload.z, colorscale: "Viridis", hovertemplate: "Month %{x}<br>%{y}<br>Average: %{z}<extra></extra>" }], { margin: { t: 16, r: 20, b: 52, l: 210 }, xaxis: { title: "Month", dtick: 1 }, yaxis: { automargin: true } }, "atlas-chart tall plotly-chart");
    const summary = $("atlasProfileSummary");
    if (summary) summary.textContent = `${fmt(profilePayload.profiles.length)} profile types ranked by seasonal variation.`;
  }

  function renderTargetsChart(rows) {
    const filtered = rows.filter(r => Number(r.period) > 0 && Number.isFinite(Number(r.value)));
    if (!filtered.length) { setAtlasEmpty("atlasTargetsChart", "No target data loaded."); return; }
    const groups = groupBy(filtered, row => `${row.target} / ${row.node}`);
    const traces = Object.keys(groups).sort().slice(0, 18).map((key, index) => {
      const series = groups[key].slice().sort((a, b) => Number(a.period) - Number(b.period));
      return { type: "scatter", mode: "lines+markers", name: key, x: series.map(r => r.period), y: series.map(r => r.value), marker: { color: palette[index % palette.length] }, line: { color: palette[index % palette.length], width: 2 }, hovertemplate: escapeHtml(key) + "<br>%{x}: %{y}<extra></extra>" };
    });
    plotlyAtlas("atlasTargetsChart", traces, { xaxis: { title: "Period", dtick: 5, gridcolor: "#eef2f5" }, yaxis: { title: "Target value", gridcolor: "#eef2f5" } });
    const summary = $("atlasTargetSummary");
    if (summary) summary.textContent = `${fmt(filtered.length)} period target values.`;
  }

  function renderTargetTable(rows) {
    renderTable("atlasTargetTable", rows, ["target", "node", "period", "value"], { limit: 120 });
  }

  function renderPolicyTable(rows) {
    const el = $("atlasPolicyTable");
    if (!el) return;
    const ranked = rows.slice().sort((a, b) => String(a.constraint || "").localeCompare(String(b.constraint || "")));
    if (!ranked.length) {
      el.className = "table-wrap explorer-table empty-state";
      el.textContent = "No policy constraints loaded.";
      return;
    }
    el.className = "table-wrap explorer-table policy-table";
    el.innerHTML = `<table><thead><tr><th></th><th>Constraint</th><th>Category</th><th>Description</th><th>Contents</th></tr></thead><tbody>${ranked.map((row, index) => {
      const componentText = (row.components || []).map(group => `${group.label}: ${fmt(group.count)}`).join("; ") || "No component data";
      return `<tr class="policy-row clickable-row" data-index="${index}" aria-expanded="false"><td><button class="policy-toggle" type="button" aria-label="Expand ${escapeHtml(row.constraint)}">+</button></td><td><strong>${escapeHtml(row.constraint)}</strong></td><td>${escapeHtml(row.category)}</td><td>${escapeHtml(row.description)}</td><td>${escapeHtml(componentText)}</td></tr><tr class="policy-detail-row hidden" data-detail-index="${index}"><td></td><td colspan="4">${renderPolicyComponents(row.components || [])}</td></tr>`;
    }).join("")}</tbody></table>`;
    el.querySelectorAll(".policy-row").forEach(row => row.addEventListener("click", event => {
      if (event.target && event.target.closest("a")) return;
      const index = row.dataset.index;
      const detail = el.querySelector(`tr[data-detail-index="${index}"]`);
      if (!detail) return;
      const isOpen = !detail.classList.contains("hidden");
      detail.classList.toggle("hidden", isOpen);
      row.setAttribute("aria-expanded", String(!isOpen));
      const toggle = row.querySelector(".policy-toggle");
      if (toggle) toggle.textContent = isOpen ? "+" : "-";
    }));
    const summary = $("atlasPolicySummary");
    if (summary) summary.textContent = `${fmt(rows.length)} policy-relevant constraint families. Click a row to inspect included technologies, activities, and target values.`;
  }

  function renderPolicyComponents(groups) {
    if (!groups.length) return `<div class="policy-detail empty-state">No component data loaded.</div>`;
    return `<div class="policy-detail">${groups.map(group => {
      const items = (group.items || []).map(item => `<span class="policy-chip">${escapeHtml(item)}</span>`).join("");
      const extra = Number(group.truncated || 0) > 0 ? `<span class="policy-chip muted">+${fmt(group.truncated)} more</span>` : "";
      return `<section class="policy-component"><h3>${escapeHtml(group.label)} <span>${fmt(group.count)}</span></h3><div class="policy-chip-list">${items}${extra}</div></section>`;
    }).join("")}</div>`;
  }

  function renderTable(id, rows, columns, options = {}) {
    const el = $(id);
    if (!el) return;
    const limit = options.limit || 100;
    const emptyClass = options.emptyClass || "table-wrap explorer-table empty-state";
    const tableClass = options.tableClass || "table-wrap explorer-table";
    if (!rows || !rows.length) {
      el.className = emptyClass;
      el.textContent = "No rows loaded.";
      return;
    }
    const visible = rows.slice(0, limit);
    el.className = tableClass;
    el.innerHTML = `<table><thead><tr>${columns.map(col => `<th>${escapeHtml(labelize(col))}</th>`).join("")}</tr></thead><tbody>${visible.map(row => `<tr>${columns.map(col => `<td>${escapeHtml(formatCell(row[col]))}</td>`).join("")}</tr>`).join("")}</tbody></table>`;
  }

  function labelize(value) {
    return String(value).replace(/([a-z])([A-Z])/g, "$1 $2").replace(/^./, ch => ch.toUpperCase());
  }

  function formatCell(value) {
    if (typeof value === "number") return fmt(value);
    return value ?? "";
  }

  async function loadModelBrowser() {
    const button = $("explorerBuildModel");
    if (button) { button.disabled = true; button.textContent = "Generating..."; }
    setStatus("explorerModelStatus", "Generating model snapshot.");
    setModelEmpty("Generating model snapshot...");
    try {
      const body = {
        inputWorkbook: currentWorkbook("explorerModelWorkbook"),
        period: Number($("explorerModelPeriod") && $("explorerModelPeriod").value) || undefined,
        mode: $("explorerModelMode") ? $("explorerModelMode").value : "timeslice",
        representativeDays: Number($("explorerModelRepDays") && $("explorerModelRepDays").value) || 1,
        hoursPerDay: Number($("explorerModelHours") && $("explorerModelHours").value) || 24,
      };
      const payload = await fetchJson("/api/explorer/modelBrowser", postBody(body));
      state.modelPayload = payload;
      setStatus("explorerModelStatus", "Model snapshot ready.");
      renderModelStats(payload);
      renderModelTable();
    } catch (error) {
      setStatus("explorerModelStatus", error.message, true);
      setModelEmpty(error.message);
    } finally {
      if (button) { button.disabled = false; button.textContent = "Generate browser"; }
    }
  }

  function renderModelStats(payload) {
    const stats = $("explorerModelStats");
    if (stats) {
      stats.innerHTML = `<div><dt>Rows</dt><dd>${fmt(payload.rows)}</dd></div><div><dt>Columns</dt><dd>${fmt(payload.columns)}</dd></div><div><dt>Build</dt><dd>${fmt(payload.buildSeconds)} s</dd></div>`;
    }
    const summary = $("explorerModelSummary");
    if (summary) summary.textContent = `${payload.mode} model, period ${payload.selectedPeriod}. ${fmt(payload.variables.length)} variable families and ${fmt(payload.constraints.length)} constraint families.`;
  }

  function renderModelTable() {
    const payload = state.modelPayload;
    if (!payload) { setModelEmpty("No model snapshot yet."); return; }
    const kind = $("explorerModelKind") ? $("explorerModelKind").value : "all";
    const query = ($("explorerModelSearch") ? $("explorerModelSearch").value : "").trim().toLowerCase();
    let rows = [...(payload.variables || []), ...(payload.constraints || [])];
    if (kind !== "all") rows = rows.filter(row => row.kind === kind);
    if (query) rows = rows.filter(row => `${row.family} ${row.type} ${(row.examples || []).join(" ")}`.toLowerCase().includes(query));
    const table = $("explorerModelTable");
    if (!table) return;
    if (!rows.length) { setModelEmpty("No matching families."); return; }
    table.className = "table-wrap explorer-table";
    table.innerHTML = `<table><thead><tr><th>Kind</th><th>Family</th><th>Count</th><th>Type</th><th>Examples</th></tr></thead><tbody>${rows.map(row => `<tr><td>${escapeHtml(row.kind)}</td><td><strong>${escapeHtml(row.family)}</strong></td><td>${fmt(row.count)}</td><td>${escapeHtml(row.type)}</td><td class="mono-cell">${escapeHtml((row.examples || []).join("\n"))}</td></tr>`).join("")}</tbody></table>`;
  }

  function setModelEmpty(message) {
    const table = $("explorerModelTable");
    if (!table) return;
    table.className = "table-wrap explorer-table empty-state";
    table.textContent = message;
  }

  async function loadGraph() {
    const button = $("explorerRefreshGraph");
    if (button) { button.disabled = true; button.textContent = "Refreshing..."; }
    setStatus("explorerGraphStatus", "Building graph.");
    setGraphEmpty("Building graph...");
    try {
      const body = {
        inputWorkbook: currentWorkbook("explorerGraphWorkbook"),
        period: Number($("explorerGraphPeriod") && $("explorerGraphPeriod").value) || undefined,
        sectors: checkedValues("explorerSectorFilters"),
        subsectors: checkedValues("explorerSubsectorFilters"),
        categories: checkedValues("explorerCategoryFilters"),
        maxActivities: Number($("explorerMaxActivitiesNumber") && $("explorerMaxActivitiesNumber").value) || 28,
      };
      const payload = await fetchJson("/api/explorer/techGraph", postBody(body));
      state.graphPayload = payload;
      renderGraph(payload);
      if ((document.querySelector(".tab-panel.active") || {}).id === "tab-explorer-activity-deps") renderActivityDependencyGraph(payload);
      if ((document.querySelector(".tab-panel.active") || {}).id === "tab-explorer-details") renderFlowDetails();
      renderActivityRows(payload);
      setStatus("explorerGraphStatus", "Graph ready.");
    } catch (error) {
      setStatus("explorerGraphStatus", error.message, true);
      setGraphEmpty(error.message);
    } finally {
      if (button) { button.disabled = false; button.textContent = "Refresh graph"; }
    }
  }

  function setGraphEmpty(message) {
    const el = $("explorerTechGraph");
    if (!el) return;
    if (window.Plotly && el._fullLayout) window.Plotly.purge(el);
    el.className = "explorer-graph empty-state";
    el.textContent = message;
  }

  function setActivityDependencyEmpty(message) {
    const el = $("explorerActivityGraph");
    if (el) {
      if (window.Plotly && el._fullLayout) window.Plotly.purge(el);
      el.className = "explorer-graph empty-state";
      el.textContent = message;
    }
    const body = $("explorerActivityDependencyRows");
    if (body) body.innerHTML = `<tr><td colspan="4" class="subtle">No technology paths loaded.</td></tr>`;
  }

  function renderGraph(payload) {
    const el = $("explorerTechGraph");
    if (!el) return;
    const flow = payload.systemFlows || {};
    if (!flow.nodes || !flow.nodes.length || !flow.links || !flow.links.length) {
      setGraphEmpty("No producer-consumer links for the selected filters.");
      return;
    }
    el.className = "explorer-graph plotly-chart";
    el.textContent = "";
    const diagram = buildSystemDiagram(flow);
    const headingAnnotations = [
      { x: 0.06, y: -0.015, xref: "x", yref: "y", text: "producing technologies", showarrow: false, font: { size: 13, color: "#334655" } },
      { x: 0.5, y: -0.015, xref: "x", yref: "y", text: "energy carriers / activities", showarrow: false, font: { size: 13, color: "#334655" } },
      { x: 0.94, y: -0.015, xref: "x", yref: "y", text: "consuming technologies", showarrow: false, font: { size: 13, color: "#334655" } },
    ];
    const layout = {
      margin: { t: 42, r: 12, b: 16, l: 12 },
      paper_bgcolor: "#fbfdfe",
      plot_bgcolor: "#fbfdfe",
      font: { family: "system-ui,Segoe UI,Roboto,sans-serif", size: 11, color: "#0f2436" },
      hovermode: "closest",
      showlegend: false,
      xaxis: { visible: false, range: [-0.04, 1.04], fixedrange: true, zeroline: false, showgrid: false },
      yaxis: { visible: false, range: [1.02, -0.02], fixedrange: true, zeroline: false, showgrid: false },
      annotations: [...headingAnnotations, ...diagram.activityAnnotations],
    };
    window.Plotly.react(el, diagram.traces, layout, { responsive: true, displaylogo: false, modeBarButtonsToRemove: ["lasso2d", "select2d"] });
    const summary = $("explorerGraphSummary");
    if (summary) summary.textContent = `${fmt(diagram.techCount)} technologies, ${fmt(diagram.activityCount)} carriers/activities, ${fmt(diagram.linkCount)} flow links in ${payload.selectedPeriod}.`;
    renderLegend(flow.nodes);
  }

  function renderActivityDependencyGraph(payload) {
    const el = $("explorerActivityGraph");
    if (!el) return;
    const flow = payload.systemFlows || {};
    const diagram = buildActivityDependencyDiagram(flow);
    if (!diagram.activities.length || !diagram.paths.length) {
      setActivityDependencyEmpty("No activity-to-activity paths for the selected filters.");
      return;
    }
    el.className = "explorer-graph plotly-chart";
    el.textContent = "";
    const layout = {
      margin: { t: 18, r: 18, b: 18, l: 18 },
      paper_bgcolor: "#fbfdfe",
      plot_bgcolor: "#fbfdfe",
      font: { family: "system-ui,Segoe UI,Roboto,sans-serif", size: 11, color: "#0f2436" },
      hovermode: "closest",
      showlegend: false,
      xaxis: { visible: false, range: [-1.14, 1.14], fixedrange: false, zeroline: false, showgrid: false },
      yaxis: { visible: false, range: [-1.12, 1.12], fixedrange: false, zeroline: false, showgrid: false, scaleanchor: "x", scaleratio: 1 },
      annotations: diagram.annotations,
    };
    window.Plotly.react(el, diagram.traces, layout, { responsive: true, displaylogo: false, scrollZoom: true, modeBarButtonsToRemove: ["lasso2d", "select2d"] });
    const summary = $("explorerActivityGraphSummary");
    if (summary) summary.textContent = `${fmt(diagram.activities.length)} activities connected by ${fmt(diagram.techCount)} technologies and ${fmt(diagram.paths.length)} paths in ${payload.selectedPeriod}.`;
    renderActivityDependencyLegend(diagram.groups);
    renderActivityDependencyRows(diagram.technologyRows);
  }

  function buildActivityDependencyDiagram(flow) {
    const sourceNodes = flow.nodes || [];
    const sourceLinks = flow.links || [];
    const byId = new Map(sourceNodes.map(node => [node.id, node]));
    const activities = new Map();
    const techMap = new Map();
    sourceLinks.forEach(link => {
      const source = byId.get(link.source);
      const target = byId.get(link.target);
      if (!source || !target) return;
      if (link.kind === "input" && source.kind === "activity" && target.kind === "technology") {
        const row = getTechnologyPathRow(techMap, target);
        row.inputs.push({ activity: source.rawId || source.label, group: source.group || "Other carriers", coefficient: Number(link.coefficient || -link.value || 0), value: Math.abs(Number(link.value) || 0) });
        activities.set(source.rawId || source.label, { id: source.rawId || source.label, label: source.label, group: source.group || "Other carriers" });
      } else if (link.kind === "output" && source.kind === "technology" && target.kind === "activity") {
        const row = getTechnologyPathRow(techMap, source);
        row.outputs.push({ activity: target.rawId || target.label, group: target.group || "Other carriers", coefficient: Number(link.coefficient || link.value || 0), value: Math.abs(Number(link.value) || 0) });
        activities.set(target.rawId || target.label, { id: target.rawId || target.label, label: target.label, group: target.group || "Other carriers" });
      }
    });

    const technologyRows = Array.from(techMap.values()).filter(row => row.inputs.length && row.outputs.length);
    const paths = [];
    technologyRows.forEach(row => {
      row.inputs.forEach(input => row.outputs.forEach(output => {
        paths.push({ technology: row.label, techId: row.id, sector: row.sector, input, output, weight: Math.max(input.value, 1e-6) * Math.max(output.value, 1e-6) });
      }));
    });
    paths.sort((a, b) => b.weight - a.weight);
    const visiblePaths = paths.slice(0, 220);
    const activeActivityIds = new Set();
    visiblePaths.forEach(path => { activeActivityIds.add(path.input.activity); activeActivityIds.add(path.output.activity); });
    const activityRows = Array.from(activities.values()).filter(row => activeActivityIds.has(row.id)).sort((a, b) => `${a.group}${a.label}`.localeCompare(`${b.group}${b.label}`));
    const position = new Map();
    activityRows.forEach((activity, index) => {
      const angle = (2 * Math.PI * index) / Math.max(activityRows.length, 1) - Math.PI / 2;
      position.set(activity.id, { x: Math.cos(angle), y: Math.sin(angle) });
    });
    const groups = Array.from(new Set(activityRows.map(row => row.group || "Other carriers"))).sort();
    const groupIndex = new Map(groups.map((group, index) => [group, index]));
    const traces = [];
    const techMidX = [], techMidY = [], techHover = [];
    visiblePaths.forEach((path, index) => {
      const inputPosition = position.get(path.input.activity);
      const outputPosition = position.get(path.output.activity);
      if (!inputPosition || !outputPosition) return;
      const midpoint = activityPathMidpoint(inputPosition, outputPosition, index);
      const inputHover = `<b>${escapeHtml(path.technology)}</b><br>${escapeHtml(path.input.activity)} input<br>Coefficient: ${fmt(path.input.coefficient)}<br>${escapeHtml(path.input.activity)} -> ${escapeHtml(path.output.activity)}`;
      const outputHover = `<b>${escapeHtml(path.technology)}</b><br>${escapeHtml(path.output.activity)} output<br>Coefficient: ${fmt(path.output.coefficient)}<br>${escapeHtml(path.input.activity)} -> ${escapeHtml(path.output.activity)}`;
      traces.push({ type: "scatter", mode: "lines", x: [inputPosition.x, midpoint.x], y: [inputPosition.y, midpoint.y], text: [inputHover, inputHover], hoverinfo: "text", line: { color: "rgba(186,58,47,0.28)", width: activityPathWidth(path.input.value) }, showlegend: false });
      traces.push({ type: "scatter", mode: "lines", x: [midpoint.x, outputPosition.x], y: [midpoint.y, outputPosition.y], text: [outputHover, outputHover], hoverinfo: "text", line: { color: "rgba(90,159,63,0.30)", width: activityPathWidth(path.output.value) }, showlegend: false });
      techMidX.push(midpoint.x); techMidY.push(midpoint.y); techHover.push(`<b>${escapeHtml(path.technology)}</b><br>${escapeHtml(path.techId)}<br>${escapeHtml(path.sector)}<br>${escapeHtml(path.input.activity)} -> ${escapeHtml(path.output.activity)}`);
    });
    traces.push({ type: "scatter", mode: "markers", x: techMidX, y: techMidY, hoverinfo: "text", hovertext: techHover, marker: { size: 5, color: "rgba(15,36,54,0.28)", line: { color: "#fff", width: 0.5 } }, showlegend: false });
    traces.push({
      type: "scatter",
      mode: "markers",
      x: activityRows.map(row => position.get(row.id).x),
      y: activityRows.map(row => position.get(row.id).y),
      hoverinfo: "text",
      hovertext: activityRows.map(row => `<b>${escapeHtml(row.label)}</b><br>${escapeHtml(row.group)}`),
      marker: { size: 32, color: activityRows.map(row => carrierColor(row.group || "Other carriers", groupIndex)), line: { color: "#fff", width: 1.5 }, opacity: 0.95 },
      showlegend: false,
    });
    const annotations = activityRows.map(row => {
      const pos = position.get(row.id);
      return { x: pos.x, y: pos.y, xref: "x", yref: "y", text: escapeHtml(row.label), showarrow: false, bgcolor: "rgba(251,253,254,0.78)", bordercolor: "rgba(15,36,54,0.12)", borderpad: 1, font: { size: 10, color: "#0f2436" } };
    });
    technologyRows.forEach(row => { row.pathCount = row.inputs.length * row.outputs.length; });
    technologyRows.sort((a, b) => b.pathCount - a.pathCount || a.label.localeCompare(b.label));
    return { traces, annotations, activities: activityRows, paths: visiblePaths, groups, techCount: technologyRows.length, technologyRows };
  }

  function getTechnologyPathRow(map, node) {
    const key = node.rawId || node.id;
    if (!map.has(key)) map.set(key, { id: key, label: node.label || key, sector: node.sector || "Unspecified", inputs: [], outputs: [], pathCount: 0 });
    return map.get(key);
  }

  function activityPathMidpoint(a, b, index) {
    const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
    const dx = b.x - a.x, dy = b.y - a.y;
    const length = Math.max(Math.hypot(dx, dy), 1e-6);
    const offset = (((index % 7) - 3) / 3) * 0.045;
    return { x: mx - dy / length * offset, y: my + dx / length * offset };
  }

  function activityPathWidth(value) {
    return Math.max(0.8, Math.min(5.2, 0.8 + Math.log1p(Math.abs(Number(value) || 0)) * 1.8));
  }

  function renderActivityDependencyLegend(groups) {
    const legend = $("explorerActivityGraphLegend");
    if (!legend) return;
    const groupIndex = new Map((groups || []).map((group, index) => [group, index]));
    const carrierItems = (groups || []).map(group => `<span class="legend-item"><span class="legend-swatch" style="background:${carrierColor(group, groupIndex)}"></span>${escapeHtml(group)}</span>`).join("");
    legend.innerHTML = `<span class="legend-item"><span class="legend-swatch" style="background:#ba3a2f"></span>negative input</span><span class="legend-item"><span class="legend-swatch" style="background:#5a9f3f"></span>positive output</span>${carrierItems}`;
  }

  function renderActivityDependencyRows(rows) {
    const body = $("explorerActivityDependencyRows");
    if (!body) return;
    const visible = (rows || []).slice(0, 80);
    if (!visible.length) {
      body.innerHTML = `<tr><td colspan="4" class="subtle">No technology paths loaded.</td></tr>`;
      return;
    }
    body.innerHTML = visible.map(row => `<tr><td>${escapeHtml(row.label)}</td><td>${escapeHtml(row.inputs.slice(0, 4).map(item => item.activity).join(", "))}</td><td>${escapeHtml(row.outputs.slice(0, 4).map(item => item.activity).join(", "))}</td><td>${fmt(row.pathCount)}</td></tr>`).join("");
  }

  function detailPayload() {
    const flow = state.graphPayload && state.graphPayload.detailFlows;
    if (!flow || !flow.nodes || !flow.links) return null;
    const nodes = flow.nodes || [];
    const links = flow.links || [];
    const byId = new Map(nodes.map(node => [node.id, node]));
    const incoming = new Map();
    const outgoing = new Map();
    links.forEach(link => {
      if (!byId.has(link.source) || !byId.has(link.target)) return;
      if (!outgoing.has(link.source)) outgoing.set(link.source, []);
      if (!incoming.has(link.target)) incoming.set(link.target, []);
      outgoing.get(link.source).push(link);
      incoming.get(link.target).push(link);
    });
    nodes.forEach(node => { if (!incoming.has(node.id)) incoming.set(node.id, []); if (!outgoing.has(node.id)) outgoing.set(node.id, []); });
    return { nodes, links, byId, incoming, outgoing };
  }

  function renderFlowDetails() {
    const detail = detailPayload();
    if (!detail) {
      setDetailEmpty("No detail graph loaded.");
      return;
    }
    renderDetailSearchResults(state.graphPayload);
    if (!state.detailCenterId || !detail.byId.has(state.detailCenterId)) {
      const first = detail.nodes.find(node => (detail.incoming.get(node.id) || []).length || (detail.outgoing.get(node.id) || []).length) || detail.nodes[0];
      state.detailCenterId = first ? first.id : "";
    }
    renderDetailDiagram(detail, state.detailCenterId);
  }

  function setDetailEmpty(message) {
    const graph = $("explorerDetailGraph");
    if (graph) {
      if (window.Plotly && graph._fullLayout) window.Plotly.purge(graph);
      graph.className = "explorer-graph empty-state";
      graph.textContent = message;
    }
    const results = $("explorerDetailResults");
    if (results) { results.className = "detail-search-results empty-state"; results.textContent = "No searchable items loaded."; }
    const rows = $("explorerDetailRows");
    if (rows) rows.innerHTML = `<tr><td colspan="5" class="subtle">No detail rows loaded.</td></tr>`;
    const legend = $("explorerDetailLegend");
    if (legend) legend.innerHTML = "";
  }

  function renderDetailSearchResults() {
    const detail = detailPayload();
    const box = $("explorerDetailResults");
    if (!box) return;
    if (!detail) { box.className = "detail-search-results empty-state"; box.textContent = "No searchable items loaded."; return; }
    const query = ($("explorerDetailSearch") ? $("explorerDetailSearch").value : "").trim().toLowerCase();
    let rows = detail.nodes.filter(node => (detail.incoming.get(node.id) || []).length || (detail.outgoing.get(node.id) || []).length);
    if (query) rows = rows.filter(node => `${node.label} ${node.rawId || ""} ${node.kind} ${node.sector || ""} ${node.group || ""}`.toLowerCase().includes(query));
    rows.sort((a, b) => detailNodeSort(a).localeCompare(detailNodeSort(b)));
    rows = rows.slice(0, 90);
    if (!rows.length) { box.className = "detail-search-results empty-state"; box.textContent = "No matches."; return; }
    box.className = "detail-search-results";
    box.innerHTML = rows.map(node => `<button type="button" class="detail-result ${node.id === state.detailCenterId ? "active" : ""}" data-id="${escapeHtml(node.id)}"><strong>${escapeHtml(node.label)}</strong><span>${escapeHtml(detailNodeMeta(node))}</span></button>`).join("");
    box.querySelectorAll(".detail-result").forEach(button => button.addEventListener("click", () => centerDetailNode(button.dataset.id)));
  }

  function detailNodeSort(node) {
    return `${node.kind === "activity" ? "0" : "1"}${node.group || node.sector || ""}${node.label}`;
  }

  function detailNodeMeta(node) {
    if (node.kind === "activity") return `Activity / ${node.group || "Other carriers"}`;
    return `Technology / ${node.sector || "Unspecified"} / ${node.category || ""}`;
  }

  function centerDetailNode(id) {
    const detail = detailPayload();
    if (!detail || !detail.byId.has(id)) return;
    state.detailCenterId = id;
    renderDetailSearchResults();
    renderDetailDiagram(detail, id);
  }

  function renderDetailDiagram(detail, centerId) {
    const graph = $("explorerDetailGraph");
    if (!graph) return;
    const center = detail.byId.get(centerId);
    if (!center) { setDetailEmpty("Select a technology or activity."); return; }
    const incoming = (detail.incoming.get(centerId) || []).slice().sort((a, b) => Number(b.value) - Number(a.value)).slice(0, 24);
    const outgoing = (detail.outgoing.get(centerId) || []).slice().sort((a, b) => Number(b.value) - Number(a.value)).slice(0, 24);
    const leftNodes = incoming.map(link => detail.byId.get(link.source)).filter(Boolean);
    const rightNodes = outgoing.map(link => detail.byId.get(link.target)).filter(Boolean);
    const leftPositions = lanePositions(leftNodes, 0.1);
    const rightPositions = lanePositions(rightNodes, 0.9);
    const centerPosition = { x: 0.5, y: 0.5 };
    const traces = [];
    incoming.forEach(link => {
      const node = detail.byId.get(link.source), pos = leftPositions.get(link.source);
      if (!node || !pos) return;
      traces.push(detailLineTrace(pos, centerPosition, link, node.id));
    });
    outgoing.forEach(link => {
      const node = detail.byId.get(link.target), pos = rightPositions.get(link.target);
      if (!node || !pos) return;
      traces.push(detailLineTrace(centerPosition, pos, link, node.id));
    });
    traces.push(...detailNodeTrace(leftNodes, leftPositions, "left"));
    traces.push(detailCenterTrace(center, centerPosition));
    traces.push(...detailNodeTrace(rightNodes, rightPositions, "right"));
    graph.className = "explorer-graph plotly-chart detail-graph detail-animated";
    graph.textContent = "";
    const annotations = [
      { x: 0.1, y: 0.02, xref: "x", yref: "y", text: "goes in", showarrow: false, font: { size: 13, color: "#334655" } },
      { x: 0.5, y: 0.02, xref: "x", yref: "y", text: "selected", showarrow: false, font: { size: 13, color: "#334655" } },
      { x: 0.9, y: 0.02, xref: "x", yref: "y", text: "comes out", showarrow: false, font: { size: 13, color: "#334655" } },
      ...detailAnnotations(leftNodes, leftPositions),
      ...detailAnnotations([center], new Map([[center.id, centerPosition]]), true),
      ...detailAnnotations(rightNodes, rightPositions),
    ];
    window.Plotly.react(graph, traces, {
      margin: { t: 28, r: 18, b: 20, l: 18 },
      paper_bgcolor: "#fbfdfe",
      plot_bgcolor: "#fbfdfe",
      font: { family: "system-ui,Segoe UI,Roboto,sans-serif", size: 11, color: "#0f2436" },
      hovermode: "closest",
      showlegend: false,
      xaxis: { visible: false, range: [0, 1], fixedrange: true, zeroline: false, showgrid: false },
      yaxis: { visible: false, range: [1, 0], fixedrange: true, zeroline: false, showgrid: false },
      annotations,
    }, { responsive: true, displaylogo: false, modeBarButtonsToRemove: ["lasso2d", "select2d"] });
    graph.removeAllListeners && graph.removeAllListeners("plotly_click");
    graph.on && graph.on("plotly_click", event => {
      const point = event.points && event.points[0];
      const nextId = point && point.customdata && point.customdata.id;
      if (nextId && detail.byId.has(nextId)) centerDetailNode(nextId);
    });
    const title = $("explorerDetailTitle");
    if (title) title.textContent = center.label || center.rawId || "Details";
    const summary = $("explorerDetailSummary");
    if (summary) summary.textContent = `${detailNodeMeta(center)}. ${fmt(incoming.length)} incoming and ${fmt(outgoing.length)} outgoing links shown.`;
    renderDetailLegend(center, incoming, outgoing, detail);
    renderDetailRows(center, incoming, outgoing, detail);
  }

  function lanePositions(nodes, x) {
    const positions = new Map();
    nodes.forEach((node, index) => positions.set(node.id, { x, y: (index + 1) / (nodes.length + 1) }));
    return positions;
  }

  function detailLineTrace(from, to, link, neighborId) {
    const positive = Number(link.coefficient) > 0;
    const group = link.group || detailActivityGroupName(link.activity);
    const color = withAlpha(detailGroupColor(group, "activity"), positive ? 0.58 : 0.48);
    const hover = `${positive ? "Output from technology" : "Input to technology"}<br><b>${escapeHtml(link.activity)}</b><br>Group: ${escapeHtml(group)}<br>${escapeHtml(link.technology)}<br>Energy balance coefficient: ${fmt(link.coefficient)}`;
    return { type: "scatter", mode: "lines", x: [from.x, to.x], y: [from.y, to.y], hoverinfo: "text", text: [hover, hover], customdata: [{ id: neighborId }, { id: neighborId }], line: { color, width: Math.max(1.2, Math.min(8, 1.2 + Math.log1p(Number(link.value) || 0) * 2.2)) }, showlegend: false };
  }

  function detailNodeTrace(nodes, positions, side) {
    const groups = new Map();
    nodes.forEach(node => {
      const key = `${node.kind}:${detailNodeGroup(node)}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(node);
    });
    const traces = [];
    groups.forEach(rows => traces.push({
      type: "scatter",
      mode: "markers",
      x: rows.map(node => positions.get(node.id).x),
      y: rows.map(node => positions.get(node.id).y),
      hoverinfo: "text",
      hovertext: rows.map(node => `<b>${escapeHtml(node.label)}</b><br>${escapeHtml(detailNodeMeta(node))}`),
      customdata: rows.map(node => ({ id: node.id, side })),
      marker: { size: rows[0].kind === "activity" ? 24 : 18, color: rows.map(node => detailNodeColor(node)), line: { color: "#fff", width: 1.2 }, opacity: 0.95 },
      showlegend: false,
    }));
    return traces;
  }

  function detailCenterTrace(node, position) {
    return { type: "scatter", mode: "markers", x: [position.x], y: [position.y], hoverinfo: "text", hovertext: [`<b>${escapeHtml(node.label)}</b><br>${escapeHtml(detailNodeMeta(node))}`], customdata: [{ id: node.id }], marker: { size: 42, color: detailNodeColor(node), line: { color: "#0f2436", width: 2 }, opacity: 0.98 }, showlegend: false };
  }

  function detailNodeColor(node) {
    return detailGroupColor(detailNodeGroup(node), node.kind);
  }

  function detailNodeGroup(node) {
    if (node.kind === "activity") return node.group || detailActivityGroupName(node.label || node.rawId || "");
    return node.sector || node.category || "Technology";
  }

  function detailActivityGroupName(activity) {
    const text = String(activity || "").toLowerCase();
    if (text.includes("emission") || text.includes("emitted") || text.includes("co2") || text.includes("ghg")) return "Emissions";
    if (text.includes("electric")) return "Electricity";
    if (text.includes("heat") || text.includes("steam")) return "Heat";
    if (text.includes("hydrogen") || text.includes("ammonia") || text.includes("methanol")) return "Molecules";
    if (text.includes("gas") || text.includes("methane") || text.includes("lng")) return "Gas";
    if (text.includes("diesel") || text.includes("kerosene") || text.includes("gasoline") || text.includes("naphtha") || text.includes("lpg") || text.includes("fuel")) return "Liquid fuels";
    if (text.includes("biomass") || text.includes("waste")) return "Biogenic";
    return "Other carriers";
  }

  function detailGroupColor(group, kind) {
    if (kind === "activity") return detailActivityColors[group] || detailActivityColors["Other carriers"];
    return palette[stringHash(group) % palette.length];
  }

  function stringHash(value) {
    return Array.from(String(value || "")).reduce((hash, ch) => ((hash * 31) + ch.charCodeAt(0)) >>> 0, 7);
  }

  function withAlpha(hex, alpha) {
    const clean = String(hex || "#7a6a8f").replace("#", "");
    const bigint = parseInt(clean.length === 3 ? clean.split("").map(ch => ch + ch).join("") : clean, 16);
    const r = (bigint >> 16) & 255, g = (bigint >> 8) & 255, b = bigint & 255;
    return `rgba(${r},${g},${b},${alpha})`;
  }

  function detailAnnotations(nodes, positions, center = false) {
    return nodes.map(node => {
      const pos = positions.get(node.id);
      return { x: pos.x, y: pos.y, xref: "x", yref: "y", text: escapeHtml(node.label), showarrow: false, bgcolor: center ? "rgba(255,255,255,0.92)" : "rgba(251,253,254,0.82)", bordercolor: "rgba(15,36,54,0.14)", borderpad: 2, font: { size: center ? 12 : 10, color: "#0f2436" } };
    });
  }

  function renderDetailRows(center, incoming, outgoing, detail) {
    const body = $("explorerDetailRows");
    if (!body) return;
    const rows = [];
    incoming.forEach(link => rows.push({ side: "In", node: detail.byId.get(link.source), link }));
    outgoing.forEach(link => rows.push({ side: "Out", node: detail.byId.get(link.target), link }));
    if (!rows.length) { body.innerHTML = `<tr><td colspan="5" class="subtle">No detail rows loaded.</td></tr>`; return; }
    rows.sort((a, b) => `${a.side}${detailFlowRowGroup(a)}${a.node.label}`.localeCompare(`${b.side}${detailFlowRowGroup(b)}${b.node.label}`));
    let previousGroup = "";
    body.innerHTML = rows.map(row => {
      const group = detailFlowRowGroup(row);
      const groupKey = `${row.side}:${group}`;
      const color = detailFlowRowColor(row);
      const header = groupKey !== previousGroup ? `<tr class="detail-group-row"><td colspan="5"><span class="legend-swatch" style="background:${color}"></span>${escapeHtml(row.side)} / ${escapeHtml(group)}</td></tr>` : "";
      previousGroup = groupKey;
      return `${header}<tr class="clickable-row" data-id="${escapeHtml(row.node.id)}"><td>${escapeHtml(row.side)}</td><td><span class="detail-group-chip"><span class="legend-swatch" style="background:${color}"></span>${escapeHtml(group)}</span></td><td>${escapeHtml(row.node.kind)}</td><td>${escapeHtml(row.node.label)}</td><td>${fmt(row.link.coefficient)}</td></tr>`;
    }).join("");
    body.querySelectorAll("tr[data-id]").forEach(row => row.addEventListener("click", () => centerDetailNode(row.dataset.id)));
  }

  function detailFlowRowGroup(row) {
    if (!row.node) return "Unknown";
    return row.node.kind === "activity" ? (row.link.group || detailNodeGroup(row.node)) : detailNodeGroup(row.node);
  }

  function detailFlowRowColor(row) {
    if (!row.node) return "#7a6a8f";
    return row.node.kind === "activity" ? detailGroupColor(detailFlowRowGroup(row), "activity") : detailGroupColor(detailFlowRowGroup(row), "technology");
  }

  function renderDetailLegend(center, incoming, outgoing, detail) {
    const legend = $("explorerDetailLegend");
    if (!legend) return;
    const activityGroups = new Set(["Emissions"]);
    const techGroups = new Set();
    [...incoming, ...outgoing].forEach(link => {
      activityGroups.add(link.group || detailActivityGroupName(link.activity));
      [link.source, link.target].forEach(id => {
        const node = detail.byId.get(id);
        if (node && node.kind === "technology") techGroups.add(detailNodeGroup(node));
      });
    });
    if (center && center.kind === "technology") techGroups.add(detailNodeGroup(center));
    if (center && center.kind === "activity") activityGroups.add(detailNodeGroup(center));
    const activityItems = Array.from(activityGroups).sort().map(group => `<span class="legend-item"><span class="legend-swatch" style="background:${detailGroupColor(group, "activity")}"></span>${escapeHtml(group)}</span>`).join("");
    const techItems = Array.from(techGroups).sort().slice(0, 10).map(group => `<span class="legend-item"><span class="legend-swatch" style="background:${detailGroupColor(group, "technology")}"></span>${escapeHtml(group)}</span>`).join("");
    legend.innerHTML = `<div><strong>Activity groups</strong>${activityItems}</div><div><strong>Technology groups</strong>${techItems || `<span class="subtle">No technology groups visible.</span>`}</div><div class="detail-legend-note">Line width follows absolute energy-balance coefficient; hover a flow to see the exact value.</div>`;
  }

  function buildSystemDiagram(flow) {
    const prepared = ($("explorerDiagramDetail") && $("explorerDiagramDetail").value) === "technology" ? flow : aggregateSystemFlow(flow);
    const nodes = prepared.nodes || [];
    const links = prepared.links || [];
    const index = new Map(nodes.map((node, i) => [node.id, i]));
    const validLinks = links.filter(link => index.has(link.source) && index.has(link.target));
    const sectorNames = Array.from(new Set(nodes.filter(n => n.kind === "technology").map(n => n.sector || "Unspecified"))).sort();
    const groupNames = Array.from(new Set(nodes.filter(n => n.kind === "activity").map(n => n.group || "Other carriers"))).sort();
    const sectorIndex = new Map(sectorNames.map((name, i) => [name, i]));
    const groupIndex = new Map(groupNames.map((name, i) => [name, i]));
    const lanes = { producer: nodes.filter(n => n.kind === "technology" && n.role === "producer"), activity: nodes.filter(n => n.kind === "activity"), consumer: nodes.filter(n => n.kind === "technology" && n.role === "consumer") };
    const position = new Map();
    Object.keys(lanes).forEach(lane => {
      lanes[lane].sort((a, b) => `${a.sector || a.group || ""}${a.label}`.localeCompare(`${b.sector || b.group || ""}${b.label}`));
      lanes[lane].forEach((node, i) => position.set(node.id, { x: node.kind === "activity" ? 0.5 : (node.role === "producer" ? 0.06 : 0.94), y: (i + 0.5) / Math.max(lanes[lane].length, 1) }));
    });
    const hoverLink = validLinks.map(link => `${link.kind === "output" ? "Output" : "Input"}<br><b>${escapeHtml(link.activity)}</b><br>${escapeHtml(link.technology)}<br>Coefficient: ${fmt(Math.abs(Number(link.coefficient || link.value)))}`);
    const linkTraces = validLinks.map((link, linkIndex) => {
      const source = position.get(link.source), target = position.get(link.target);
      const value = Math.abs(Number(link.value) || 0);
      const color = link.kind === "output" ? "rgba(29,95,143,0.17)" : "rgba(183,120,0,0.17)";
      return { type: "scatter", mode: "lines", x: [source.x, target.x], y: [source.y, target.y], hoverinfo: "text", text: [hoverLink[linkIndex], hoverLink[linkIndex]], line: { color, width: Math.max(0.7, Math.min(5.5, 0.7 + Math.log1p(value) * 1.7)) }, showlegend: false };
    });
    const producerTrace = nodeTrace(lanes.producer, position, node => adjustColor(palette[(sectorIndex.get(node.sector || "Unspecified") || 0) % palette.length], 0.1), "Producers", false);
    const activityTrace = nodeTrace(lanes.activity, position, node => carrierColor(node.group || "Other carriers", groupIndex), "Carriers", false, 14);
    const consumerTrace = nodeTrace(lanes.consumer, position, node => adjustColor(palette[(sectorIndex.get(node.sector || "Unspecified") || 0) % palette.length], -0.04), "Consumers", false);
    const activityAnnotations = lanes.activity.map(node => {
      const pos = position.get(node.id) || { x: 0.5, y: 0.5 };
      return { x: pos.x, y: pos.y, xref: "x", yref: "y", text: escapeHtml(node.label), showarrow: false, bgcolor: "rgba(251,253,254,0.86)", bordercolor: "rgba(15,36,54,0.16)", borderpad: 2, font: { size: 10, color: "#0f2436" } };
    });
    return {
      techCount: new Set(nodes.filter(n => n.kind === "technology").map(n => n.rawId)).size,
      activityCount: nodes.filter(n => n.kind === "activity").length,
      linkCount: validLinks.length,
      activityAnnotations,
      traces: [...linkTraces, producerTrace, activityTrace, consumerTrace],
    };
  }

  function aggregateSystemFlow(flow) {
    const sourceNodes = flow.nodes || [];
    const sourceLinks = flow.links || [];
    const byId = new Map(sourceNodes.map(node => [node.id, node]));
    const nodes = new Map();
    const links = new Map();
    function mappedNode(original) {
      if (!original) return null;
      if (original.kind === "activity") return Object.assign({}, original);
      const role = original.role || "technology";
      const sector = original.sector || "Unspecified";
      const category = original.category || "Technology";
      return {
        id: `group:${role}:${sector}:${category}`,
        label: `${sector} / ${category}`,
        kind: "technology",
        role,
        rawId: `${sector} / ${category}`,
        sector,
        subsector: original.subsector || "",
        category,
      };
    }
    sourceLinks.forEach(link => {
      const source = mappedNode(byId.get(link.source));
      const target = mappedNode(byId.get(link.target));
      if (!source || !target) return;
      nodes.set(source.id, source);
      nodes.set(target.id, target);
      const key = `${source.id}\0${target.id}\0${link.activity}\0${link.kind}`;
      const row = links.get(key) || { source: source.id, target: target.id, value: 0, activity: link.activity, kind: link.kind, technology: "Grouped technologies", coefficient: 0 };
      row.value += Math.abs(Number(link.value) || 0);
      row.coefficient += Math.abs(Number(link.coefficient || link.value) || 0);
      links.set(key, row);
    });
    return { nodes: Array.from(nodes.values()), links: Array.from(links.values()) };
  }

  function nodeTrace(nodes, position, colorFn, name, showText, markerSize) {
    return {
      type: "scatter",
      mode: showText ? "markers+text" : "markers",
      name,
      x: nodes.map(node => (position.get(node.id) || {}).x),
      y: nodes.map(node => (position.get(node.id) || {}).y),
      text: showText ? nodes.map(node => node.label) : undefined,
      textposition: "middle center",
      hoverinfo: "text",
      hovertext: nodes.map(node => node.kind === "activity" ? `<b>${escapeHtml(node.label)}</b><br>${escapeHtml(node.group || "Carrier")}` : `<b>${escapeHtml(node.label)}</b><br>${escapeHtml(node.rawId || "")}<br>${escapeHtml(node.sector || "")} / ${escapeHtml(node.subsector || "")}<br>${node.role === "producer" ? "Produces into carriers" : "Consumes from carriers"}`),
      marker: { size: markerSize || (showText ? 18 : 8), color: nodes.map(colorFn), line: { color: "#fff", width: 1.1 }, opacity: showText ? 0.95 : 0.88 },
      textfont: { size: 10, color: "#0f2436" },
      showlegend: false,
    };
  }

  function carrierColor(group, groupIndex) {
    const fixed = {
      Electricity: "#4778c4",
      Heat: "#c80f1e",
      Molecules: "#74ad45",
      Gas: "#f2b705",
      Emissions: "#8a5a2b",
      CO2: "#8a5a2b",
      "Liquid fuels": "#c56f2c",
      Biogenic: "#5aa06f",
    };
    return fixed[group] || palette[(groupIndex.get(group) || 0) % palette.length];
  }

  function computePositions(nodes) {
    const sectors = groupBy(nodes, node => node.sector || "Unspecified");
    const sectorNames = Object.keys(sectors).sort();
    const positions = {};
    const mainRadius = Math.max(2.2, sectorNames.length * 0.55);
    sectorNames.forEach((sector, sectorIndex) => {
      const angle = (2 * Math.PI * sectorIndex) / Math.max(sectorNames.length, 1) - Math.PI / 2;
      const cx = Math.cos(angle) * mainRadius;
      const cy = Math.sin(angle) * mainRadius;
      const sectorNodes = sectors[sector].slice().sort((a, b) => `${a.subsector}${a.name}`.localeCompare(`${b.subsector}${b.name}`));
      const localRadius = Math.max(0.45, Math.sqrt(sectorNodes.length) * 0.22);
      sectorNodes.forEach((node, nodeIndex) => {
        const localAngle = (2 * Math.PI * nodeIndex) / Math.max(sectorNodes.length, 1);
        const jitter = (nodeIndex % 5) * 0.035;
        positions[node.id] = { x: cx + Math.cos(localAngle) * (localRadius + jitter), y: cy + Math.sin(localAngle) * (localRadius + jitter) };
      });
    });
    return positions;
  }

  function groupBy(rows, fn) {
    return rows.reduce((acc, row) => {
      const key = fn(row);
      if (!acc[key]) acc[key] = [];
      acc[key].push(row);
      return acc;
    }, {});
  }

  function buildEdgeLineTrace(edges, positions) {
    const x = [], y = [];
    edges.forEach(edge => {
      const a = positions[edge.from], b = positions[edge.to];
      if (!a || !b) return;
      x.push(a.x, b.x, null);
      y.push(a.y, b.y, null);
    });
    return { type: "scatter", mode: "lines", x, y, hoverinfo: "skip", line: { color: "rgba(96,112,128,0.24)", width: 1 }, showlegend: false };
  }

  function buildEdgeHoverTrace(edges, positions) {
    const x = [], y = [], text = [];
    edges.forEach(edge => {
      const a = positions[edge.from], b = positions[edge.to];
      if (!a || !b) return;
      x.push((a.x + b.x) / 2);
      y.push((a.y + b.y) / 2);
      text.push(`<b>${escapeHtml(edge.activity)}</b><br>${escapeHtml(edge.from)} -> ${escapeHtml(edge.to)}<br>Output: ${fmt(edge.outputRatio)}<br>Input: ${fmt(edge.inputRatio)}<br>Input/output: ${fmt(edge.inputOutputRatio)}`);
    });
    return { type: "scatter", mode: "markers", x, y, text, hoverinfo: "text", marker: { size: 14, color: "rgba(29,95,143,0.02)" }, showlegend: false };
  }

  function buildNodeTraces(nodes, positions) {
    const sectors = groupBy(nodes, node => node.sector || "Unspecified");
    const sectorNames = Object.keys(sectors).sort();
    const subsectorIndex = new Map();
    return sectorNames.map((sector, sectorIndex) => {
      const rows = sectors[sector];
      const x = [], y = [], text = [], colors = [], sizes = [];
      rows.forEach(node => {
        const pos = positions[node.id];
        if (!pos) return;
        x.push(pos.x); y.push(pos.y);
        colors.push(colorForNode(node, sectorIndex, subsectorIndex));
        sizes.push(10 + Math.min(10, (node.inputs || []).length + (node.outputs || []).length));
        text.push(nodeHover(node));
      });
      return { type: "scatter", mode: "markers", name: sector, x, y, text, hoverinfo: "text", marker: { size: sizes, color: colors, line: { width: 1.2, color: "#fff" }, opacity: 0.94 } };
    });
  }

  function colorForNode(node, sectorIndex, subsectorIndex) {
    const key = `${node.sector}||${node.subsector}`;
    if (!subsectorIndex.has(key)) subsectorIndex.set(key, subsectorIndex.size);
    const base = palette[sectorIndex % palette.length];
    const shift = (subsectorIndex.get(key) % 5) * 0.08 - 0.12;
    return adjustColor(base, shift);
  }

  function adjustColor(hex, amount) {
    const n = parseInt(hex.slice(1), 16);
    let r = (n >> 16) & 255, g = (n >> 8) & 255, b = n & 255;
    const target = amount >= 0 ? 255 : 0;
    const f = Math.abs(amount);
    r = Math.round(r + (target - r) * f);
    g = Math.round(g + (target - g) * f);
    b = Math.round(b + (target - b) * f);
    return `rgb(${r},${g},${b})`;
  }

  function nodeHover(node) {
    const inputs = (node.inputs || []).slice(0, 4).map(row => `${escapeHtml(row.activity)}: ${fmt(Math.abs(row.coefficient))}`).join("<br>") || "None";
    const outputs = (node.outputs || []).slice(0, 4).map(row => `${escapeHtml(row.activity)}: ${fmt(row.coefficient)}`).join("<br>") || "None";
    return `<b>${escapeHtml(node.name || node.id)}</b><br>${escapeHtml(node.id)}<br>${escapeHtml(node.sector)} / ${escapeHtml(node.subsector)}<br>Category: ${escapeHtml(node.category)}<br><br><b>Inputs</b><br>${inputs}<br><br><b>Outputs</b><br>${outputs}`;
  }

  function renderLegend(nodes) {
    const legend = $("explorerGraphLegend");
    if (!legend) return;
    const groups = Array.from(new Set((nodes || []).filter(node => node.kind === "activity").map(node => node.group || "Other carriers"))).sort();
    const groupIndex = new Map(groups.map((name, i) => [name, i]));
    legend.innerHTML = groups.map(group => `<span class="legend-item"><span class="legend-swatch" style="background:${carrierColor(group, groupIndex)}"></span>${escapeHtml(group)}</span>`).join("");
  }

  function renderActivityRows(payload) {
    const body = $("explorerActivityRows");
    if (!body) return;
    const rows = payload.activities || [];
    if (!rows.length) {
      body.innerHTML = `<tr><td colspan="4" class="subtle">No activities loaded.</td></tr>`;
      return;
    }
    body.innerHTML = rows.map(row => `<tr><td>${escapeHtml(row.activity)}</td><td>${fmt(row.producers)}</td><td>${fmt(row.consumers)}</td><td>${fmt(row.edges)}</td></tr>`).join("");
  }

  window.IESAExplorer = { populateForm };
})();