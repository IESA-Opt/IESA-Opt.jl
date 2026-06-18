(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const DAYS_PER_YEAR = 360;
  const state = { options: null, solvers: [], preview: null, campaignId: null, results: [], status: null, campaigns: [], investmentSpread: [], baselineInvestments: [], investmentSort: "max" };

  function escapeHtml(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  function populateForm(options, solvers) {
    state.options = options || {};
    state.solvers = Array.isArray(solvers) ? solvers : [];
    const d = state.options.defaults || {};
    fillSelect("mgaInputWorkbook", state.options.scenarios || [], d.inputWorkbook);
    fillSelect("mgaClusteringApproach", state.options.clusteringApproaches || [], d.clusteringApproach);
    fillSelect("mgaConstraintGroup", state.options.constraintGroups || [], d.constraintGroup);
    renderPeriods("mgaPeriods", state.options.periods || [], d.periods || []);
    renderHours("mgaHoursPerDay", state.options.hoursPerDayOptions || [], d.hoursPerDay || 24);
    renderSolveMethods("mgaSolveMethod", state.options.solveMethods || [], d.solveMethod || "barrier_crossover");
    populateSolvers(state.solvers, d.solver);
    const rd = Number(d.representativeDays || 15);
    if ($("mgaRepresentativeDays")) $("mgaRepresentativeDays").value = String(rd);
    if ($("mgaRepresentativeDaysNumber")) $("mgaRepresentativeDaysNumber").value = String(rd);
    configureThreadSlider();
    bind();
    updateTimeSlicingControls();
    updateTotalSlices();
    updateScenarioSummary();
    updateSummaries();
  }

  function fillSelect(id, values, selected) {
    const s = $(id);
    if (!s) return;
    s.innerHTML = "";
    const opts = values.includes(selected) ? values : [selected, ...values].filter(Boolean);
    opts.forEach((v) => {
      const o = document.createElement("option");
      o.value = v;
      o.textContent = v;
      o.selected = v === selected;
      s.appendChild(o);
    });
  }

  function populateSolvers(solvers, defaultId) {
    const select = $("mgaSolver");
    if (!select) return;
    select.innerHTML = "";
    state.solvers = Array.isArray(solvers) ? solvers : [];
    const def = state.solvers.find((x) => x.default && x.available)
             || state.solvers.find((x) => x.id === defaultId && x.available)
             || state.solvers.find((x) => x.available);
    state.solvers.forEach((solver) => {
      const option = document.createElement("option");
      option.value = solver.id;
      option.textContent = solver.available ? solverLabel(solver) : `${solver.label} unavailable`;
      option.disabled = !solver.available;
      option.selected = def && solver.id === def.id;
      select.appendChild(option);
    });
    updateSolverDetails();
  }

  function solverLabel(solver) { return solver.version ? `${solver.label} (${solver.version})` : solver.label; }

  function updateSolverDetails() {
    const select = $("mgaSolver");
    if (!select) return;
    const solver = (state.solvers || []).find((x) => x.id === select.value);
    const detail = solver ? solver.message || "" : "";
    const detailEl = $("mgaSolverDetails");
    if (detailEl) { detailEl.textContent = detail; detailEl.classList.toggle("hidden", !detail); }
    const label = $("mgaSelectedSolverLabel");
    if (label) label.textContent = solver ? solver.label : "-";
  }

  function renderPeriods(id, periods, selected) {
    const w = $(id);
    if (!w) return;
    w.innerHTML = "";
    const selectedSet = new Set((selected || []).map((p) => String(p)));
    periods.forEach((p) => {
      const l = document.createElement("label");
      l.innerHTML = `<input type="checkbox" value="${p}"><span>${p}</span>`;
      const input = l.querySelector("input");
      input.checked = selectedSet.has(String(p));
      input.addEventListener("change", () => { updateScenarioSummary(); updateSummaries(); });
      w.appendChild(l);
    });
  }

  function renderHours(id, hours, selected) {
    const w = $(id);
    if (!w) return;
    w.innerHTML = "";
    hours.forEach((h) => {
      const l = document.createElement("label");
      l.innerHTML = `<input type="radio" name="mgaHoursPerDay" value="${h}"><span>${h}</span>`;
      const input = l.querySelector("input");
      input.checked = Number(h) === Number(selected);
      input.addEventListener("change", updateTotalSlices);
      w.appendChild(l);
    });
  }

  function renderSolveMethods(id, methods, selected) {
    const w = $(id);
    if (!w) return;
    w.innerHTML = "";
    methods.forEach((m) => {
      const l = document.createElement("label");
      const safe = String(m.label || "").replace(/[<>&"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" }[c]));
      const help = window.IESASolverMethodHelp ? window.IESASolverMethodHelp(m) : null;
      if (help) {
        l.dataset.helpTitle = help.title;
        l.dataset.help = help.short.join("\n");
        l.dataset.helpMore = help.more;
      }
      l.innerHTML = `<input type="radio" name="mgaSolveMethod" value="${m.id}"><span>${safe}</span>`;
      l.querySelector("input").checked = m.id === selected;
      w.appendChild(l);
    });
  }

  function currentHoursPerDay() {
    const checked = document.querySelector("input[name='mgaHoursPerDay']:checked");
    return checked ? Number(checked.value) : 24;
  }

  function currentSolveMethod() {
    const checked = document.querySelector("input[name='mgaSolveMethod']:checked");
    return checked ? checked.value : "barrier_crossover";
  }

  function updateTotalSlices() {
    const ts = $("mgaTimeSlicingToggle");
    if (!ts) return;
    const tsOn = ts.checked;
    const total = tsOn
      ? Number(($("mgaRepresentativeDays") || {}).value || 0) * 24
      : DAYS_PER_YEAR * currentHoursPerDay();
    if ($("mgaTotalSlices")) $("mgaTotalSlices").value = String(total);
  }

  function updateTimeSlicingControls() {
    const ts = $("mgaTimeSlicingToggle");
    if (!ts) return;
    const tsOn = ts.checked;
    if ($("mgaHoursPerDayField")) $("mgaHoursPerDayField").classList.toggle("hidden", tsOn);
    if ($("mgaRepresentativeDaysField")) $("mgaRepresentativeDaysField").classList.toggle("hidden", !tsOn);
    if ($("mgaClusteringApproachField")) $("mgaClusteringApproachField").classList.toggle("hidden", !tsOn);
    if ($("mgaExtremeDaysField")) $("mgaExtremeDaysField").classList.toggle("hidden", !tsOn);
  }

  function updateScenarioSummary() {
    const wb = (($("mgaInputWorkbook") || {}).value || "");
    const periods = [...document.querySelectorAll("#mgaPeriods input:checked")].map((i) => i.value);
    const sum = $("mgaScenarioSummary");
    if (sum) sum.textContent = `${wb || "No workbook"} - ${periods.length ? periods.join(", ") : "no years"}`;
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
    syncRange("mgaThreads", "mgaThreadsNumber", updateSummaries);
    syncRange("mgaRepresentativeDays", "mgaRepresentativeDaysNumber", updateTotalSlices);
    const ts = $("mgaTimeSlicingToggle");
    if (ts && !ts.dataset.bound) {
      ts.dataset.bound = "1";
      ts.addEventListener("change", () => { updateTimeSlicingControls(); updateTotalSlices(); });
    }
    const solver = $("mgaSolver");
    if (solver && !solver.dataset.bound) {
      solver.dataset.bound = "1";
      solver.addEventListener("change", () => { updateSolverDetails(); updateSummaries(); });
    }
    const wb = $("mgaInputWorkbook");
    if (wb && !wb.dataset.bound) {
      wb.dataset.bound = "1";
      wb.addEventListener("change", updateScenarioSummary);
    }
    ["mgaCostSlack", "mgaDirections", "mgaTolerance", "mgaOracleIterations", "mgaOracleBatch", "mgaExtremeDays", "mgaExtremePeriods", "mgaBoundaryRamping", "mgaConstraintGroup", "mgaClusteringApproach"].forEach((id) => {
      const el = $(id);
      if (el && !el.dataset.bound) {
        el.dataset.bound = "1";
        el.addEventListener("input", updateSummaries);
        el.addEventListener("change", updateSummaries);
      }
    });
    bindMgaResultsControls();
  }

  function bindMgaResultsControls() {
    const refresh = $("mgaRefreshCampaigns");
    if (refresh && !refresh.dataset.bound) {
      refresh.dataset.bound = "1";
      refresh.addEventListener("click", () => {
        fetchMgaCampaigns().catch((err) => console.warn("mga campaigns refresh failed", err));
      });
    }
    document.querySelectorAll('.tab-button[data-section="mga"][data-tab="mga-results"]').forEach((btn) => {
      if (btn.dataset.boundResults) return;
      btn.dataset.boundResults = "1";
      btn.addEventListener("click", () => {
        fetchMgaCampaigns().catch((err) => console.warn("mga campaigns autoload failed", err));
      });
    });
    const sort = $("mgaInvestmentSort");
    if (sort && !sort.dataset.bound) {
      sort.dataset.bound = "1";
      sort.value = state.investmentSort || "max";
      sort.addEventListener("change", () => {
        state.investmentSort = sort.value || "max";
        renderInvestmentInsights();
      });
    }
  }

  async function fetchMgaCampaigns() {
    const r = await fetch("/api/mga/campaigns", { cache: "no-store" });
    const payload = await r.json().catch(() => ({}));
    if (!payload || payload.ok === false) {
      state.campaigns = [];
      renderMgaCampaignList(payload && payload.error);
      return;
    }
    state.campaigns = Array.isArray(payload.campaigns) ? payload.campaigns : [];
    renderMgaCampaignList();
  }

  function renderMgaCampaignList(error) {
    const list = $("mgaCampaignList");
    const summary = $("mgaCampaignListSummary");
    const rows = state.campaigns || [];
    if (summary) {
      summary.textContent = error ? "Could not load campaigns." : `${rows.length} campaign${rows.length === 1 ? "" : "s"} available.`;
      if (window.IESAExplainStatus) window.IESAExplainStatus(summary, error || summary.textContent, error ? "error" : "");
    }
    if (!list) return;
    list.innerHTML = "";
    if (error) {
      list.className = "scenario-campaign-list empty-state";
      list.textContent = String(error);
      if (window.IESAExplainStatus) window.IESAExplainStatus(list, error, "error");
      return;
    }
    if (!rows.length) {
      list.className = "scenario-campaign-list empty-state";
      list.textContent = "No MGA campaigns yet.";
      return;
    }
    list.className = "scenario-campaign-list";
    rows.forEach((c) => list.appendChild(renderMgaCampaignItem(c)));
  }

  function renderMgaCampaignItem(c) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "scenario-campaign-item" + (c.id === state.campaignId ? " active" : "");
    const finished = Number(c.completed || 0) + Number(c.failed || 0);
    const total = Number(c.total || 0);
    const started = c.started_at ? formatStartedClock(Number(c.started_at) * 1000) : "";
    const solverLabel = (c.solver ? prettifySolver(c.solver) : "") + (c.solveMethod ? ` \u00b7 ${String(c.solveMethod).replace(/_/g, " ")}` : "");
    const slack = Number.isFinite(Number(c.costSlack)) ? `${Number(c.costSlack).toFixed(1)}% slack` : "";
    btn.innerHTML = `<span class="scenario-campaign-name">${escapeHtml(c.name || c.id)}</span>`
      + `<span class="scenario-campaign-meta">${escapeHtml(c.state || "unknown")} \u00b7 ${finished}/${total} done \u00b7 ${Number(c.result_count || 0)} alternatives</span>`
      + (solverLabel ? `<span class="scenario-campaign-meta">${escapeHtml(solverLabel)}${slack ? ` \u00b7 ${escapeHtml(slack)}` : ""}</span>` : (slack ? `<span class="scenario-campaign-meta">${escapeHtml(slack)}</span>` : ""))
      + (started ? `<span class="scenario-campaign-time">Started ${escapeHtml(started)}</span>` : "");
    btn.addEventListener("click", () => {
      state.campaignId = c.id;
      renderMgaCampaignList();
      loadResult(c.id).catch((err) => renderError(err));
    });
    return btn;
  }

  function formatStartedClock(ms) {
    const d = new Date(ms);
    if (Number.isNaN(d.getTime())) return "";
    const yyyy = d.getFullYear();
    const mm = String(d.getMonth() + 1).padStart(2, "0");
    const dd = String(d.getDate()).padStart(2, "0");
    const hh = String(d.getHours()).padStart(2, "0");
    const mi = String(d.getMinutes()).padStart(2, "0");
    return `${yyyy}-${mm}-${dd} ${hh}:${mi}`;
  }

  function detectedCpuThreads() {
    const fromOptions = Number(state.options && state.options.cpuThreads);
    if (Number.isFinite(fromOptions) && fromOptions > 0) return Math.round(fromOptions);
    const fromBrowser = Number(navigator.hardwareConcurrency || 0);
    return Number.isFinite(fromBrowser) && fromBrowser > 0 ? Math.round(fromBrowser) : 64;
  }

  function configureThreadSlider() {
    const maxThreads = String(Math.max(4, detectedCpuThreads()));
    const slider = $("mgaThreads");
    const number = $("mgaThreadsNumber");
    if (slider) slider.max = maxThreads;
    if (number) number.max = maxThreads;
  }

  function syncRange(rangeId, numberId, callback) {
    const range = $(rangeId);
    const number = $(numberId);
    if (!range || !number || range.dataset.synced) return;
    range.dataset.synced = "1";
    const update = (value) => {
      range.value = value;
      number.value = value;
      if (callback) callback();
    };
    range.addEventListener("input", () => update(range.value));
    number.addEventListener("input", () => update(number.value));
  }

  function collectConfig() {
    const ts = ($("mgaTimeSlicingToggle") || {}).checked !== false;
    return {
      name: ($("mgaName") && $("mgaName").value) || "mga_campaign",
      inputWorkbook: ($("mgaInputWorkbook") && $("mgaInputWorkbook").value) || "Input/default_data.xlsx",
      mode: ts ? "timeslice" : "full_hourly",
      periods: [...document.querySelectorAll("#mgaPeriods input:checked")].map((i) => Number(i.value)),
      representativeDays: Number(($("mgaRepresentativeDays") && $("mgaRepresentativeDays").value) || 15),
      hoursPerDay: currentHoursPerDay(),
      clusteringApproach: ($("mgaClusteringApproach") && $("mgaClusteringApproach").value) || "kmeans_avg",
      extremePeriods: !!($("mgaExtremePeriods") && $("mgaExtremePeriods").checked),
      extremeDays: Number(($("mgaExtremeDays") && $("mgaExtremeDays").value) || 5),
      boundaryRamping: !!($("mgaBoundaryRamping") && $("mgaBoundaryRamping").checked),
      constraintGroup: ($("mgaConstraintGroup") && $("mgaConstraintGroup").value) || "Base + Bunkers + Scope3",
      solver: ($("mgaSolver") && $("mgaSolver").value) || "highs",
      solveMethod: currentSolveMethod(),
      costSlack: Number(($("mgaCostSlack") && $("mgaCostSlack").value) || 5),
      directions: Number(($("mgaDirections") && $("mgaDirections").value) || 6),
      workers: 1,
      threads: Number(($("mgaThreads") && $("mgaThreads").value) || 0),
      tolerance: Number(($("mgaTolerance") && $("mgaTolerance").value) || 0.1),
      oracleIterations: Number(($("mgaOracleIterations") && $("mgaOracleIterations").value) || 1),
      oracleBatch: Number(($("mgaOracleBatch") && $("mgaOracleBatch").value) || 1),
      method: "hybrid-oracle-mga",
    };
  }

  function updateSummaries() {
    const cfg = collectConfig();
    const slack = $("mgaSlackSummary");
    const dirs = $("mgaDirectionSummary");
    const tolerance = $("mgaToleranceSummary");
    if (slack) slack.textContent = `${cfg.costSlack}%`;
    if (dirs) dirs.textContent = String(cfg.directions);
    if (tolerance) tolerance.textContent = String(cfg.tolerance);
    const label = $("mgaSelectedSolverLabel");
    if (label) {
      const s = (state.solvers || []).find((x) => x.id === cfg.solver);
      label.textContent = s ? s.label : cfg.solver;
    }
  }

  async function postJson(url, body) {
    const response = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, cache: "no-store", body: JSON.stringify(body) });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || payload.ok === false) {
      const detail = payload.error ? `${url}: ${payload.error}` : `${url}: ${response.status} ${response.statusText}`;
      throw new Error(detail || "Request failed");
    }
    return payload;
  }

  async function previewMga() {
    setTitle("Planning MGA design", "Loading workbook and building hybrid ORACLE directions.");
    const payload = await postJson("/api/mga/preview", collectConfig());
    state.preview = payload;
    setTitle("MGA design ready", "Review seed and ORACLE refinement directions, then run the campaign.");
    renderPreview(payload);
    renderProgress(payload);
  }

  function showProgressTab() {
    const btn = document.querySelector('.tab-button[data-section="mga"][data-tab="mga-progress"]');
    if (btn && !btn.disabled) btn.click();
  }

  async function runMga() {
    setTitle("Running MGA", "Dispatching hybrid ORACLE alternatives.");
    showProgressTab();
    const payload = await postJson("/api/mga/run", collectConfig());
    state.campaignId = payload.campaign_id || payload.id || (payload.snapshot && payload.snapshot.id);
    if (!state.campaignId) throw new Error("/api/mga/run did not return a campaign id.");
    renderProgress(payload.snapshot || payload);
    fetchMgaCampaigns().catch((err) => console.warn("mga campaigns refresh failed", err));
    await pollResult(state.campaignId);
  }

  async function pollResult(id) {
    for (let attempt = 0; attempt < 1800; attempt += 1) {
      const url = "/api/mga/status/" + encodeURIComponent(id);
      const response = await fetch(url, { cache: "no-store" });
      const payload = await response.json().catch(() => ({}));
      if (!response.ok || payload.ok === false) throw new Error(payload.error || `${url}: ${response.status} ${response.statusText}` || "Could not load MGA status");
      state.status = payload;
      renderProgress(payload);
      const campaign = payload.campaign || {};
      setTitle("Running MGA", `${Number(campaign.completed || 0)}/${Number(campaign.total || 0)} alternatives prepared.`);
      if (campaign.state === "failed") {
        throw new Error(campaign.stage || "MGA campaign failed.");
      }
      if (payload.done || campaign.state === "completed") {
        await loadResult(id);
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    setTitle("MGA still running", "The exact solver-backed campaign is still running. Keep the Progress tab open for updates.");
  }

  async function loadResult(id) {
    const url = "/api/mga/result/" + encodeURIComponent(id);
    const response = await fetch(url, { cache: "no-store" });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || payload.ok === false) throw new Error(payload.error || `${url}: ${response.status} ${response.statusText}` || "Could not load MGA result");
    state.campaignId = id;
    state.results = Array.isArray(payload.results) ? payload.results : [];
    renderResults(payload);
    renderProgress(payload);
    setTitle("MGA complete", `${state.results.length} alternatives prepared.`);
    fetchMgaCampaigns().catch((err) => console.warn("mga campaigns refresh failed", err));
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
    const cert = payload.certificate || {};
    if (method) method.textContent = `${payload.description || "Hybrid ORACLE MGA design loaded."} Estimated max error: ${formatMaybe(cert.estimatedMaxError)}; target: ${formatMaybe(cert.targetTolerance)}.`;
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
      return `<tr><td>${escapeHtml(d.id)}</td><td>${escapeHtml(d.phase || "seed")}</td><td>${escapeHtml(d.dominantGroup)}</td><td>${formatMaybe(d.maxError)}</td><td>${summary}</td></tr>`;
    }).join("");
    el.innerHTML = `<table><thead><tr><th>Direction</th><th>Phase</th><th>Dominant group</th><th>Max error</th><th>Largest weights</th></tr></thead><tbody>${rows}</tbody></table>`;
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
    el.textContent = "";
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
    const cert = payload.certificate || {};
    if (summary) summary.textContent = rows.length ? `${rows.length} MGA alternatives available within ${payload.config.costSlack}% cost slack. Estimated max error ${formatMaybe(cert.estimatedMaxError)}.` : "No MGA results loaded.";
    renderCertificate(cert);
    renderOracleChart(Array.isArray(payload.oracleTrace) ? payload.oracleTrace : []);
    renderResultChart(rows);
    renderResultTable(rows);
    state.investmentSpread = Array.isArray(payload.investmentSpread) ? payload.investmentSpread : [];
    state.baselineInvestments = Array.isArray(payload.baselineInvestments) ? payload.baselineInvestments : [];
    renderInvestmentInsights();
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
    el.textContent = "";
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
    const body = rows.map((r) => `<tr><td>${escapeHtml(r.direction)}</td><td>${escapeHtml(r.phase)}</td><td>${escapeHtml(r.status || "")}</td><td>${escapeHtml(r.dominantGroup)}</td><td>${formatMaybe(r.systemCost)}</td><td>${formatMaybe(r.costIndex)}</td><td>${formatMaybe(r.slackUsed)}</td><td>${formatMaybe(r.diversityScore)}</td><td>${formatMaybe(r.maxError)}</td><td>${escapeHtml(r.solver || "")}</td></tr>`).join("");
    el.innerHTML = `<table><thead><tr><th>Direction</th><th>Phase</th><th>Status</th><th>Dominant group</th><th>System cost</th><th>Cost index</th><th>Slack used</th><th>Diversity</th><th>Max error</th><th>Solver</th></tr></thead><tbody>${body}</tbody></table>`;
  }

  function renderInvestmentInsights() {
    const spread = Array.isArray(state.investmentSpread) ? state.investmentSpread : [];
    const summaryEl = $("mgaInvestmentSummary");
    const envelopeEl = $("mgaInvestmentEnvelope");
    const lowRegretEl = $("mgaLowRegretTable");
    const highVolEl = $("mgaHighVolatilityTable");
    if (!spread.length) {
      if (summaryEl) summaryEl.textContent = "Run an MGA campaign to see which technologies the alternatives invest in.";
      if (envelopeEl) { envelopeEl.className = "atlas-chart empty-state"; envelopeEl.textContent = "No investment data loaded."; }
      if (lowRegretEl) { lowRegretEl.className = "table-wrap explorer-table empty-state"; lowRegretEl.textContent = "No low-regret investments detected."; }
      if (highVolEl) { highVolEl.className = "table-wrap explorer-table empty-state"; highVolEl.textContent = "No high-volatility investments detected."; }
      return;
    }
    const altCount = Number((spread[0] && spread[0].alternativeCount) || 0);
    const everyAlt = spread.filter((r) => Number(r.share) >= 0.999 && Number(r.max) > 1e-6).length;
    const optional = spread.filter((r) => Number(r.share) > 0 && Number(r.share) < 0.999).length;
    if (summaryEl) summaryEl.textContent = `${spread.length} technologies invested in across ${altCount} alternative${altCount === 1 ? "" : "s"}. ${everyAlt} built in every alternative, ${optional} optional.`;
    renderInvestmentEnvelope(spread);
    const lowRegret = spread
      .filter((r) => Number(r.share) >= 0.999 && Number(r.max) > 1e-6)
      .slice()
      .sort((a, b) => Number(a.relativeRange) - Number(b.relativeRange) || Number(b.mean) - Number(a.mean))
      .slice(0, 10);
    const highVolatility = spread
      .filter((r) => Number(r.max) > 1e-6)
      .slice()
      .sort((a, b) => Number(b.relativeRange) - Number(a.relativeRange) || Number(b.range) - Number(a.range))
      .slice(0, 10);
    renderInvestmentTable(lowRegretEl, lowRegret, "No low-regret investments detected (need techs built in every alternative).");
    renderInvestmentTable(highVolEl, highVolatility, "No high-volatility investments detected.");
  }

  function renderInvestmentEnvelope(spread) {
    const el = $("mgaInvestmentEnvelope");
    if (!el) return;
    if (!window.Plotly || !spread.length) {
      el.className = "atlas-chart empty-state";
      el.textContent = spread.length ? "Plotly is not loaded." : "No investment data loaded.";
      return;
    }
    const sort = state.investmentSort || "max";
    const sorted = spread.slice().sort((a, b) => {
      if (sort === "range") return Number(b.range) - Number(a.range);
      if (sort === "relativeRange") return Number(b.relativeRange) - Number(a.relativeRange);
      if (sort === "baseline") return Number(b.baselineStock) - Number(a.baselineStock);
      return Number(b.max) - Number(a.max);
    });
    const top = sorted.slice(0, 20).reverse(); // reverse so largest sits at the top of horizontal bar
    const labels = top.map((r) => r.name || r.tech);
    const mins = top.map((r) => Number(r.min));
    const ranges = top.map((r) => Math.max(Number(r.max) - Number(r.min), 0));
    const baselines = top.map((r) => Number(r.baselineStock));
    const colors = top.map((r) => {
      if (r.category === "low-regret") return "#2f9e44";
      if (r.category === "high-volatility") return "#d97706";
      if (r.category === "optional") return "#6366f1";
      return "#0ea5e9";
    });
    const hover = top.map((r) => `${escapeHtml(r.name || r.tech)}<br>Sector: ${escapeHtml(r.sector || "?")}<br>Built in ${(Number(r.share) * 100).toFixed(0)}% of alternatives<br>Min: ${formatMaybe(r.min)} - Max: ${formatMaybe(r.max)}<br>Mean: ${formatMaybe(r.mean)} (std ${formatMaybe(r.std)})<br>Baseline: ${formatMaybe(r.baselineStock)}<br>Category: ${escapeHtml(r.category)}<extra></extra>`);
    el.className = "atlas-chart plotly-chart";
    el.textContent = "";
    window.Plotly.react(el, [
      {
        type: "bar",
        orientation: "h",
        x: ranges,
        y: labels,
        base: mins,
        marker: { color: colors, line: { width: 0 } },
        hovertemplate: hover,
        name: "Alternative range",
      },
      {
        type: "scatter",
        mode: "markers",
        x: baselines,
        y: labels,
        marker: { symbol: "diamond", size: 10, color: "#0f2436", line: { color: "#fff", width: 1 } },
        hovertemplate: "Baseline: %{x:.2f}<extra></extra>",
        name: "Baseline",
      },
    ], {
      margin: { l: 220, r: 24, t: 24, b: 56 },
      paper_bgcolor: "rgba(0,0,0,0)",
      plot_bgcolor: "rgba(0,0,0,0)",
      barmode: "overlay",
      xaxis: { title: "Installed capacity across MGA alternatives", gridcolor: "#dbe4ec", zerolinecolor: "#94a3b8" },
      yaxis: { automargin: true, ticksuffix: "  " },
      showlegend: true,
      legend: { orientation: "h", y: -0.22 },
    }, { responsive: true, displaylogo: false });
  }

  function renderInvestmentTable(el, rows, emptyText) {
    if (!el) return;
    if (!rows.length) {
      el.className = "table-wrap explorer-table empty-state";
      el.textContent = emptyText;
      return;
    }
    el.className = "table-wrap explorer-table";
    const body = rows.map((r) => {
      const share = `${(Number(r.share) * 100).toFixed(0)}%`;
      const rel = `${(Number(r.relativeRange) * 100).toFixed(1)}%`;
      return `<tr>
        <td>${escapeHtml(r.name || r.tech)}</td>
        <td>${escapeHtml(r.sector || "?")}</td>
        <td>${formatMaybe(r.baselineStock)}</td>
        <td>${formatMaybe(r.min)}</td>
        <td>${formatMaybe(r.max)}</td>
        <td>${formatMaybe(r.mean)}</td>
        <td>${rel}</td>
        <td>${share}</td>
      </tr>`;
    }).join("");
    el.innerHTML = `<table><thead><tr><th>Technology</th><th>Sector</th><th>Baseline</th><th>Min</th><th>Max</th><th>Mean</th><th>Relative spread</th><th>Built in</th></tr></thead><tbody>${body}</tbody></table>`;
  }

  function formatMaybe(value) {
    if (value == null || value === "") return "-";
    const n = Number(value);
    return Number.isFinite(n) ? n.toFixed(3) : String(value);
  }

  function renderProgress(payload) {
    const campaign = (payload && payload.campaign) || {};
    const certificate = (payload && payload.certificate) || {};
    const trace = Array.isArray(payload && payload.oracleTrace) ? payload.oracleTrace : [];
    const directions = Array.isArray(payload && payload.directions) ? payload.directions : [];
    const results = Array.isArray(payload && payload.results) ? payload.results : [];
    const directionStates = Array.isArray(payload && payload.directionStates) ? payload.directionStates : [];
    const workersInfo = (payload && payload.workersInfo) || {};
    const subtitle = $("mgaProgressSubtitle");
    const detail = $("mgaProgressDetail");
    const status = $("mgaProgressStatus");
    const log = $("mgaProgressLog");
    const stateText = campaign.state || (payload && payload.ok ? "planned" : "idle");
    const completed = Number(campaign.completed || 0);
    const total = Number(campaign.total || directions.length || 0);
    if (subtitle) subtitle.textContent = campaign.name ? `${campaign.name} - ${stateText}` : "Hybrid ORACLE design previewed.";
    if (detail) {
      detail.textContent = campaign.stage || `Estimated max error ${formatMaybe(certificate.estimatedMaxError)} against target ${formatMaybe(certificate.targetTolerance)}.`;
      if (window.IESAExplainStatus) window.IESAExplainStatus(detail, detail.textContent, stateText === "failed" ? "error" : "");
    }
    if (status) {
      status.textContent = stateText === "completed" ? "Complete" : stateText === "running" ? "Running" : stateText === "failed" ? "Failed" : "Ready";
      status.className = `status-pill ${stateText === "completed" ? "ready" : stateText === "running" ? "warming" : stateText === "failed" ? "failed" : "muted"}`;
    }
    renderProgressBar(campaign, completed, total);
    renderStageStrip(campaign, directionStates, trace, stateText);
    renderWorkers(workersInfo, directionStates, campaign);
    renderDirectionsTable(directionStates, directions);
    if (log) {
      const lines = [];
      if (certificate.mode) lines.push(`Method: ${certificate.mode}`);
      if (certificate.exploratoryDimensions != null) lines.push(`Exploratory dimensions: ${certificate.exploratoryDimensions}`);
      if (campaign.baselineCost != null) lines.push(`Baseline cost: ${formatMaybe(campaign.baselineCost)} (solved in ${formatMaybe(campaign.baselineSolveSeconds)} s)`);
      if (campaign.costCap != null) lines.push(`Cost cap (slack ${formatMaybe(certificate.costSlackPercent)}%): ${formatMaybe(campaign.costCap)}`);
      if (certificate.initialMaxError != null) lines.push(`Initial estimated max error: ${formatMaybe(certificate.initialMaxError)}`);
      if (certificate.estimatedMaxError != null) lines.push(`Current estimated max error: ${formatMaybe(certificate.estimatedMaxError)} (target ${formatMaybe(certificate.targetTolerance)})`);
      if (trace.length) lines.push(...trace.map((t) => `ORACLE ${t.iteration}: ${formatMaybe(t.maxErrorBefore)} -> ${formatMaybe(t.maxErrorAfter)} with ${t.accepted} accepted candidate(s)`));
      if (campaign.total != null) lines.push(`Alternatives: ${completed}/${total}`);
      log.textContent = lines.length ? lines.join("\n") : "Waiting for MGA campaign.";
    }
  }

  function renderProgressBar(campaign, completed, total) {
    const fill = $("mgaProgressBarFill");
    const label = $("mgaProgressBarLabel");
    const elapsed = $("mgaProgressBarElapsed");
    const pct = total > 0 ? Math.max(0, Math.min(100, (completed / total) * 100)) : 0;
    if (fill) fill.style.width = `${pct.toFixed(1)}%`;
    if (label) label.textContent = `${completed} / ${total} alternatives (${pct.toFixed(0)}%)`;
    if (elapsed) {
      const startedAt = Number(campaign && campaign.started_at);
      const completedAt = Number(campaign && campaign.completed_at);
      if (Number.isFinite(startedAt) && startedAt > 0) {
        const end = Number.isFinite(completedAt) && completedAt > startedAt ? completedAt : Date.now() / 1000;
        const seconds = Math.max(0, end - startedAt);
        elapsed.textContent = `Elapsed: ${formatDuration(seconds)}`;
      } else {
        elapsed.textContent = "";
      }
    }
  }

  function renderStageStrip(campaign, directionStates, trace, stateText) {
    const phase = String((campaign && campaign.phase) || "");
    const completedAll = stateText === "completed";
    const hasResult = directionStates.some((s) => s.status === "solved" || s.status === "failed");
    const baselineDone = hasResult || phase === "baseline-done" || phase === "vmm" || phase === "parallel-seed" || phase === "oracle" || phase === "finalize" || completedAll;
    const prepareDone = baselineDone || phase === "baseline" || phase === "baseline-done";
    setStage("mgaStagePrepare", prepareDone ? "done" : phase === "prepare" ? "active" : "pending");
    setStage("mgaStageBaseline", baselineDone ? "done" : (phase === "baseline" || phase === "baseline-done") ? "active" : "pending");
    setStage("mgaStageVmm", phaseStatus(directionStates, "vmm", phase, completedAll));
    setStage("mgaStageSeed", phaseStatus(directionStates, "parallel-seed", phase, completedAll));
    setStage("mgaStageOracle", oracleStageStatus(directionStates, trace, phase, completedAll));
    setStage("mgaStageFinalize", completedAll ? "done" : phase === "finalize" ? "active" : "pending");
  }

  function phaseStatus(directionStates, phaseName, currentPhase, completedAll) {
    const matching = directionStates.filter((s) => s.phase === phaseName);
    if (!matching.length) return completedAll ? "done" : "pending";
    const running = matching.some((s) => s.status === "running");
    const allFinished = matching.every((s) => s.status === "solved" || s.status === "failed");
    if (allFinished) return "done";
    if (running || currentPhase === phaseName) return "active";
    if (completedAll) return "done";
    return "pending";
  }

  function oracleStageStatus(directionStates, trace, currentPhase, completedAll) {
    const oracleDirs = directionStates.filter((s) => s.phase === "oracle-refine");
    if (!oracleDirs.length) return completedAll ? "done" : "pending";
    const running = oracleDirs.some((s) => s.status === "running") || currentPhase === "oracle";
    const allFinished = oracleDirs.every((s) => s.status === "solved" || s.status === "failed");
    if (allFinished && trace.length) return "done";
    if (running) return "active";
    if (completedAll) return "done";
    return "pending";
  }

  function renderWorkers(workersInfo, directionStates, campaign) {
    const summary = $("mgaWorkersSummary");
    const body = $("mgaWorkersBody");
    if (!body) return;
    const configured = Number(workersInfo && workersInfo.configured) || 1;
    const threadsPerSolve = workersInfo && workersInfo.threadsPerSolve != null ? workersInfo.threadsPerSolve : "auto";
    const solver = (workersInfo && workersInfo.solver) || "";
    const solveMethod = (workersInfo && workersInfo.solveMethod) || "";
    if (summary) {
      const parts = [`${configured} worker${configured === 1 ? "" : "s"}`, `${threadsPerSolve} threads/solve`, "sequential"];
      summary.textContent = parts.join(" - ");
    }
    const current = workersInfo && workersInfo.current;
    const stateText = campaign && campaign.state;
    if (current && typeof current === "object") {
      const startedAt = Number(current.startedAt) || 0;
      const elapsed = startedAt > 0 ? Math.max(0, Date.now() / 1000 - startedAt) : 0;
      body.innerHTML = `
        <div class="mga-worker-card running">
          <div class="mga-worker-head">
            <span class="mga-worker-id">Worker 1</span>
            <span class="mga-worker-status">Solving</span>
          </div>
          <div class="mga-worker-label">Direction ${escapeHtml(String(current.directionId || "?"))} - ${escapeHtml(String(current.label || ""))}</div>
          <div class="mga-worker-meta">
            <span>Phase: ${escapeHtml(prettifyPhase(String(current.phase || "")))}</span>
            <span>Elapsed: ${formatDuration(elapsed)}</span>
            <span>Solver: ${escapeHtml(prettifySolver(solver))}${solveMethod ? ` (${escapeHtml(solveMethod)})` : ""}</span>
          </div>
        </div>
      `;
    } else {
      let label = "Idle";
      if (stateText === "completed") label = "All workers finished";
      else if (stateText === "failed") label = "Worker stopped (failed)";
      else if (stateText === "running") label = "Worker is between solves";
      body.innerHTML = `
        <div class="mga-worker-card idle">
          <div class="mga-worker-head">
            <span class="mga-worker-id">Worker 1</span>
            <span class="mga-worker-status muted">${escapeHtml(label)}</span>
          </div>
          <div class="mga-worker-meta">
            <span>Solver: ${escapeHtml(prettifySolver(solver) || "auto")}${solveMethod ? ` (${escapeHtml(solveMethod)})` : ""}</span>
            <span>Threads/solve: ${escapeHtml(String(threadsPerSolve))}</span>
          </div>
        </div>
      `;
    }
  }

  function renderDirectionsTable(directionStates, directions) {
    const el = $("mgaDirectionsTable");
    const summaryEl = $("mgaDirectionsSummary");
    if (!el) return;
    const fallback = directionStates.length ? directionStates : (directions || []).map((d, i) => ({
      id: d.id || i + 1,
      label: d.label || "",
      phase: d.phase || "",
      status: "queued",
      worker: 0,
      durationSeconds: null,
    }));
    if (!fallback.length) {
      el.innerHTML = "";
      el.textContent = "No directions queued.";
      el.classList.add("empty-state");
      if (summaryEl) summaryEl.textContent = "Queued: 0";
      return;
    }
    el.classList.remove("empty-state");
    const counts = { queued: 0, running: 0, solved: 0, failed: 0 };
    fallback.forEach((s) => { const k = String(s.status || "queued"); if (counts[k] != null) counts[k] += 1; });
    if (summaryEl) summaryEl.textContent = `Queued: ${counts.queued} - Running: ${counts.running} - Solved: ${counts.solved}${counts.failed ? ` - Failed: ${counts.failed}` : ""}`;
    const rows = fallback.map((s) => {
      const status = String(s.status || "queued");
      const dur = s.durationSeconds != null ? formatDuration(Number(s.durationSeconds)) : status === "running" && Number(s.startedAt) > 0 ? formatDuration(Math.max(0, Date.now() / 1000 - Number(s.startedAt))) : "-";
      const errorTitle = s.errorMessage ? ` title="${escapeHtml(String(s.errorMessage))}"` : "";
      return `
        <tr class="mga-direction-row ${escapeHtml(status)}">
          <td>${escapeHtml(String(s.id))}</td>
          <td>${escapeHtml(prettifyPhase(String(s.phase || "")))}</td>
          <td>${escapeHtml(String(s.label || ""))}</td>
          <td><span class="mga-direction-status ${escapeHtml(status)}"${errorTitle}>${escapeHtml(prettifyStatus(status))}</span></td>
          <td>${escapeHtml(dur)}</td>
          <td>${s.worker ? escapeHtml(String(s.worker)) : "-"}</td>
        </tr>
      `;
    }).join("");
    el.innerHTML = `
      <table class="mga-directions-grid">
        <thead><tr><th>#</th><th>Phase</th><th>Label</th><th>Status</th><th>Duration</th><th>Worker</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    `;
    if (window.IESAExplainStatus) {
      el.querySelectorAll(".mga-direction-status.failed").forEach((node, idx) => {
        const failed = fallback.filter((s) => String(s.status || "") === "failed")[idx];
        window.IESAExplainStatus(node, failed && failed.errorMessage ? failed.errorMessage : "MGA direction failed.", "error");
      });
    }
  }

  function prettifyPhase(phase) {
    switch (phase) {
      case "vmm": return "VMM seed";
      case "parallel-seed": return "Parallel seed";
      case "oracle-refine": return "ORACLE refinement";
      case "oracle": return "ORACLE refinement";
      case "baseline": return "Baseline";
      case "baseline-done": return "Baseline";
      case "prepare": return "Prepare";
      case "finalize": return "Finalize";
      case "complete": return "Complete";
      default: return phase || "-";
    }
  }

  function prettifyStatus(status) {
    switch (status) {
      case "queued": return "Queued";
      case "running": return "Running";
      case "solved": return "Solved";
      case "failed": return "Failed";
      default: return status || "-";
    }
  }

  function prettifySolver(solver) {
    const s = String(solver || "").toLowerCase();
    if (s === "gurobi") return "Gurobi";
    if (s === "highs") return "HiGHS";
    if (s === "cplex") return "CPLEX";
    if (s === "xpress") return "Xpress";
    return solver || "";
  }

  function formatDuration(seconds) {
    const n = Number(seconds);
    if (!Number.isFinite(n) || n < 0) return "-";
    if (n < 1) return `${(n * 1000).toFixed(0)} ms`;
    if (n < 60) return `${n.toFixed(1)} s`;
    const m = Math.floor(n / 60);
    const s = Math.floor(n % 60);
    return `${m}m ${s.toString().padStart(2, "0")}s`;
  }

  function setStage(id, status) {
    const el = $(id);
    if (!el) return;
    el.classList.remove("done", "active", "pending");
    el.classList.add(status);
  }

  function renderCertificate(certificate) {
    const el = $("mgaCertificate");
    if (!el) return;
    if (!certificate || !certificate.mode) {
      el.innerHTML = "";
      return;
    }
    const items = [
      ["Baseline cost", formatMaybe(certificate.baselineCost)],
      ["Cost cap", formatMaybe(certificate.costCap)],
      ["Initial max error", formatMaybe(certificate.initialMaxError)],
      ["Estimated max error", formatMaybe(certificate.estimatedMaxError)],
      ["Target tolerance", formatMaybe(certificate.targetTolerance)],
      ["ORACLE iterations", certificate.iterations == null ? "-" : certificate.iterations],
      ["Design dimensions", certificate.exploratoryDimensions == null ? "-" : certificate.exploratoryDimensions],
      ["Solved alternatives", certificate.solvedAlternatives == null ? "-" : certificate.solvedAlternatives],
      ["Solver", certificate.solver || "-"],
      ["Converged", certificate.converged ? "Yes" : "No"],
    ];
    el.innerHTML = items.map(([label, value]) => `<div class="metric"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`).join("");
  }

  function renderOracleChart(trace) {
    const el = $("mgaOracleChart");
    if (!el) return;
    if (!window.Plotly || !Array.isArray(trace) || !trace.length) {
      el.className = "atlas-chart empty-state";
      el.textContent = trace && trace.length ? "Plotly is not loaded." : "No ORACLE convergence trace loaded.";
      return;
    }
    el.className = "atlas-chart plotly-chart";
    el.textContent = "";
    window.Plotly.react(el, [{
      type: "scatter",
      mode: "lines+markers",
      x: trace.map((t) => Number(t.iteration)),
      y: trace.map((t) => Number(t.maxErrorAfter)),
      text: trace.map((t) => `${t.accepted} accepted`),
      hovertemplate: "Iteration %{x}<br>Estimated max error: %{y:.3f}<br>%{text}<extra></extra>",
      line: { color: "#007a78", width: 2 },
      marker: { size: 8, color: "#143d59" },
    }], {
      margin: { l: 64, r: 18, t: 16, b: 52 },
      paper_bgcolor: "rgba(0,0,0,0)",
      plot_bgcolor: "rgba(0,0,0,0)",
      xaxis: { title: "ORACLE iteration", gridcolor: "#dbe4ec" },
      yaxis: { title: "Estimated max error", gridcolor: "#dbe4ec" },
      showlegend: false,
    }, { responsive: true, displaylogo: false });
  }

  function renderError(err) {
    const raw = err && err.message ? err.message : String(err);
    const message = /fetch|network|failed to fetch/i.test(raw)
      ? "Cannot reach the local IESA-Opt UI server. Start or refresh the UI session, then run the MGA campaign again."
      : raw;
    setTitle("MGA error", message);
    const detail = $("mgaProgressDetail");
    const log = $("mgaProgressLog");
    if (detail) { detail.textContent = message; if (window.IESAExplainStatus) window.IESAExplainStatus(detail, message, "error"); }
    if (log) { log.textContent = message; if (window.IESAExplainStatus) window.IESAExplainStatus(log, message, "error"); }
  }

  function bindStandalone() {
    if (!$('mgaForm')) return;
    bind();
    configureThreadSlider();
    updateSummaries();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", bindStandalone);
  else bindStandalone();

  window.IESAMGA = { populateForm, previewMga, runMga };
})();
