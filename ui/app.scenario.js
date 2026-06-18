// =============================================================================
// app.scenario.js -- Scenario Space tab
//
// Owns the Setup, Progress and (later) Results sub-tabs of the Scenario Space
// section. Talks to two server endpoints today (Phase 1):
//   * POST /api/scenario/validate -> errors/warnings + impliedSampleSize
//   * POST /api/scenario/preview  -> first N rows of the sampled matrix
//
// Public hook (called by app.js once /api/options + /api/solvers respond):
//   window.IESAScenario.populateForm(options, solvers)
//
// The campaign runner (start, live progress, results) hooks in via the SAME
// rendering shape as the demo simulation built into this file. Until Phase 3
// lands, the user can press "Start demo" on the Progress sub-tab to preview
// how a campaign of 1..50 workers will look.
// =============================================================================
(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const DAYS_PER_YEAR = 360;
  const PARAMETER_SPACE_STORAGE_KEY = "iesa.scenario.parameterSpace.v1";

  function detectedCpuThreads(options) {
    const fromServer = Number(options && options.cpuThreads);
    if (Number.isFinite(fromServer) && fromServer > 0) return fromServer;
    return Number(navigator.hardwareConcurrency) || 64;
  }

  // ---------------------------------------------------------------------------
  // Parameter space columns: id -> descriptor. The selection checkbox is NOT
  // part of this list; it is always rendered as the first cell of every row.
  // `essential: true` columns cannot be hidden (we keep `parameter` always-on
  // so the row identity is never lost).
  // ---------------------------------------------------------------------------
  const COLUMNS = [
    { id: "parameter",    label: "Parameter",     kind: "text",   essential: true },
    { id: "subparameter", label: "Sub-parameter", kind: "text" },
    { id: "sheet",        label: "Sheet",         kind: "text" },
    { id: "cell",         label: "Cell",          kind: "text" },
    { id: "type",         label: "Type",          kind: "select", options: ["set", "multiply"] },
    { id: "min",          label: "Min",           kind: "number" },
    { id: "max",          label: "Max",           kind: "number" },
    { id: "step",         label: "Step",          kind: "number" },
    { id: "notes",        label: "Notes",         kind: "text" },
  ];

  // Defaults use the workbook coordinates a user sees in the Excel database.
  // The server resolves them to ModelParams fields/indices before launching.
  const DEFAULT_ROWS = [
    { parameter: "Bunker emission cap",    subparameter: "NL 2050", sheet: "NodeParameters", cell: "AE5", type: "multiply", min: 0.5, max: 1.5, step: "", notes: "" },
    { parameter: "Feedstock emission cap", subparameter: "NL 2050", sheet: "NodeParameters", cell: "AL5", type: "multiply", min: 0.5, max: 1.5, step: "", notes: "" },
    { parameter: "Cumulative CO2 budget",  subparameter: "NL",      sheet: "NodeParameters", cell: "I5",  type: "multiply", min: 0.8, max: 1.2, step: "", notes: "" },
  ];

  const state = {
    rows: DEFAULT_ROWS.map((r) => Object.assign({}, r)),
    selected: new Set(),
    customWorkbookPath: "",
    cpuThreads: 0,
    bound: false,
  };

  const CAMPAIGN_PHASES = [
    { id: "workers", label: "Making workers" },
    { id: "assign", label: "Assigning tasks" },
    { id: "generate", label: "Generating" },
    { id: "solve", label: "Solve" },
    { id: "write", label: "Export" },
  ];
  const PHASE_STATUS_LABELS = {
    pending: "Pending",
    active: "Running",
    done: "Done",
    failed: "Failed",
    skipped: "Skipped",
  };

  // Live / demo progress state. Shape matches the eventual Phase 3 endpoint.
  const progressState = {
    active: false,
    demoTimer: null,
    pollTimer: null,
    activeCampaignId: null,
    startedAt: 0,
    campaign: { name: "", total: 0, started_at: 0 },
    workers: [],
    phases: defaultCampaignPhases(),
    failures: [],
  };

  const scenarioResultsState = {
    campaignId: null,
    scatter: [],
    campaigns: [],
  };

  const GSA_METHODS = {
    rank: { label: "Rank correlation", sampler: "lhs", hint: "Rank correlation uses Latin hypercube sampling and reports Spearman rho." },
    moment_delta: { label: "Moment-independent delta", sampler: "lhs", hint: "Moment-independent GSA uses Latin hypercube sampling and reports Borgonovo-style delta indices." },
    morris: { label: "Morris elementary effects", sampler: "morris", hint: "Morris GSA uses Morris sampling and reports mu, mu*, and sigma elementary-effect metrics." },
    sobol: { label: "Sobol variance indices", sampler: "sobol", hint: "Sobol GSA uses Sobol sampling and reports first-order variance-index estimates." },
  };

  function defaultCampaignPhases() {
    return CAMPAIGN_PHASES.map((p) => ({ id: p.id, label: p.label, status: "pending", detail: "" }));
  }

  function normalizeCampaignPhases(phases, campaignState) {
    const incoming = new Map((Array.isArray(phases) ? phases : [])
      .filter((p) => p && p.id)
      .map((p) => [String(p.id), p]));
    const normalized = CAMPAIGN_PHASES.map((def) => {
      const p = incoming.get(def.id) || {};
      const rawStatus = String(p.status || "pending").toLowerCase();
      const status = Object.prototype.hasOwnProperty.call(PHASE_STATUS_LABELS, rawStatus) ? rawStatus : "pending";
      return {
        id: def.id,
        label: String(p.label || def.label),
        status,
        detail: String(p.detail || ""),
        seconds: typeof p.seconds === "number" ? p.seconds : null,
      };
    });
    if ((!phases || !phases.length) && campaignState === "completed") {
      normalized.forEach((p) => { p.status = p.id === "write" ? "skipped" : "done"; });
      const write = normalized.find((p) => p.id === "write");
      if (write) write.detail = "Export not enabled";
    }
    return normalized;
  }

  function setProgressPhase(id, status, detail) {
    const phases = progressState.phases || defaultCampaignPhases();
    progressState.phases = phases.map((p) => p.id === id ? Object.assign({}, p, { status, detail: detail || "" }) : p);
  }

  // ===========================================================================
  // Init / bindings
  // ===========================================================================
  function init() {
    if (state.bound) return;
    if (!$("scTableBody")) return; // tab markup not present (older HTML)
    state.bound = true;
    restoreSavedParameterSpace();
    renderTable();
    bindRowControls();
    bindScenarioFormControls();
    bindProgressControls();
    bindScenarioResultsControls();
    renderProgress();
    fetchScenarioCampaigns().catch(() => {});
    // Kick off an implicit validate so the implied count appears right away.
    validateNow().catch(() => {});
  }

  function bindRowControls() {
    $("scAddRow").addEventListener("click", () => {
      state.rows.push({ parameter: "", subparameter: "", sheet: "", cell: "", type: "set", min: "", max: "", step: "", notes: "" });
      renderTable();
      scheduleValidate();
    });
    $("scDuplicateRow").addEventListener("click", duplicateSelected);
    $("scRemoveRow").addEventListener("click", removeSelected);
    const saveBtn = $("scSaveParameterSpace");
    if (saveBtn) saveBtn.addEventListener("click", saveParameterSpace);
    const loadBtn = $("scLoadParameterSpace");
    const loadFile = $("scLoadParameterSpaceFile");
    if (loadBtn && loadFile) {
      loadBtn.addEventListener("click", () => loadFile.click());
      loadFile.addEventListener("change", loadParameterSpaceFile);
    }
    $("scValidateBtn").addEventListener("click", () => validateNow());
    $("scPreviewBtn").addEventListener("click", () => previewNow());
    ["scCampaignName", "scGsaMethod", "scMethod", "scNVariants", "scSeed"].forEach((id) => {
      const el = $(id);
      if (!el) return;
      el.addEventListener("change", onCampaignFieldChange);
      el.addEventListener("input", onCampaignFieldChange);
    });
    syncGsaSampling();
  }

  function onCampaignFieldChange() {
    syncGsaSampling();
    updateCampaignSummary();
    scheduleValidate();
  }

  function syncGsaSampling() {
    const gsaEl = $("scGsaMethod");
    const methodEl = $("scMethod");
    const hint = $("scGsaMethodHint");
    if (!gsaEl || !methodEl) return;
    const cfg = GSA_METHODS[gsaEl.value] || GSA_METHODS.rank;
    methodEl.value = cfg.sampler;
    if (hint) hint.textContent = cfg.hint;
  }

  // ===========================================================================
  // Parameter-space table
  // ===========================================================================
  function renderTable() {
    renderTableHead();
    renderTableBody();
  }

  function renderTableHead() {
    const thead = $("scTableHead");
    if (!thead) return;
    thead.innerHTML = "";
    const tr = document.createElement("tr");
    const thSel = document.createElement("th");
    thSel.style.width = "32px";
    tr.appendChild(thSel);

    COLUMNS.forEach((col) => {
      const th = document.createElement("th");
      const wrap = document.createElement("span");
      wrap.className = "sc-col-head";
      const label = document.createElement("span");
      label.textContent = col.label;
      wrap.appendChild(label);
      th.appendChild(wrap);
      tr.appendChild(th);
    });
    thead.appendChild(tr);
  }

  function renderTableBody() {
    const tbody = $("scTableBody");
    tbody.innerHTML = "";
    state.rows.forEach((row, i) => {
      const tr = document.createElement("tr");
      if (state.selected.has(i)) tr.classList.add("selected");
      tr.dataset.idx = i;

      // Selection checkbox
      const tdSel = document.createElement("td");
      const cb = document.createElement("input");
      cb.type = "checkbox";
      cb.checked = state.selected.has(i);
      cb.addEventListener("change", () => {
        if (cb.checked) state.selected.add(i); else state.selected.delete(i);
        tr.classList.toggle("selected", cb.checked);
      });
      tdSel.appendChild(cb);
      tr.appendChild(tdSel);

      COLUMNS.forEach((col) => {
        const td = document.createElement("td");
        if (col.kind === "select") {
          td.appendChild(makeSelectInput(row, col.id, col.options));
        } else {
          td.appendChild(makeInput(row, col.id, col.kind));
        }
        tr.appendChild(td);
      });

      tbody.appendChild(tr);
    });
  }

  function makeInput(row, field, kind) {
    const inp = document.createElement("input");
    inp.type = kind === "number" ? "number" : "text";
    if (kind === "number") inp.step = "any";
    inp.value = row[field] === undefined || row[field] === null ? "" : row[field];
    inp.addEventListener("change", () => {
      row[field] = kind === "number" ? (inp.value === "" ? "" : Number(inp.value)) : inp.value;
      scheduleValidate();
    });
    return inp;
  }

  function makeSelectInput(row, field, options) {
    const sel = document.createElement("select");
    options.forEach((opt) => {
      const o = document.createElement("option");
      o.value = opt;
      o.textContent = opt;
      if (row[field] === opt) o.selected = true;
      sel.appendChild(o);
    });
    sel.addEventListener("change", () => {
      row[field] = sel.value;
      scheduleValidate();
    });
    return sel;
  }

  function duplicateSelected() {
    if (!state.selected.size) return;
    const newRows = [];
    Array.from(state.selected).sort((a, b) => a - b).forEach((i) => {
      newRows.push(Object.assign({}, state.rows[i]));
    });
    state.rows = state.rows.concat(newRows);
    state.selected.clear();
    renderTable();
    scheduleValidate();
  }

  function removeSelected() {
    if (!state.selected.size) return;
    const keep = [];
    state.rows.forEach((r, i) => { if (!state.selected.has(i)) keep.push(r); });
    state.rows = keep;
    state.selected.clear();
    renderTable();
    scheduleValidate();
  }

  function csvCell(value) {
    const text = value === null || value === undefined ? "" : String(value);
    return /[",\r\n]/.test(text) ? '"' + text.replace(/"/g, '""') + '"' : text;
  }

  function parameterSpaceCsv() {
    const header = COLUMNS.map((c) => csvCell(c.label)).join(",");
    const rows = state.rows.map((row) => COLUMNS.map((c) => csvCell(row[c.id])).join(","));
    return [header].concat(rows).join("\r\n") + "\r\n";
  }

  function parseCsv(text) {
    const rows = [];
    let row = [];
    let cell = "";
    let quoted = false;
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (quoted) {
        if (ch === '"') {
          if (text[i + 1] === '"') { cell += '"'; i++; }
          else quoted = false;
        } else {
          cell += ch;
        }
      } else if (ch === '"') {
        quoted = true;
      } else if (ch === ",") {
        row.push(cell); cell = "";
      } else if (ch === "\n") {
        row.push(cell); cell = "";
        rows.push(row); row = [];
      } else if (ch !== "\r") {
        cell += ch;
      }
    }
    if (cell !== "" || row.length) { row.push(cell); rows.push(row); }
    return rows;
  }

  function normalizeParameterSpaceRows(rows) {
    const headers = rows.length ? rows[0].map((h) => String(h || "").trim()) : [];
    const headerToId = new Map();
    COLUMNS.forEach((col) => {
      headerToId.set(col.label.toLowerCase(), col.id);
      headerToId.set(col.id.toLowerCase(), col.id);
    });
    const ids = headers.map((h) => headerToId.get(h.toLowerCase()) || null);
    if (!ids.some(Boolean)) throw new Error("CSV header does not match the parameter-space columns.");
    const out = [];
    rows.slice(1).forEach((cells) => {
      const r = {};
      COLUMNS.forEach((col) => { r[col.id] = col.kind === "number" ? "" : ""; });
      ids.forEach((id, i) => {
        if (!id) return;
        const col = COLUMNS.find((c) => c.id === id);
        const raw = cells[i] === undefined ? "" : String(cells[i]).trim();
        r[id] = col && col.kind === "number" ? (raw === "" ? "" : Number(raw)) : raw;
      });
      if (!Object.values(r).some((v) => String(v || "").trim() !== "")) return;
      if (!COLUMNS.find((c) => c.id === "type").options.includes(r.type)) r.type = "set";
      out.push(r);
    });
    if (!out.length) throw new Error("CSV has no parameter rows.");
    return out;
  }

  function persistParameterSpace() {
    try {
      localStorage.setItem(PARAMETER_SPACE_STORAGE_KEY, JSON.stringify({
        savedAt: new Date().toISOString(),
        rows: state.rows,
      }));
      return true;
    } catch (_) {
      return false;
    }
  }

  function restoreSavedParameterSpace() {
    try {
      const raw = localStorage.getItem(PARAMETER_SPACE_STORAGE_KEY);
      if (!raw) return false;
      const payload = JSON.parse(raw);
      if (!payload || !Array.isArray(payload.rows) || !payload.rows.length) return false;
      state.rows = normalizeParameterSpaceRows([
        COLUMNS.map((c) => c.id),
        ...payload.rows.map((row) => COLUMNS.map((c) => row[c.id] === undefined ? "" : row[c.id])),
      ]);
      state.selected.clear();
      return true;
    } catch (_) {
      return false;
    }
  }

  function downloadText(filename, text, type) {
    const blob = new Blob([text], { type });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  }

  function safeFilenamePart(value) {
    const raw = String(value || "scenario_space").trim() || "scenario_space";
    return raw.replace(/[^A-Za-z0-9_.-]+/g, "_").replace(/^_+|_+$/g, "") || "scenario_space";
  }

  function saveParameterSpace() {
    const campaign = safeFilenamePart(($("scCampaignName") || {}).value);
    const filename = campaign + "_parameter_space.csv";
    const persisted = persistParameterSpace();
    downloadText(filename, parameterSpaceCsv(), "text/csv;charset=utf-8");
    setStatus("Parameter space saved to " + filename + (persisted ? " and kept for reload." : "."), "ok");
  }

  function loadParameterSpaceFile(event) {
    const input = event.target;
    const file = input && input.files && input.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      try {
        state.rows = normalizeParameterSpaceRows(parseCsv(String(reader.result || "")));
        state.selected.clear();
        persistParameterSpace();
        renderTable();
        updateCampaignSummary();
        scheduleValidate();
        setStatus("Loaded parameter space from " + file.name + ".", "ok");
      } catch (err) {
        setStatus("Could not load parameter space: " + (err && err.message ? err.message : err), "error");
      } finally {
        input.value = "";
      }
    };
    reader.onerror = () => {
      setStatus("Could not read parameter space file.", "error");
      input.value = "";
    };
    reader.readAsText(file);
  }

  // ===========================================================================
  // Scenario form (mirrors the run-form options/solvers)
  // ===========================================================================
  function bindScenarioFormControls() {
    const form = $("scForm");
    if (form) form.addEventListener("submit", (e) => {
      e.preventDefault();
      runCampaign().catch((err) => {
        setStatus("Failed to launch campaign: " + (err && err.message ? err.message : err), "error");
      });
    });
    const browse = $("scBrowseInputButton");
    if (browse) browse.addEventListener("click", browseInputFile);
    const clear = $("scClearCustomInputButton");
    if (clear) clear.addEventListener("click", clearCustomInput);
    const wb = $("scInputWorkbook");
    if (wb) wb.addEventListener("change", () => { if (state.customWorkbookPath) clearCustomInput(); else updateScenarioSummary(); scheduleValidate(); });

    const ts = $("scTimeSlicingToggle");
    if (ts) ts.addEventListener("change", () => { updateTimeSlicingControls(); updateTotalSlices(); });
    const rd = $("scRepresentativeDays");
    const rdn = $("scRepresentativeDaysNumber");
    if (rd && rdn) {
      rd.addEventListener("input", () => { rdn.value = rd.value; updateTotalSlices(); });
      rdn.addEventListener("input", () => { rd.value = rdn.value; updateTotalSlices(); });
    }
    const th = $("scThreads");
    const thn = $("scThreadsNumber");
    if (th && thn) {
      th.addEventListener("input", () => { thn.value = th.value; th.dataset.touched = "1"; thn.dataset.touched = "1"; updateThreadsPerWorker(); });
      thn.addEventListener("input", () => { th.value = thn.value; th.dataset.touched = "1"; thn.dataset.touched = "1"; updateThreadsPerWorker(); });
    }
    const wk = $("scWorkers");
    const wkn = $("scWorkersNumber");
    if (wk && wkn) {
      wk.addEventListener("input", () => { wkn.value = wk.value; wk.dataset.touched = "1"; wkn.dataset.touched = "1"; updateThreadsPerWorker(); });
      wkn.addEventListener("input", () => { wk.value = wkn.value; wk.dataset.touched = "1"; wkn.dataset.touched = "1"; updateThreadsPerWorker(); });
    }
    const periods = $("scPeriods");
    if (periods) periods.addEventListener("change", updateScenarioSummary);

    const solver = $("scSolver");
    if (solver) solver.addEventListener("change", updateSolverDetails);

    const outputMode = $("scOutputMode");
    if (outputMode) outputMode.addEventListener("change", () => {
      $("scOutputNameWrap").classList.toggle("hidden", outputMode.value !== "custom");
    });
  }

  function populateForm(options, solvers) {
    if (!options || !$("scInputWorkbook")) return;
    const d = options.defaults || {};
    fillSelect("scInputWorkbook", options.scenarios || [], d.inputWorkbook);
    fillSelect("scClusteringApproach", options.clusteringApproaches || [], d.clusteringApproach);
    fillSelect("scConstraintGroup", options.constraintGroups || [], d.constraintGroup);
    renderPeriods(options.periods || [], d.periods || []);
    renderHours(options.hoursPerDayOptions || [], d.hoursPerDay);
    renderSolveMethods(options.solveMethods || [], d.solveMethod);
    state.cpuThreads = detectedCpuThreads(options);
    if ($("scRepresentativeDays")) { $("scRepresentativeDays").value = d.representativeDays; }
    if ($("scRepresentativeDaysNumber")) { $("scRepresentativeDaysNumber").value = d.representativeDays; }
    const cpuThreads = String(Math.max(4, state.cpuThreads));
    if ($("scThreads")) $("scThreads").max = cpuThreads;
    if ($("scThreadsNumber")) $("scThreadsNumber").max = cpuThreads;
    if ($("scWorkers")) $("scWorkers").max = cpuThreads;
    if ($("scWorkersNumber")) $("scWorkersNumber").max = cpuThreads;
    // Sensible defaults so the user immediately sees a real Threads-per-worker
    // number instead of "auto": total threads = detected, workers = half.
    const detected = state.cpuThreads;
    const defaultThreads = Math.max(1, Math.min(detected || 4, Number(cpuThreads)));
    const defaultWorkers = Math.max(1, Math.min(detected ? Math.floor(detected / 2) : 4, Number(cpuThreads)));
    if ($("scThreads") && !$("scThreads").dataset.touched) $("scThreads").value = defaultThreads;
    if ($("scThreadsNumber") && !$("scThreadsNumber").dataset.touched) $("scThreadsNumber").value = defaultThreads;
    if ($("scWorkers") && !$("scWorkers").dataset.touched) $("scWorkers").value = defaultWorkers;
    if ($("scWorkersNumber") && !$("scWorkersNumber").dataset.touched) $("scWorkersNumber").value = defaultWorkers;

    populateSolvers(solvers || [], d.solver);
    updateTotalSlices();
    updateTimeSlicingControls();
    updateScenarioSummary();
    updateThreadsPerWorker();
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
    const select = $("scSolver");
    if (!select) return;
    select.innerHTML = "";
    state._solvers = solvers;
    const def = solvers.find((x) => x.default && x.available)
             || solvers.find((x) => x.id === defaultId && x.available)
             || solvers.find((x) => x.available);
    solvers.forEach((solver) => {
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
    const select = $("scSolver");
    if (!select || !state._solvers) return;
    const solver = state._solvers.find((x) => x.id === select.value);
    if (!solver) return;
    const detail = solver.message || "";
    const detailEl = $("scSolverDetails");
    if (detailEl) {
      detailEl.textContent = detail;
      detailEl.classList.toggle("hidden", !detail);
    }
  }

  function renderPeriods(periods, selected) {
    const w = $("scPeriods");
    if (!w) return;
    w.innerHTML = "";
    periods.forEach((p) => {
      const l = document.createElement("label");
      l.innerHTML = `<input type="checkbox" value="${p}"><span>${p}</span>`;
      const input = l.querySelector("input");
      input.checked = selected.includes(p);
      input.addEventListener("change", updateScenarioSummary);
      w.appendChild(l);
    });
  }

  function renderHours(hours, selected) {
    const w = $("scHoursPerDay");
    if (!w) return;
    w.innerHTML = "";
    hours.forEach((h) => {
      const l = document.createElement("label");
      l.innerHTML = `<input type="radio" name="scHoursPerDay" value="${h}"><span>${h}</span>`;
      const input = l.querySelector("input");
      input.checked = h === selected;
      input.addEventListener("change", updateTotalSlices);
      w.appendChild(l);
    });
  }

  function renderSolveMethods(methods, selected) {
    const w = $("scSolveMethod");
    if (!w) return;
    w.innerHTML = "";
    methods.forEach((m) => {
      const l = document.createElement("label");
      const safe = (m.label || "").replace(/[<>&"]/g, (c) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" }[c]));
      const help = window.IESASolverMethodHelp ? window.IESASolverMethodHelp(m) : null;
      if (help) {
        l.dataset.helpTitle = help.title;
        l.dataset.help = help.short.join("\n");
        l.dataset.helpMore = help.more;
      }
      l.innerHTML = `<input type="radio" name="scSolveMethod" value="${m.id}"><span>${safe}</span>`;
      l.querySelector("input").checked = m.id === selected;
      w.appendChild(l);
    });
  }

  function currentHoursPerDay() {
    const checked = document.querySelector("input[name='scHoursPerDay']:checked");
    return checked ? Number(checked.value) : 24;
  }

  function updateTotalSlices() {
    const ts = $("scTimeSlicingToggle");
    if (!ts) return;
    const tsOn = ts.checked;
    const total = tsOn
      ? Number(($("scRepresentativeDays") || {}).value || 0) * 24
      : DAYS_PER_YEAR * currentHoursPerDay();
    if ($("scTotalSlices")) $("scTotalSlices").value = String(total);
  }

  function updateTimeSlicingControls() {
    const ts = $("scTimeSlicingToggle");
    if (!ts) return;
    const tsOn = ts.checked;
    if ($("scHoursPerDayField")) $("scHoursPerDayField").classList.toggle("hidden", tsOn);
    if ($("scRepresentativeDaysField")) $("scRepresentativeDaysField").classList.toggle("hidden", !tsOn);
    if ($("scClusteringApproachField")) $("scClusteringApproachField").classList.toggle("hidden", !tsOn);
    if ($("scExtremeDaysField")) $("scExtremeDaysField").classList.toggle("hidden", !tsOn);
  }

  // ---------------------------------------------------------------------------
  // Compute and display the implied threads/worker.
  //   - Total CPU threads (scThreads): cap on threads allocated to the campaign.
  //     0 means "let the solver pick".
  //   - Parallel workers (scWorkers): how many variants run in parallel.
  //   - Threads per worker = floor(totalThreads / workers), with a floor of 1.
  //
  // When totalThreads is 0 (auto), we report "auto" instead of dividing by the
  // detected hardware concurrency since the actual thread count the solver
  // claims at runtime is decided by HiGHS/Gurobi internally.
  // ---------------------------------------------------------------------------
  function updateThreadsPerWorker() {
    const out = $("scThreadsPerWorker");
    if (!out) return;
    const totalThreads = Number(($("scThreads") || {}).value || 0);
    const workers = Math.max(1, Number(($("scWorkers") || {}).value || 1));
    if (totalThreads <= 0) {
      out.innerHTML = `<strong>auto</strong> <span class="subtle">(solver picks; \u00f7 ${workers} workers)</span>`;
      out.title = `Total CPU threads = 0 -> solver decides per worker.`;
      return;
    }
    // floor(total / workers) is the threads-per-worker we send to the solver.
    const perWorker = Math.max(1, Math.floor(totalThreads / workers));
    const allocated = perWorker * workers;
    const slack = totalThreads - allocated;
    out.innerHTML = `<strong>${perWorker}</strong> <span class="subtle">= floor(${totalThreads} \u00f7 ${workers})${slack > 0 ? `, ${slack} thread(s) unused` : ""}</span>`;
    out.title = `threads_per_worker = floor(total_threads / workers) = floor(${totalThreads} / ${workers}) = ${perWorker}`;
  }

  function updateScenarioSummary() {
    const wb = state.customWorkbookPath || (($("scInputWorkbook") || {}).value || "");
    const periods = [...document.querySelectorAll("#scPeriods input:checked")].map((i) => i.value);
    const sum = $("scScenarioSummary");
    if (sum) sum.textContent = `${wb || "No workbook"} - ${periods.length ? periods.join(", ") : "no years"}`;
    updateCampaignSummary();
  }

  function updateCampaignSummary() {
    const name = ($("scCampaignName") || {}).value || "—";
    const method = ($("scMethod") || {}).value || "—";
    const gsaMethod = ($("scGsaMethod") || {}).value || "rank";
    const variants = ($("scNVariants") || {}).value || "—";
    if ($("scSelectedCampaignLabel")) $("scSelectedCampaignLabel").textContent = name;
    const methodLabels = { lhs: "Latin hypercube", morris: "Morris", sobol: "Sobol", factorial: "Factorial" };
    const gsaLabel = (GSA_METHODS[gsaMethod] || GSA_METHODS.rank).label;
    if ($("scSelectedMethod")) $("scSelectedMethod").textContent = `${gsaLabel} / ${methodLabels[method] || method}`;
    if ($("scSelectedVariants")) $("scSelectedVariants").textContent = variants;
  }

  // ---------------------------------------------------------------------------
  // Browse input file (campaign-scoped custom workbook)
  // ---------------------------------------------------------------------------
  async function browseInputFile() {
    const btn = $("scBrowseInputButton");
    if (!btn) return;
    const original = btn.textContent;
    btn.disabled = true;
    btn.textContent = "Opening\u2026";
    try {
      const r = await fetch("/api/browseInputFile", { method: "POST" });
      const p = await r.json();
      if (!r.ok) throw new Error(p.error || r.statusText);
      const picked = (p && p.path) ? String(p.path).trim() : "";
      if (picked) setCustomWorkbook(picked);
    } catch (error) {
      console.error("scenario.browseInputFile failed", error);
    } finally {
      btn.disabled = false;
      btn.textContent = original;
    }
  }

  function setCustomWorkbook(path) {
    state.customWorkbookPath = path;
    const display = $("scCustomInputDisplay");
    const pathEl = $("scCustomInputDisplayPath");
    if (pathEl) pathEl.textContent = path;
    if (display) display.classList.remove("hidden");
    const clearBtn = $("scClearCustomInputButton");
    if (clearBtn) clearBtn.classList.remove("hidden");
    updateScenarioSummary();
    scheduleValidate();
  }

  function clearCustomInput() {
    state.customWorkbookPath = "";
    const display = $("scCustomInputDisplay");
    const pathEl = $("scCustomInputDisplayPath");
    if (display) display.classList.add("hidden");
    if (pathEl) pathEl.textContent = "";
    const clearBtn = $("scClearCustomInputButton");
    if (clearBtn) clearBtn.classList.add("hidden");
    updateScenarioSummary();
    scheduleValidate();
  }

  // ===========================================================================
  // Validate / preview
  // ===========================================================================
  let validateTimer = null;
  function scheduleValidate() {
    if (validateTimer) clearTimeout(validateTimer);
    validateTimer = setTimeout(() => { validateTimer = null; validateNow().catch(() => {}); }, 300);
  }

  async function validateNow() {
    const body = collectSpec();
    setStatus("Validating\u2026", "");
    try {
      const r = await fetch("/api/scenario/validate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const p = await r.json();
      renderValidation(p);
      return p;
    } catch (e) {
      setStatus("Server unreachable: " + (e.message || e), "error");
    }
  }

  async function previewNow() {
    const body = Object.assign({ previewRows: 20 }, collectSpec());
    $("scPreviewStatus").textContent = "Sampling\u2026";
    try {
      const r = await fetch("/api/scenario/preview", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      const p = await r.json();
      renderPreview(p);
    } catch (e) {
      $("scPreviewStatus").textContent = "Server unreachable: " + (e.message || e);
    }
  }

  function collectSpec() {
    return {
      name: $("scCampaignName").value.trim(),
      gsaMethod: ($("scGsaMethod") || {}).value || "rank",
      method: $("scMethod").value,
      n_variants: Number($("scNVariants").value) || 0,
      seed: Number($("scSeed").value) || 0,
      inputWorkbook: state.customWorkbookPath
        || (($("scInputWorkbook") || {}).value)
        || "Input/default_data.xlsx",
      rows: state.rows.map((r) => ({
        parameter: r.parameter || "",
        subparameter: r.subparameter || "",
        sheet: r.sheet || "",
        cell: r.cell || "",
        type: r.type || "set",
        min: r.min === "" || r.min === null || r.min === undefined ? "" : Number(r.min),
        max: r.max === "" || r.max === null || r.max === undefined ? "" : Number(r.max),
        step: r.step === "" || r.step === null || r.step === undefined ? "" : Number(r.step),
        notes: r.notes || "",
      })),
    };
  }

  function renderValidation(payload) {
    const msgEl = $("scMessages");
    msgEl.innerHTML = "";
    if (payload.errors && payload.errors.length) {
      const ul = document.createElement("ul");
      ul.className = "sc-errors";
      payload.errors.forEach((e) => { const li = document.createElement("li"); li.textContent = e; ul.appendChild(li); });
      msgEl.appendChild(ul);
    }
    if (payload.warnings && payload.warnings.length) {
      const ul = document.createElement("ul");
      ul.className = "sc-warnings";
      payload.warnings.forEach((e) => { const li = document.createElement("li"); li.textContent = e; ul.appendChild(li); });
      msgEl.appendChild(ul);
    }
    if (payload.valid) {
      setStatus("Spec is valid.", "ok");
    } else {
      setStatus("Spec has " + (payload.errors || []).length + " error(s).", "error");
    }
    const implied = $("scImplied");
    implied.textContent = payload.impliedSampleSize >= 0
      ? payload.impliedSampleSize.toLocaleString() + " variants"
      : "\u2014";
  }

  function renderPreview(payload) {
    const wrap = $("scPreviewWrap");
    wrap.innerHTML = "";
    if (!payload.ok) {
      $("scPreviewStatus").textContent = (payload.errors || ["Preview failed."])[0];
      return;
    }
    $("scPreviewStatus").textContent = "Showing " + payload.shown + " of " + payload.impliedSampleSize.toLocaleString() + " variants.";
    const tbl = document.createElement("table");
    const thead = document.createElement("thead");
    const trh = document.createElement("tr");
    const th0 = document.createElement("th"); th0.textContent = "Variant"; trh.appendChild(th0);
    payload.parameters.forEach((p) => { const th = document.createElement("th"); th.textContent = p; trh.appendChild(th); });
    thead.appendChild(trh); tbl.appendChild(thead);
    const tbody = document.createElement("tbody");
    payload.rows.forEach((row) => {
      const tr = document.createElement("tr");
      const td0 = document.createElement("td"); td0.textContent = row.variant; tr.appendChild(td0);
      payload.parameters.forEach((p) => {
        const td = document.createElement("td");
        const v = row[p];
        td.textContent = typeof v === "number" ? v.toFixed(4) : (v == null ? "" : v);
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });
    tbl.appendChild(tbody);
    wrap.appendChild(tbl);
  }

  function setStatus(text, kind) {
    const el = $("scStatus");
    if (!el) return;
    el.textContent = text;
    el.classList.remove("sc-status-ok", "sc-status-error");
    if (kind === "ok") el.classList.add("sc-status-ok");
    else if (kind === "error") el.classList.add("sc-status-error");
  }

  // ===========================================================================
  // Progress UI + demo simulation
  //
  // Status values:
  //   - "idle"    grey    (worker reserved, no variant assigned)
  //   - "running" amber   (worker is actively solving a variant; pulses)
  //   - "done"    green   (variant finished optimal)
  //   - "failed"  red     (any error: infeasible, unbounded, crash, timeout)
  //
  // Progress payload shape (Phase 3 endpoint will produce this exact shape):
  //   {
  //     campaign: { name, total, started_at },
  //     workers:  [ { id, status, variant_id, completed, assigned, started_at } ]
  //   }
  // ===========================================================================
  function bindProgressControls() {
    const start = $("campaignDemoStart");
    const stop = $("campaignDemoStop");
    const pauseBtn = $("campaignPauseBtn");
    const resumeBtn = $("campaignResumeBtn");
    const stopBtn = $("campaignStopBtn");
    if (start) start.addEventListener("click", startDemo);
    if (stop) stop.addEventListener("click", () => {
      // Stop demo only — live campaign has its own Stop button now.
      stopDemo();
    });
    if (pauseBtn) pauseBtn.addEventListener("click", () => {
      pauseLiveCampaign().catch((err) => console.warn("pause failed", err));
    });
    if (resumeBtn) resumeBtn.addEventListener("click", () => {
      resumeLiveCampaign().catch((err) => console.warn("resume failed", err));
    });
    if (stopBtn) stopBtn.addEventListener("click", () => {
      if (!confirm("Stop the campaign? Progress is kept but the run cannot be resumed.")) return;
      stopLiveCampaign().catch((err) => console.warn("stop failed", err));
    });
  }

  function bindScenarioResultsControls() {
    const refresh = $("scenarioRefreshCampaigns");
    if (refresh) refresh.addEventListener("click", () => {
      fetchScenarioCampaigns().catch((err) => console.warn("scenario/campaigns refresh failed", err));
    });
  }

  // ---------------------------------------------------------------------------
  // Real-campaign launch + polling (Phase 3.5)
  // ---------------------------------------------------------------------------
  async function runCampaign() {
    // Always validate first so the user sees errors before we launch.
    const v = await validateNow();
    if (v && v.valid === false) {
      setStatus("Fix the validation errors before running.", "error");
      return;
    }
    const body = buildRunBody();
    setStatus("Launching campaign\u2026", "");
    let r, rawText;
    try {
      r = await fetch("/api/scenario/run", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      rawText = await r.text();
    } catch (e) {
      setStatus("Server unreachable: " + (e.message || e), "error");
      return;
    }
    let payload;
    try { payload = JSON.parse(rawText); } catch (_) { payload = null; }
    if (!payload || payload.ok === false || payload.ok === undefined) {
      // Surface whatever the server gave us: errors[] (validation), error (singular),
      // or the raw body + HTTP status as a last resort.
      let msg = null;
      if (payload) {
        if (Array.isArray(payload.errors) && payload.errors.length) msg = payload.errors[0];
        else if (payload.error) msg = String(payload.error);
      }
      // A bare "Not found" with HTTP 404 is the classic stale-server symptom:
      // the route exists in the source but the running Julia process loaded an
      // older version of src/ui_server.jl. Spell that out for the user.
      if (r && r.status === 404 && msg && /not found/i.test(msg)) {
        msg = "Server responded 404 for POST /api/scenario/run. The route exists in the code, "
            + "which means the Julia server is running stale code. Restart the Julia REPL "
            + "(or re-run `IESAOpt.serve_ui()`) so the new routes are loaded.";
      } else if (!msg) {
        msg = `Run failed (HTTP ${r ? r.status : "?"}): ${rawText ? rawText.slice(0, 240) : "empty response"}`;
      }
      console.error("[scenario/run] failed", { status: r && r.status, body: rawText, payload });
      setStatus(msg, "error");
      return;
    }
    setStatus("Campaign queued: " + payload.campaign_id, "ok");
    progressState.activeCampaignId = payload.campaign_id;
    // Seed the dashboard from the initial snapshot.
    applySnapshot(payload.snapshot);
    fetchScenarioCampaigns().catch(() => {});
    // Switch the user to the Progress sub-tab so they can watch it run.
    activateProgressTab();
    startPolling(payload.campaign_id);
  }

  function buildRunBody() {
    const spec = collectSpec();
    // Prefer a user-browsed file over the dropdown selection.
    spec.inputWorkbook = state.customWorkbookPath
      || (($("scInputWorkbook") || {}).value)
      || "Input/default_data.xlsx";
    spec.n_workers = Number(($("scWorkers") || {}).value) || 1;
    spec.threads_per_worker = computeThreadsPerWorker();
    spec.solver = ($("scSolver") || {}).value || "highs";
    spec.mode = computeMode();
    spec.periods = collectPeriods();
    return spec;
  }

  function computeThreadsPerWorker() {
    const totalThreads = Number(($("scThreads") || {}).value) || 0;
    const workers = Math.max(1, Number(($("scWorkers") || {}).value) || 1);
    return totalThreads > 0 ? Math.max(1, Math.floor(totalThreads / workers)) : 1;
  }

  function computeMode() {
    const ts = $("scTimeSlicingToggle");
    if (ts && ts.checked === false) return "fh";
    return "ts";
  }

  function collectPeriods() {
    const wrap = $("scPeriods");
    if (!wrap) return [];
    return Array.from(wrap.querySelectorAll("input[type='checkbox']:checked"))
      .map((cb) => Number(cb.value)).filter((n) => !isNaN(n));
  }

  function activateProgressTab() {
    // Switch the user to the Progress sub-tab so they can watch live updates.
    const tab = document.querySelector(".tab-button[data-tab='scenario-progress']");
    if (tab) tab.click();
  }

  function applySnapshot(snap) {
    if (!snap || !snap.campaign) return;
    progressState.active = !snap.done;
    progressState.campaign = {
      name: snap.campaign.name || "",
      total: snap.campaign.total || 0,
      started_at: (snap.campaign.started_at || 0) * 1000,
      state: String(snap.campaign.state || snap.campaign.status || ""),
      stage: String(snap.campaign.stage || ""),
      n_workers: Number(snap.campaign.n_workers || 0),
      avg_task_seconds: Number(snap.campaign.avg_task_seconds || 0),
      task_seconds_count: Number(snap.campaign.task_seconds_count || 0),
      collect_save_seconds: Number(snap.campaign.collect_save_seconds || 0),
      error: snap.error || null,
    };
    progressState.phases = normalizeCampaignPhases(snap.phases, progressState.campaign.state);
    progressState.workers = (snap.workers || []).map((w) => ({
      id: w.id,
      status: w.status,
      variant_id: w.variant_id,
      assigned: w.assigned || 0,
      started: w.started || 0,
      completed: w.completed || 0,
      failed: w.failed || 0,
      progress: (w.progress || 0) * 100,
      started_at: (w.started_at || 0) * 1000,
      pid: w.pid || null,
      rss_bytes: w.rss_bytes || 0,
      last_error: w.last_error || null,
      last_term: w.last_term || null,
      last_failed_variant: w.last_failed_variant || null,
    }));
    progressState.failures = Array.isArray(snap.failures) ? snap.failures.slice(0, 50) : [];
    applyLiveButtonVisibility(progressState.campaign.state, !!snap.done);
    renderProgress();
  }

  // Show/hide Pause / Resume / Stop / Start-demo / Stop-demo according
  // to the live campaign's lifecycle state. Demo buttons are kept out
  // of the way whenever a live campaign exists.
  function applyLiveButtonVisibility(state, done) {
    const pauseBtn  = $("campaignPauseBtn");
    const resumeBtn = $("campaignResumeBtn");
    const stopBtn   = $("campaignStopBtn");
    const demoStart = $("campaignDemoStart");
    const demoStop  = $("campaignDemoStop");

    const show = (el) => el && el.classList.remove("hidden");
    const hide = (el) => el && el.classList.add("hidden");
    const setEnabled = (el, on) => { if (el) el.disabled = !on; };

    // Default: hide everything; we re-enable per branch below.
    hide(pauseBtn); hide(resumeBtn); hide(stopBtn);
    setEnabled(pauseBtn, true); setEnabled(resumeBtn, true); setEnabled(stopBtn, true);

    const isLive = !!state;
    if (!isLive || done || state === "completed" || state === "cancelled" || state === "failed") {
      // No live campaign or it terminated -> only demo buttons matter.
      show(demoStart); hide(demoStop);
      if (done) progressState.activeCampaignId = null;
      return;
    }

    // Live campaign exists -> hide demo buttons.
    hide(demoStart); hide(demoStop);

    if (state === "running") {
      show(pauseBtn); show(stopBtn);
    } else if (state === "paused") {
      show(resumeBtn); show(stopBtn);
    } else if (state === "pausing") {
      show(pauseBtn); setEnabled(pauseBtn, false);
      show(stopBtn);
    } else if (state === "resuming") {
      show(resumeBtn); setEnabled(resumeBtn, false);
      show(stopBtn);
    } else if (state === "cancelling") {
      show(stopBtn); setEnabled(stopBtn, false);
    } else {
      // preparing / queued / reading -> show Stop so the user can abort.
      show(stopBtn);
    }
  }

  function startPolling(id) {
    stopPolling();
    progressState.pollTimer = setInterval(async () => {
      try {
        const r = await fetch("/api/scenario/status/" + encodeURIComponent(id));
        const snap = await r.json();
        if (!snap || snap.ok === false) {
          stopPolling();
          return;
        }
        applySnapshot(snap);
        if (snap.done) {
          stopPolling();
          progressState.active = false;
          fetchScenarioResult(id).catch((err) => console.warn("scenario/result fetch failed", err));
          fetchScenarioCampaigns().catch((err) => console.warn("scenario/campaigns refresh failed", err));
          // applyLiveButtonVisibility (called from applySnapshot) already
          // restored the demo buttons and cleared activeCampaignId.
          renderProgress();
        }
      } catch (err) {
        console.warn("scenario/status poll failed", err);
      }
    }, 1000);
  }

  function stopPolling() {
    if (progressState.pollTimer) {
      clearInterval(progressState.pollTimer);
      progressState.pollTimer = null;
    }
  }

  async function fetchScenarioResult(id) {
    if (!id) return;
    const r = await fetch("/api/scenario/result/" + encodeURIComponent(id));
    const payload = await r.json();
    if (!payload || payload.ok === false) {
      renderScenarioResults({ scatter: [], error: payload && payload.error });
      return;
    }
    scenarioResultsState.campaignId = id;
    scenarioResultsState.scatter = Array.isArray(payload.scatter) ? payload.scatter : [];
    renderScenarioResults(payload);
  }

  async function fetchScenarioCampaigns() {
    const r = await fetch("/api/scenario/campaigns");
    const payload = await r.json();
    if (!payload || payload.ok === false) {
      scenarioResultsState.campaigns = [];
      renderScenarioCampaignList(payload && payload.error);
      return;
    }
    scenarioResultsState.campaigns = Array.isArray(payload.campaigns) ? payload.campaigns : [];
    renderScenarioCampaignList();
  }

  function renderScenarioCampaignList(error) {
    const list = $("scenarioCampaignList");
    const summary = $("scenarioCampaignListSummary");
    const rows = scenarioResultsState.campaigns || [];
    if (summary) {
      summary.textContent = error ? "Could not load campaigns." : `${rows.length} campaign${rows.length === 1 ? "" : "s"} available.`;
    }
    if (!list) return;
    list.innerHTML = "";
    if (error) {
      list.className = "scenario-campaign-list empty-state";
      list.textContent = error;
      return;
    }
    if (!rows.length) {
      list.className = "scenario-campaign-list empty-state";
      list.textContent = "No Scenario Space campaigns yet.";
      return;
    }
    list.className = "scenario-campaign-list";
    rows.forEach((c) => list.appendChild(renderScenarioCampaignItem(c)));
  }

  function renderScenarioCampaignItem(c) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "scenario-campaign-item" + (c.id === scenarioResultsState.campaignId ? " active" : "");
    const finished = Number(c.completed || 0) + Number(c.failed || 0);
    const total = Number(c.total || 0);
    const started = c.started_at ? formatFinishClock(Number(c.started_at) * 1000) : "";
    btn.innerHTML = `<span class="scenario-campaign-name">${escapeHtml(c.name || c.id)}</span>`
      + `<span class="scenario-campaign-meta">${escapeHtml(c.state || "unknown")} · ${finished}/${total} done · ${Number(c.result_count || 0)} results</span>`
      + (started ? `<span class="scenario-campaign-time">Started ${escapeHtml(started)}</span>` : "");
    btn.addEventListener("click", () => {
      scenarioResultsState.campaignId = c.id;
      renderScenarioCampaignList();
      fetchScenarioResult(c.id).catch((err) => {
        renderScenarioResults({ scatter: [], error: err && err.message ? err.message : String(err) });
      });
    });
    return btn;
  }

  function renderScenarioResults(payload) {
    const rows = Array.isArray(payload && payload.scatter) ? payload.scatter : scenarioResultsState.scatter || [];
    const summary = $("scenarioResultsSummary");
    const total = rows.length;
    const points = rows.map((r) => ({
      variant_id: Number(r.variant_id),
      worker_id: r.worker_id,
      system_cost: Number(r.system_cost),
      co2_price: Number(r.co2_price),
      term_status: String(r.term_status || ""),
    })).filter((r) => Number.isFinite(r.system_cost) && Number.isFinite(r.co2_price));

    if (summary) {
      if (payload && payload.error) {
        summary.textContent = "Could not load campaign results: " + payload.error;
      } else if (points.length) {
        summary.textContent = `${points.length} plotted variant${points.length === 1 ? "" : "s"} from ${total} completed result${total === 1 ? "" : "s"}.`;
      } else if (total) {
        summary.textContent = `${total} result${total === 1 ? "" : "s"} loaded, but no finite CO2 prices were available.`;
      } else {
        summary.textContent = "No campaign results loaded.";
      }
    }

    renderCostCo2Scatter(points, total);
    renderScenarioAnalysis(rows, payload);
  }

  function renderCostCo2Scatter(points, totalRows) {
    const el = $("scenarioCostCo2Scatter");
    if (!el) return;
    if (!window.Plotly) {
      el.className = "bar-chart empty-state";
      el.textContent = "Plotly is not loaded.";
      return;
    }
    if (!points.length) {
      if (el._fullLayout) window.Plotly.purge(el);
      el.className = "bar-chart empty-state";
      el.textContent = totalRows ? "No finite CO2 price values available for completed variants." : "No campaign results yet.";
      return;
    }
    el.className = "bar-chart plotly-chart";
    const trace = {
      type: "scattergl",
      mode: "markers",
      x: points.map((r) => r.system_cost),
      y: points.map((r) => r.co2_price),
      text: points.map((r) => `Variant ${r.variant_id}`),
      customdata: points.map((r) => [r.variant_id, r.worker_id || "", r.term_status || ""]),
      hovertemplate: "Variant %{customdata[0]}<br>System cost: %{x:,.3f}<br>CO2 price: %{y:,.3f} EUR/tCO2eq<br>Worker: %{customdata[1]}<br>Status: %{customdata[2]}<extra></extra>",
      marker: { size: 8, color: "#007a78", opacity: 0.78, line: { color: "#0f2436", width: 0.5 } },
    };
    const layout = {
      margin: { l: 64, r: 18, t: 16, b: 56 },
      paper_bgcolor: "rgba(0,0,0,0)",
      plot_bgcolor: "rgba(0,0,0,0)",
      xaxis: { title: "System cost (objective)", gridcolor: "#dbe4ec", zerolinecolor: "#c8d5df", automargin: true },
      yaxis: { title: "CO2 price (EUR/tCO2eq)", gridcolor: "#dbe4ec", zerolinecolor: "#c8d5df", automargin: true },
      hovermode: "closest",
      showlegend: false,
    };
    window.Plotly.react(el, [trace], layout, { responsive: true, displaylogo: false, modeBarButtonsToRemove: ["lasso2d", "select2d"] });
  }

  function renderScenarioAnalysis(rows, payload) {
    const campaign = payload && payload.campaign ? payload.campaign : {};
    const gsaMethod = String(campaign.gsa_method || (($("scGsaMethod") || {}).value) || "rank");
    const usable = (Array.isArray(rows) ? rows : []).map((r) => ({
      variant_id: Number(r.variant_id),
      system_cost: Number(r.system_cost),
      co2_price: Number(r.co2_price),
      parameters: r && r.parameters && typeof r.parameters === "object" ? r.parameters : {},
    })).filter((r) => Number.isFinite(r.system_cost) && Object.keys(r.parameters).length);
    if (!usable.length) {
      analysisEmpty("scenarioPrimSummary", "scenarioPrimChart", "scenarioPrimTable", "Scenario Discovery needs completed campaign rows with sampled parameter values.");
      analysisEmpty("scenarioGsaSummary", "scenarioGsaChart", "scenarioGsaTable", "GSA needs completed campaign rows with sampled parameter values.");
      return;
    }
    const labels = Object.keys(usable[0].parameters).filter((label) => usable.some((r) => Number.isFinite(Number(r.parameters[label]))));
    if (!labels.length) {
      analysisEmpty("scenarioPrimSummary", "scenarioPrimChart", "scenarioPrimTable", "No numeric sampled parameters were available.");
      analysisEmpty("scenarioGsaSummary", "scenarioGsaChart", "scenarioGsaTable", "No numeric sampled parameters were available.");
      return;
    }
    const prim = computePrimBoxes(usable, labels);
    const gsa = computeGsaRows(usable, labels, gsaMethod);
    renderPrim(prim, usable.length);
    renderGsa(gsa, usable.length, gsaMethod);
  }

  function analysisEmpty(summaryId, chartId, tableId, message) {
    const summary = $(summaryId);
    const chart = $(chartId);
    const table = $(tableId);
    if (summary) summary.textContent = message;
    if (chart) {
      if (chart._fullLayout && window.Plotly) window.Plotly.purge(chart);
      chart.className = "atlas-chart empty-state";
      chart.textContent = message;
    }
    if (table) {
      table.className = "table-wrap explorer-table empty-state";
      table.textContent = message;
    }
  }

  function quantile(values, q) {
    const xs = values.filter(Number.isFinite).sort((a, b) => a - b);
    if (!xs.length) return NaN;
    const pos = (xs.length - 1) * q;
    const lo = Math.floor(pos);
    const hi = Math.ceil(pos);
    if (lo === hi) return xs[lo];
    return xs[lo] + (xs[hi] - xs[lo]) * (pos - lo);
  }

  function computePrimBoxes(rows, labels) {
    const threshold = quantile(rows.map((r) => r.system_cost), 0.25);
    const target = rows.filter((r) => r.system_cost <= threshold);
    const totalTarget = Math.max(1, target.length);
    return labels.map((label) => {
      const allVals = rows.map((r) => Number(r.parameters[label])).filter(Number.isFinite);
      const targetVals = target.map((r) => Number(r.parameters[label])).filter(Number.isFinite);
      const lo = quantile(targetVals, 0.1);
      const hi = quantile(targetVals, 0.9);
      const inBox = rows.filter((r) => {
        const v = Number(r.parameters[label]);
        return Number.isFinite(v) && v >= lo && v <= hi;
      });
      const inTarget = inBox.filter((r) => r.system_cost <= threshold);
      return {
        label,
        min: lo,
        max: hi,
        fullMin: quantile(allVals, 0),
        fullMax: quantile(allVals, 1),
        density: inBox.length ? inTarget.length / inBox.length : 0,
        coverage: inTarget.length / totalTarget,
        mass: inBox.length / Math.max(1, rows.length),
        meanCost: inBox.length ? inBox.reduce((acc, r) => acc + r.system_cost, 0) / inBox.length : NaN,
      };
    }).filter((r) => Number.isFinite(r.min) && Number.isFinite(r.max))
      .sort((a, b) => (b.density * b.coverage) - (a.density * a.coverage))
      .slice(0, 12);
  }

  function ranks(values) {
    const indexed = values.map((v, i) => ({ v, i })).sort((a, b) => a.v - b.v);
    const out = Array(values.length).fill(0);
    let i = 0;
    while (i < indexed.length) {
      let j = i + 1;
      while (j < indexed.length && indexed[j].v === indexed[i].v) j += 1;
      const rank = (i + j + 1) / 2;
      for (let k = i; k < j; k += 1) out[indexed[k].i] = rank;
      i = j;
    }
    return out;
  }

  function corr(x, y) {
    const n = Math.min(x.length, y.length);
    if (n < 3) return NaN;
    const mx = x.reduce((a, b) => a + b, 0) / n;
    const my = y.reduce((a, b) => a + b, 0) / n;
    let num = 0, dx = 0, dy = 0;
    for (let i = 0; i < n; i += 1) {
      const vx = x[i] - mx;
      const vy = y[i] - my;
      num += vx * vy;
      dx += vx * vx;
      dy += vy * vy;
    }
    return dx > 0 && dy > 0 ? num / Math.sqrt(dx * dy) : NaN;
  }

  function spearman(rows, label, output) {
    const pairs = rows.map((r) => [Number(r.parameters[label]), Number(r[output])]).filter((p) => Number.isFinite(p[0]) && Number.isFinite(p[1]));
    if (pairs.length < 4) return NaN;
    return corr(ranks(pairs.map((p) => p[0])), ranks(pairs.map((p) => p[1])));
  }

  function mean(values) {
    return values.length ? values.reduce((acc, v) => acc + v, 0) / values.length : NaN;
  }

  function stdev(values) {
    if (values.length < 2) return 0;
    const m = mean(values);
    return Math.sqrt(values.reduce((acc, v) => acc + Math.pow(v - m, 2), 0) / (values.length - 1));
  }

  function computeRankGsaRows(rows, labels) {
    return labels.map((label) => {
      const cost = spearman(rows, label, "system_cost");
      const co2 = spearman(rows, label, "co2_price");
      return { label, method: "rank", cost, co2, influence: Math.max(Math.abs(cost) || 0, Math.abs(co2) || 0) };
    }).filter((r) => Number.isFinite(r.cost) || Number.isFinite(r.co2))
      .sort((a, b) => b.influence - a.influence)
      .slice(0, 18);
  }

  function computeMorrisRows(rows, labels) {
    const sorted = rows.slice().sort((a, b) => a.variant_id - b.variant_id);
    const byLabel = new Map(labels.map((label) => [label, { cost: [], co2: [] }]));
    for (let i = 1; i < sorted.length; i += 1) {
      const prev = sorted[i - 1];
      const curr = sorted[i];
      const changed = labels.filter((label) => {
        const a = Number(prev.parameters[label]);
        const b = Number(curr.parameters[label]);
        return Number.isFinite(a) && Number.isFinite(b) && Math.abs(b - a) > 1e-12;
      });
      if (changed.length !== 1) continue;
      const label = changed[0];
      const dx = Number(curr.parameters[label]) - Number(prev.parameters[label]);
      if (!Number.isFinite(dx) || Math.abs(dx) <= 1e-12) continue;
      const bucket = byLabel.get(label);
      if (Number.isFinite(prev.system_cost) && Number.isFinite(curr.system_cost)) bucket.cost.push((curr.system_cost - prev.system_cost) / dx);
      if (Number.isFinite(prev.co2_price) && Number.isFinite(curr.co2_price)) bucket.co2.push((curr.co2_price - prev.co2_price) / dx);
    }
    return labels.map((label) => {
      const bucket = byLabel.get(label) || { cost: [], co2: [] };
      const costMu = mean(bucket.cost);
      const costMuStar = mean(bucket.cost.map(Math.abs));
      const costSigma = stdev(bucket.cost);
      const co2Mu = mean(bucket.co2);
      const co2MuStar = mean(bucket.co2.map(Math.abs));
      const co2Sigma = stdev(bucket.co2);
      return { label, method: "morris", n: Math.max(bucket.cost.length, bucket.co2.length), costMu, costMuStar, costSigma, co2Mu, co2MuStar, co2Sigma, influence: Math.max(costMuStar || 0, co2MuStar || 0) };
    }).filter((r) => r.n > 0)
      .sort((a, b) => b.influence - a.influence)
      .slice(0, 18);
  }

  function varianceIndex(rows, label, output) {
    const pairs = rows.map((r) => [Number(r.parameters[label]), Number(r[output])]).filter((p) => Number.isFinite(p[0]) && Number.isFinite(p[1]));
    if (pairs.length < 8) return NaN;
    pairs.sort((a, b) => a[0] - b[0]);
    const ys = pairs.map((p) => p[1]);
    const totalVar = Math.pow(stdev(ys), 2);
    if (!(totalVar > 0)) return NaN;
    const bins = Math.max(3, Math.min(8, Math.floor(Math.sqrt(pairs.length))));
    const globalMean = mean(ys);
    let between = 0;
    for (let b = 0; b < bins; b += 1) {
      const start = Math.floor(b * pairs.length / bins);
      const stop = Math.floor((b + 1) * pairs.length / bins);
      const part = pairs.slice(start, stop).map((p) => p[1]);
      if (!part.length) continue;
      between += part.length * Math.pow(mean(part) - globalMean, 2);
    }
    return Math.max(0, Math.min(1, between / (pairs.length * totalVar)));
  }

  function computeVarianceRows(rows, labels) {
    return labels.map((label) => {
      const costS1 = varianceIndex(rows, label, "system_cost");
      const co2S1 = varianceIndex(rows, label, "co2_price");
      return { label, method: "sobol", costS1, co2S1, influence: Math.max(costS1 || 0, co2S1 || 0) };
    }).filter((r) => Number.isFinite(r.costS1) || Number.isFinite(r.co2S1))
      .sort((a, b) => b.influence - a.influence)
      .slice(0, 18);
  }

  function cdfAt(sortedValues, x) {
    let lo = 0;
    let hi = sortedValues.length;
    while (lo < hi) {
      const mid = Math.floor((lo + hi) / 2);
      if (sortedValues[mid] <= x) lo = mid + 1;
      else hi = mid;
    }
    return sortedValues.length ? lo / sortedValues.length : NaN;
  }

  function borgonovoDelta(rows, label, output) {
    const pairs = rows.map((r) => [Number(r.parameters[label]), Number(r[output])]).filter((p) => Number.isFinite(p[0]) && Number.isFinite(p[1]));
    if (pairs.length < 10) return NaN;
    pairs.sort((a, b) => a[0] - b[0]);
    const global = pairs.map((p) => p[1]).sort((a, b) => a - b);
    const gridCount = Math.min(25, Math.max(8, Math.floor(Math.sqrt(global.length))));
    const grid = Array.from({ length: gridCount }, (_, i) => quantile(global, (i + 0.5) / gridCount)).filter(Number.isFinite);
    const bins = Math.max(3, Math.min(8, Math.floor(Math.sqrt(pairs.length))));
    let delta = 0;
    let used = 0;
    for (let b = 0; b < bins; b += 1) {
      const start = Math.floor(b * pairs.length / bins);
      const stop = Math.floor((b + 1) * pairs.length / bins);
      const conditional = pairs.slice(start, stop).map((p) => p[1]).sort((a, b2) => a - b2);
      if (conditional.length < 2) continue;
      const distance = mean(grid.map((x) => Math.abs(cdfAt(conditional, x) - cdfAt(global, x))));
      delta += (conditional.length / pairs.length) * distance;
      used += conditional.length;
    }
    return used ? Math.max(0, Math.min(1, delta)) : NaN;
  }

  function computeMomentDeltaRows(rows, labels) {
    return labels.map((label) => {
      const costDelta = borgonovoDelta(rows, label, "system_cost");
      const co2Delta = borgonovoDelta(rows, label, "co2_price");
      return { label, method: "moment_delta", costDelta, co2Delta, influence: Math.max(costDelta || 0, co2Delta || 0) };
    }).filter((r) => Number.isFinite(r.costDelta) || Number.isFinite(r.co2Delta))
      .sort((a, b) => b.influence - a.influence)
      .slice(0, 18);
  }

  function computeGsaRows(rows, labels, method) {
    if (method === "morris") return computeMorrisRows(rows, labels);
    if (method === "sobol") return computeVarianceRows(rows, labels);
    if (method === "moment_delta") return computeMomentDeltaRows(rows, labels);
    return computeRankGsaRows(rows, labels);
  }

  function renderPrim(rows, n) {
    const summary = $("scenarioPrimSummary");
    if (summary) summary.textContent = rows.length ? `PRIM-style discovery from ${n} completed variants; target is the lowest-cost quartile.` : "No PRIM boxes found.";
    const table = $("scenarioPrimTable");
    if (table) {
      if (!rows.length) {
        table.className = "table-wrap explorer-table empty-state";
        table.textContent = "No PRIM boxes found.";
      } else {
        table.className = "table-wrap explorer-table";
        table.innerHTML = `<table><thead><tr><th>Parameter</th><th>Box range</th><th>Density</th><th>Coverage</th><th>Mass</th><th>Mean cost</th></tr></thead><tbody>${rows.map((r) => `<tr><td>${escapeHtml(r.label)}</td><td>${r.min.toPrecision(4)} to ${r.max.toPrecision(4)}</td><td>${(100 * r.density).toFixed(1)}%</td><td>${(100 * r.coverage).toFixed(1)}%</td><td>${(100 * r.mass).toFixed(1)}%</td><td>${Number.isFinite(r.meanCost) ? r.meanCost.toPrecision(5) : ""}</td></tr>`).join("")}</tbody></table>`;
      }
    }
    const chart = $("scenarioPrimChart");
    if (!chart || !window.Plotly || !rows.length) {
      if (chart) { chart.className = "atlas-chart empty-state"; chart.textContent = rows.length ? "Plotly is not loaded." : "No PRIM boxes found."; }
      return;
    }
    chart.className = "atlas-chart plotly-chart";
    window.Plotly.react(chart, [{ type: "bar", orientation: "h", y: rows.map((r) => r.label).reverse(), x: rows.map((r) => r.density).reverse(), name: "Density", marker: { color: "#007a78" } }, { type: "bar", orientation: "h", y: rows.map((r) => r.label).reverse(), x: rows.map((r) => r.coverage).reverse(), name: "Coverage", marker: { color: "#c07122" } }], { barmode: "group", margin: { l: 160, r: 16, t: 16, b: 42 }, paper_bgcolor: "rgba(0,0,0,0)", plot_bgcolor: "rgba(0,0,0,0)", xaxis: { title: "Share", tickformat: ".0%", gridcolor: "#dbe4ec" }, yaxis: { automargin: true } }, { responsive: true, displaylogo: false });
  }

  function renderGsa(rows, n, method) {
    const summary = $("scenarioGsaSummary");
    const methodInfo = GSA_METHODS[method] || GSA_METHODS.rank;
    const summaryText = method === "morris"
      ? `Morris elementary-effect metrics from ${n} completed variants.`
      : method === "sobol"
        ? `Sobol-style first-order variance indices from ${n} completed variants.`
        : method === "moment_delta"
          ? `Moment-independent Borgonovo-style delta indices from ${n} completed variants.`
          : `Rank-correlation sensitivity from ${n} completed variants.`;
    if (summary) summary.textContent = rows.length ? summaryText : `No ${methodInfo.label} rows found.`;
    const table = $("scenarioGsaTable");
    if (table) {
      if (!rows.length) {
        table.className = "table-wrap explorer-table empty-state";
        table.textContent = `No ${methodInfo.label} rows found.`;
      } else {
        table.className = "table-wrap explorer-table";
        if (method === "morris") {
          table.innerHTML = `<table><thead><tr><th>Parameter</th><th>Effects</th><th>Cost mu*</th><th>Cost sigma</th><th>CO2 mu*</th><th>CO2 sigma</th></tr></thead><tbody>${rows.map((r) => `<tr><td>${escapeHtml(r.label)}</td><td>${r.n}</td><td>${Number.isFinite(r.costMuStar) ? r.costMuStar.toPrecision(4) : ""}</td><td>${Number.isFinite(r.costSigma) ? r.costSigma.toPrecision(4) : ""}</td><td>${Number.isFinite(r.co2MuStar) ? r.co2MuStar.toPrecision(4) : ""}</td><td>${Number.isFinite(r.co2Sigma) ? r.co2Sigma.toPrecision(4) : ""}</td></tr>`).join("")}</tbody></table>`;
        } else if (method === "sobol") {
          table.innerHTML = `<table><thead><tr><th>Parameter</th><th>System cost S1</th><th>CO2 price S1</th><th>Influence</th></tr></thead><tbody>${rows.map((r) => `<tr><td>${escapeHtml(r.label)}</td><td>${Number.isFinite(r.costS1) ? r.costS1.toFixed(3) : ""}</td><td>${Number.isFinite(r.co2S1) ? r.co2S1.toFixed(3) : ""}</td><td>${r.influence.toFixed(3)}</td></tr>`).join("")}</tbody></table>`;
        } else if (method === "moment_delta") {
          table.innerHTML = `<table><thead><tr><th>Parameter</th><th>System cost delta</th><th>CO2 price delta</th><th>Influence</th></tr></thead><tbody>${rows.map((r) => `<tr><td>${escapeHtml(r.label)}</td><td>${Number.isFinite(r.costDelta) ? r.costDelta.toFixed(3) : ""}</td><td>${Number.isFinite(r.co2Delta) ? r.co2Delta.toFixed(3) : ""}</td><td>${r.influence.toFixed(3)}</td></tr>`).join("")}</tbody></table>`;
        } else {
          table.innerHTML = `<table><thead><tr><th>Parameter</th><th>System cost rho</th><th>CO2 price rho</th><th>Influence</th></tr></thead><tbody>${rows.map((r) => `<tr><td>${escapeHtml(r.label)}</td><td>${Number.isFinite(r.cost) ? r.cost.toFixed(3) : ""}</td><td>${Number.isFinite(r.co2) ? r.co2.toFixed(3) : ""}</td><td>${r.influence.toFixed(3)}</td></tr>`).join("")}</tbody></table>`;
        }
      }
    }
    const chart = $("scenarioGsaChart");
    if (!chart || !window.Plotly || !rows.length) {
      if (chart) { chart.className = "atlas-chart empty-state"; chart.textContent = rows.length ? "Plotly is not loaded." : `No ${methodInfo.label} rows found.`; }
      return;
    }
    chart.className = "atlas-chart plotly-chart";
    const y = rows.map((r) => r.label).reverse();
    const traces = method === "morris"
      ? [{ type: "bar", orientation: "h", y, x: rows.map((r) => r.costMuStar || 0).reverse(), name: "System cost mu*", marker: { color: "#007a78" } }, { type: "bar", orientation: "h", y, x: rows.map((r) => r.co2MuStar || 0).reverse(), name: "CO2 price mu*", marker: { color: "#8a5a2b" } }]
      : method === "sobol"
        ? [{ type: "bar", orientation: "h", y, x: rows.map((r) => r.costS1 || 0).reverse(), name: "System cost S1", marker: { color: "#007a78" } }, { type: "bar", orientation: "h", y, x: rows.map((r) => r.co2S1 || 0).reverse(), name: "CO2 price S1", marker: { color: "#8a5a2b" } }]
        : method === "moment_delta"
          ? [{ type: "bar", orientation: "h", y, x: rows.map((r) => r.costDelta || 0).reverse(), name: "System cost delta", marker: { color: "#007a78" } }, { type: "bar", orientation: "h", y, x: rows.map((r) => r.co2Delta || 0).reverse(), name: "CO2 price delta", marker: { color: "#8a5a2b" } }]
          : [{ type: "bar", orientation: "h", y, x: rows.map((r) => r.cost || 0).reverse(), name: "System cost rho", marker: { color: "#007a78" } }, { type: "bar", orientation: "h", y, x: rows.map((r) => r.co2 || 0).reverse(), name: "CO2 price rho", marker: { color: "#8a5a2b" } }];
    const xaxis = method === "morris"
      ? { title: "Morris mu*", gridcolor: "#dbe4ec", zerolinecolor: "#455a64" }
      : method === "sobol"
        ? { title: "First-order variance index", range: [0, 1], gridcolor: "#dbe4ec", zerolinecolor: "#455a64" }
        : method === "moment_delta"
          ? { title: "Borgonovo delta", range: [0, 1], gridcolor: "#dbe4ec", zerolinecolor: "#455a64" }
          : { title: "Spearman rho", range: [-1, 1], gridcolor: "#dbe4ec", zerolinecolor: "#455a64" };
    window.Plotly.react(chart, traces, { barmode: "group", margin: { l: 160, r: 16, t: 16, b: 42 }, paper_bgcolor: "rgba(0,0,0,0)", plot_bgcolor: "rgba(0,0,0,0)", xaxis, yaxis: { automargin: true } }, { responsive: true, displaylogo: false });
  }

  async function stopLiveCampaign() {
    const id = progressState.activeCampaignId;
    if (!id) return;
    try {
      const r = await fetch("/api/scenario/stop/" + encodeURIComponent(id), { method: "POST" });
      const payload = await r.json().catch(() => ({}));
      if (payload && payload.ok === false && payload.error) {
        setStatus(payload.error, "error");
      }
    } catch (err) {
      console.warn("scenario/stop failed", err);
    }
  }

  async function pauseLiveCampaign() {
    const id = progressState.activeCampaignId;
    if (!id) return;
    try {
      const r = await fetch("/api/scenario/pause/" + encodeURIComponent(id), { method: "POST" });
      const payload = await r.json().catch(() => ({}));
      if (payload && payload.ok === false && payload.error) {
        setStatus(payload.error, "error");
      }
    } catch (err) {
      console.warn("scenario/pause failed", err);
    }
  }

  async function resumeLiveCampaign() {
    const id = progressState.activeCampaignId;
    if (!id) return;
    try {
      const r = await fetch("/api/scenario/resume/" + encodeURIComponent(id), { method: "POST" });
      const payload = await r.json().catch(() => ({}));
      if (payload && payload.ok === false && payload.error) {
        setStatus(payload.error, "error");
        return;
      }
      // The status poll may have stopped if a previous done-snapshot fired;
      // make sure we start polling again now that the task is alive.
      if (!progressState.pollTimer) {
        startPolling(id);
      }
    } catch (err) {
      console.warn("scenario/resume failed", err);
    }
  }

  function startDemo() {
    if (progressState.demoTimer) return;
    // Use the configured worker count so the slider visibly affects the demo.
    const configuredWorkers = Number(($("scWorkers") || {}).value || 0);
    const nWorkers = configuredWorkers > 0
      ? Math.min(50, configuredWorkers)
      : Math.min(8, Math.max(2, Math.floor((state.cpuThreads || detectedCpuThreads()) / 2)));
    const total = Math.max(nWorkers, Number(($("scNVariants") || {}).value) || 60);
    const variantsPerWorker = Math.ceil(total / nWorkers);
    progressState.active = true;
    progressState.startedAt = Date.now();
    progressState.demoPhaseStartedAt = progressState.startedAt;
    progressState.campaign = {
      name: ($("scCampaignName") || {}).value || "demo_campaign",
      total,
      started_at: progressState.startedAt,
      state: "running",
      stage: "Demo campaign running",
    };
    progressState.workers = [];
    progressState.phases = defaultCampaignPhases();
    setProgressPhase("workers", "active", `Starting ${nWorkers} demo workers`);
    progressState.failures = [];
    for (let i = 1; i <= nWorkers; i++) {
      progressState.workers.push({
        id: i,
        status: "running",
        variant_id: i,
        completed: 0,
        failed: 0,
        assigned: variantsPerWorker,
        started: 1,
        progress: 0,
        started_at: progressState.startedAt,
        last_change: progressState.startedAt,
        next_finish_in: 800 + Math.random() * 2400, // ms
        pid: 1000 + i,
        rss_bytes: (350 + Math.random() * 200) * 1024 * 1024, // 350-550 MB fake
      });
    }
    updateDemoPhases();
    $("campaignDemoStart").classList.add("hidden");
    $("campaignDemoStop").classList.remove("hidden");
    progressState.demoTimer = setInterval(tickDemo, 250);
    renderProgress();
  }

  function stopDemo() {
    if (progressState.demoTimer) {
      clearInterval(progressState.demoTimer);
      progressState.demoTimer = null;
    }
    progressState.active = false;
    progressState.campaign.state = "cancelled";
    progressState.campaign.stage = "Demo stopped";
    setProgressPhase("solve", "skipped", "Demo stopped");
    if ($("campaignDemoStart")) $("campaignDemoStart").classList.remove("hidden");
    if ($("campaignDemoStop")) $("campaignDemoStop").classList.add("hidden");
    renderProgress();
  }

  function tickDemo() {
    const now = Date.now();
    const dt = 250;
    let anyRunning = false;
    progressState.workers.forEach((w) => {
      if (w.status !== "running") return;
      anyRunning = true;
      // Drift fake RAM by +/- 5 MB per tick so the demo card visibly updates.
      const drift = (Math.random() - 0.4) * 5 * 1024 * 1024;
      w.rss_bytes = Math.max(64 * 1024 * 1024, (w.rss_bytes || 0) + drift);
      // Advance progress fraction toward 100%
      const remaining = w.next_finish_in - (now - w.last_change);
      const total = w.next_finish_in;
      w.progress = Math.max(0, Math.min(99, Math.round(100 * (1 - remaining / total))));
      if (now - w.last_change >= w.next_finish_in) {
        // Finish this variant
        const variantsRemaining = w.assigned - w.completed - w.failed;
        // 8% chance of failure
        const failed = Math.random() < 0.08;
        const finishedVid = w.variant_id;
        if (failed) {
          w.failed += 1;
          // Demo-only fake error so the failures panel has content.
          const fakeMsgs = [
            "MOI.InvalidIndex: variable index 12345 not found in the model",
            "JuMP.NoOptimizer(): no optimizer attached to the model",
            "MethodError: no method matching applyVariant(::Nothing) — leaf change missing",
            "HiGHS_run: model is infeasible (kHighsStatusError)",
            "OutOfMemoryError: solve aborted by OS (peak RSS exceeded)",
          ];
          w.last_error = fakeMsgs[Math.floor(Math.random() * fakeMsgs.length)];
          w.last_term = Math.random() < 0.5 ? "INFEASIBLE" : "ERROR";
          w.last_failed_variant = finishedVid;
          (progressState.failures = progressState.failures || []).unshift({
            variant_id: finishedVid,
            worker_id: w.id,
            worker_pid: w.pid,
            term_status: w.last_term,
            error: w.last_error,
            at: now / 1000,
          });
          if (progressState.failures.length > 50) progressState.failures.length = 50;
        } else {
          w.completed += 1;
        }
        w.last_change = now;
        if (variantsRemaining > 1) {
          w.status = "running";
          w.variant_id = w.id + (w.completed + w.failed) * progressState.workers.length;
          w.started = (w.started || 0) + 1;
          w.progress = 0;
          w.next_finish_in = 800 + Math.random() * 2400;
        } else {
          w.status = (w.failed > 0 && w.completed === 0) ? "failed" : "done";
          w.variant_id = null;
          w.progress = 100;
        }
      }
    });
    // Auto-stop when everything is finished
    if (!anyRunning) {
      progressState.active = false;
      progressState.campaign.state = "completed";
      progressState.campaign.stage = "Demo completed";
      clearInterval(progressState.demoTimer);
      progressState.demoTimer = null;
      if ($("campaignDemoStart")) $("campaignDemoStart").classList.remove("hidden");
      if ($("campaignDemoStop")) $("campaignDemoStop").classList.add("hidden");
    }
    updateDemoPhases();
    renderProgress();
  }

  function updateDemoPhases() {
    if (!progressState.demoPhaseStartedAt) return;
    const elapsed = Date.now() - progressState.demoPhaseStartedAt;
    const workers = progressState.workers || [];
    const total = (progressState.campaign || {}).total || 0;
    const finished = workers.reduce((acc, w) => acc + (w.completed || 0) + (w.failed || 0), 0);
    progressState.phases = defaultCampaignPhases();
    if (!progressState.active && finished >= total && total > 0) {
      setProgressPhase("workers", "done", `${workers.length} workers loaded`);
      setProgressPhase("assign", "done", `${total} variants assigned`);
      setProgressPhase("generate", "done", `${total} variants generated`);
      setProgressPhase("solve", "done", `${finished}/${total} variants solved`);
      setProgressPhase("write", "skipped", "Export not enabled");
    } else if (elapsed < 900) {
      setProgressPhase("workers", "active", `Starting ${workers.length} workers`);
    } else if (elapsed < 1700) {
      setProgressPhase("workers", "done", `${workers.length} workers loaded`);
      setProgressPhase("assign", "active", `${total} variants waiting`);
    } else if (elapsed < 2500) {
      setProgressPhase("workers", "done", `${workers.length} workers loaded`);
      setProgressPhase("assign", "done", `${total} variants assigned`);
      setProgressPhase("generate", "active", "Building variant inputs");
    } else {
      setProgressPhase("workers", "done", `${workers.length} workers loaded`);
      setProgressPhase("assign", "done", `${total} variants assigned`);
      setProgressPhase("generate", "done", `${total} variants generated`);
      setProgressPhase("solve", "active", `${finished}/${total} variants solved`);
    }
  }

  function renderCampaignPhases(c, total) {
    const grid = $("campaignPhaseGrid");
    const summary = $("campaignPhaseSummary");
    if (!grid) return;
    const phases = normalizeCampaignPhases(progressState.phases || [], (c || {}).state || "");
    grid.innerHTML = "";
    phases.forEach((phase) => {
      const card = document.createElement("div");
      card.className = `campaign-phase-card ${phase.status || "pending"}`;

      const head = document.createElement("div");
      head.className = "campaign-phase-head";
      const label = document.createElement("span");
      label.className = "campaign-phase-label";
      label.textContent = phase.label;
      const status = document.createElement("span");
      status.className = "campaign-phase-status";
      status.textContent = PHASE_STATUS_LABELS[phase.status] || "Pending";
      head.appendChild(label);
      head.appendChild(status);

      const detail = document.createElement("div");
      detail.className = "campaign-phase-detail";
      const parts = [];
      if (phase.detail) parts.push(phase.detail);
      if (typeof phase.seconds === "number" && isFinite(phase.seconds)) parts.push(fmtDuration(phase.seconds));
      detail.textContent = parts.join(" - ") || "Waiting";

      card.appendChild(head);
      card.appendChild(detail);
      grid.appendChild(card);
    });

    if (summary) {
      const failed = phases.find((p) => p.status === "failed");
      const active = phases.find((p) => p.status === "active");
      const completed = total > 0 && phases.every((p) => p.status === "done" || p.status === "skipped");
      if (failed) {
        summary.textContent = `${failed.label}: ${failed.detail || "failed"}`;
      } else if (active) {
        summary.textContent = `${active.label}: ${active.detail || "running"}`;
      } else if (completed) {
        summary.textContent = "Campaign phases finished.";
      } else {
        summary.textContent = "Waiting for a campaign.";
      }
    }
  }

  function pad2(n) { return String(n).padStart(2, "0"); }

  function formatFinishClock(ms) {
    const d = new Date(ms);
    const time = `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}`;
    const now = new Date();
    const sameDay = d.getFullYear() === now.getFullYear()
      && d.getMonth() === now.getMonth()
      && d.getDate() === now.getDate();
    if (sameDay) return time;
    return `${time} (${d.getFullYear()}.${pad2(d.getMonth() + 1)}.${pad2(d.getDate())})`;
  }

  function estimateCampaignFinish(c, total, workerCount) {
    const avgTaskSec = Number(c.avg_task_seconds || 0);
    const startedAt = Number(c.started_at || 0);
    if (!Number.isFinite(avgTaskSec) || avgTaskSec <= 0 || !startedAt || total <= 0) return null;
    const workers = Math.max(1, Number(c.n_workers || workerCount || 1));
    const waves = Math.ceil(total / workers);
    const collectSaveSec = Number.isFinite(Number(c.collect_save_seconds))
      ? Math.max(0, Number(c.collect_save_seconds))
      : Math.max(20, workers * 2 + total * 0.05);
    const projectedSec = waves * avgTaskSec * 1.15 + collectSaveSec;
    let finishMs = startedAt + projectedSec * 1000;
    if (progressState.active && finishMs < Date.now()) {
      finishMs = Date.now() + Math.max(collectSaveSec, avgTaskSec * 1.15) * 1000;
    }
    return { finishMs, avgTaskSec, collectSaveSec, waves };
  }

  function renderProgress() {
    const c = progressState.campaign || {};
    const workers = progressState.workers || [];
    const total = c.total || 0;
    let done = 0, failed = 0, running = 0, queued = 0;
    workers.forEach((w) => {
      done += w.completed || 0;
      failed += w.failed || 0;
      if (w.status === "running") running += 1;
    });
    queued = Math.max(0, total - done - failed - running);

    if ($("campaignTitle")) $("campaignTitle").textContent = c.name ? `Campaign: ${c.name}` : "Campaign progress";
    if ($("campaignSubtitle")) {
      const st = c.state || "";
      const stage = c.stage || "";
      if (st === "paused") {
        $("campaignSubtitle").textContent = stage || `Paused after ${done + failed} of ${total} variants. Press Resume to continue.`;
      } else if (st === "cancelled") {
        $("campaignSubtitle").textContent = stage || `Stopped after ${done + failed} of ${total} variants.`;
      } else if (st === "failed") {
        $("campaignSubtitle").textContent = stage || `Failed.`;
      } else if (st === "completed") {
        $("campaignSubtitle").textContent = `Completed all ${total} variants.`;
      } else if (st === "pausing" || st === "resuming" || st === "cancelling" || st === "preparing") {
        $("campaignSubtitle").textContent = stage || `${st}\u2026`;
      } else if (!progressState.active && total === 0) {
        $("campaignSubtitle").textContent = "No campaign running.";
      } else if (!progressState.active) {
        $("campaignSubtitle").textContent = `Stopped after ${done + failed} of ${total} variants.`;
      } else {
        $("campaignSubtitle").textContent = `${done + failed} of ${total} variants resolved.`;
      }
    }
    if ($("campaignTotal"))   $("campaignTotal").textContent = total;
    if ($("campaignDone"))    $("campaignDone").textContent = done;
    if ($("campaignRunning")) $("campaignRunning").textContent = running;
    if ($("campaignFailed"))  $("campaignFailed").textContent = failed;
    if ($("campaignQueued"))  $("campaignQueued").textContent = queued;
    if ($("campaignWorkers")) $("campaignWorkers").textContent = workers.length;

    const pct = total > 0 ? ((done + failed) / total) * 100 : 0;
    const failedPct = total > 0 ? (failed / total) * 100 : 0;
    const okPct = Math.max(0, pct - failedPct);
    if ($("campaignBarFill")) $("campaignBarFill").style.width = okPct.toFixed(1) + "%";
    if ($("campaignBarFailed")) $("campaignBarFailed").style.width = failedPct.toFixed(1) + "%";
    if ($("campaignPct")) $("campaignPct").textContent = pct.toFixed(0) + "%";

    const bar = document.querySelector(".campaign-bar");
    if (bar) bar.classList.toggle("idle", !progressState.active);

    // Status pill
    const pill = $("campaignStatusPill");
    if (pill) {
      pill.classList.remove("muted", "running", "completed", "failed", "paused");
      const st = (c && c.state) || "";
      if (st === "paused") {
        pill.classList.add("paused"); pill.textContent = "Paused";
      } else if (st === "pausing") {
        pill.classList.add("running"); pill.textContent = "Pausing\u2026";
      } else if (st === "resuming") {
        pill.classList.add("running"); pill.textContent = "Resuming\u2026";
      } else if (st === "cancelling") {
        pill.classList.add("running"); pill.textContent = "Stopping\u2026";
      } else if (st === "cancelled") {
        pill.classList.add("muted"); pill.textContent = "Stopped";
      } else if (st === "failed") {
        pill.classList.add("failed"); pill.textContent = "Failed";
      } else if (!progressState.active && total === 0) {
        pill.classList.add("muted"); pill.textContent = "Idle";
      } else if (failed > 0 && done + failed === total) {
        pill.classList.add("failed"); pill.textContent = `Finished (${failed} failed)`;
      } else if (done + failed === total && total > 0) {
        pill.classList.add("completed"); pill.textContent = "Completed";
      } else {
        pill.classList.add("running"); pill.textContent = "Running";
      }
    }

    // Elapsed + ETA
    const elapsedMs = c.started_at ? Date.now() - c.started_at : 0;
    const elapsedEl = $("campaignElapsed");
    if (elapsedEl) elapsedEl.textContent = "Elapsed: " + (elapsedMs > 0 ? fmtDuration(elapsedMs / 1000) : "\u2014");
    const etaEl = $("campaignEta");
    if (etaEl) {
      const estimate = estimateCampaignFinish(c, total, workers.length);
      if (progressState.active && estimate) {
        etaEl.textContent = "Finish: " + formatFinishClock(estimate.finishMs);
        etaEl.title = `avg completed task ${estimate.avgTaskSec.toFixed(1)}s * ${estimate.waves} worker wave(s) * 1.15 + ${estimate.collectSaveSec.toFixed(1)}s collect/save`;
      } else if (!progressState.active && total === 0) {
        etaEl.textContent = "Finish: \u2014";
        etaEl.title = "";
      } else {
        etaEl.textContent = "Finish: estimating\u2026";
        etaEl.title = "Waiting for at least one completed task.";
      }
    }

    renderCampaignPhases(c, total);

    // Worker grid
    const grid = $("workerGrid");
    if (grid) {
      if (!workers.length) {
        grid.classList.add("empty-state");
        grid.innerHTML = "No workers active. Start a campaign or click <em>Start demo</em> to preview the layout.";
      } else {
        grid.classList.remove("empty-state");
        grid.innerHTML = "";
        workers.forEach((w) => grid.appendChild(renderWorkerCard(w)));
      }
    }

    // Campaign-level error panel (the run_campaign task itself threw).
    const errPanel = $("campaignErrorPanel");
    const errMsg = $("campaignErrorMsg");
    if (errPanel && errMsg) {
      const ce = c.error;
      if (ce && String(ce).trim()) {
        errPanel.classList.remove("hidden");
        errMsg.textContent = String(ce);
      } else {
        errPanel.classList.add("hidden");
        errMsg.textContent = "";
      }
    }

    // Recent per-variant failures panel.
    const failPanel = $("campaignFailuresPanel");
    const failList = $("campaignFailuresList");
    const failCount = $("campaignFailuresCount");
    const failures = progressState.failures || [];
    if (failPanel && failList) {
      if (failures.length === 0) {
        failPanel.classList.add("hidden");
        failList.innerHTML = "";
        if (failCount) failCount.textContent = "";
      } else {
        failPanel.classList.remove("hidden");
        if (failCount) failCount.textContent = `(${failures.length} shown)`;
        failList.innerHTML = "";
        failures.forEach((f) => failList.appendChild(renderFailureRow(f)));
      }
    }
  }

  function renderFailureRow(f) {
    const row = document.createElement("div");
    row.className = "failure-row";
    const head = document.createElement("div");
    head.className = "failure-head";
    const left = document.createElement("span");
    left.innerHTML = `<strong>Variant ${f.variant_id}</strong> &middot; Worker ${f.worker_id}${f.worker_pid ? ` &middot; PID ${f.worker_pid}` : ""}`;
    const right = document.createElement("span");
    right.className = "failure-term";
    right.textContent = f.term_status || "ERROR";
    head.appendChild(left);
    head.appendChild(right);
    row.appendChild(head);
    const pre = document.createElement("pre");
    pre.className = "failure-msg";
    pre.textContent = f.error || "(no message)";
    pre.title = "Click to copy";
    pre.addEventListener("click", () => {
      try { navigator.clipboard.writeText(f.error || ""); } catch (_) {}
    });
    row.appendChild(pre);
    return row;
  }

  function renderWorkerCard(w) {
    const card = document.createElement("div");
    card.className = "worker-card status-" + (w.status || "idle");
    const completed = Math.max(0, Number(w.completed || 0));
    const failed = Math.max(0, Number(w.failed || 0));
    const running = (w.status === "running" && w.variant_id != null) ? 1 : 0;
    const assigned = Math.max(0, Number(w.assigned || 0));
    const total = Math.max(assigned, completed + failed + running);
    const queued = Math.max(0, total - completed - failed - running);
    const pct = (value) => total > 0 ? Math.max(0, Math.min(100, (value / total) * 100)) : 0;

    const head = document.createElement("div");
    head.className = "worker-card-header";
    const id = document.createElement("span");
    id.className = "worker-id";
    id.textContent = "Worker " + w.id + (w.pid ? ` \u00b7 PID ${w.pid}` : "");
    head.appendChild(id);
    const status = document.createElement("span");
    status.className = "worker-status status-" + (w.status || "idle");
    status.textContent = w.status || "idle";
    head.appendChild(status);
    card.appendChild(head);

    const cur = document.createElement("div");
    cur.className = "worker-current";
    cur.innerHTML = w.variant_id != null
      ? `Variant <strong>${w.variant_id}</strong>`
      : (w.status === "done" ? "All variants finished" : (w.status === "failed" ? "Failed run" : "\u2014"));
    card.appendChild(cur);

    const bar = document.createElement("div");
    bar.className = "worker-progress";
    bar.title = `${completed} done, ${running} running, ${failed} failed, ${queued} queued of ${total} task${total === 1 ? "" : "s"}`;
    const doneSeg = document.createElement("div");
    doneSeg.className = "worker-progress-segment worker-progress-done";
    doneSeg.style.width = pct(completed).toFixed(1) + "%";
    const currentSeg = document.createElement("div");
    currentSeg.className = "worker-progress-segment worker-progress-current";
    currentSeg.style.width = pct(running).toFixed(1) + "%";
    const failedSeg = document.createElement("div");
    failedSeg.className = "worker-progress-segment worker-progress-failed";
    failedSeg.style.width = pct(failed).toFixed(1) + "%";
    bar.appendChild(doneSeg);
    bar.appendChild(currentSeg);
    bar.appendChild(failedSeg);
    card.appendChild(bar);

    const meta = document.createElement("div");
    meta.className = "worker-meta";
    const left = document.createElement("span");
    const taskLabel = total === 1 ? "task" : "tasks";
    const parts = [`${completed} done`];
    if (running) parts.push("1 running");
    if (failed) parts.push(`${failed} failed`);
    if (queued) parts.push(`${queued} queued`);
    left.textContent = `${parts.join(", ")} / ${total} ${taskLabel}`;
    const right = document.createElement("span");
    const elapsed = w.started_at ? (Date.now() - w.started_at) / 1000 : 0;
    right.textContent = elapsed > 0 ? fmtDuration(elapsed) : "";
    meta.appendChild(left);
    meta.appendChild(right);
    card.appendChild(meta);

    // RAM (peak resident set) — separate row so it doesn't crowd the meta line.
    const ram = document.createElement("div");
    ram.className = "worker-ram";
    if (w.rss_bytes && w.rss_bytes > 0) {
      ram.innerHTML = `<span class="subtle">RAM (peak)</span> <strong>${fmtBytes(w.rss_bytes)}</strong>`;
      ram.title = `Sys.maxrss() on this worker process — peak resident memory in bytes.`;
    } else {
      ram.innerHTML = `<span class="subtle">RAM (peak)</span> <span class="subtle">\u2014</span>`;
    }
    card.appendChild(ram);

    // Failure detail — show the last error message + term status when this
    // worker most recently failed a variant, so the user doesn't have to
    // hunt through Julia logs to see why.
    if (w.last_error || (w.status === "failed" && w.last_term)) {
      const err = document.createElement("div");
      err.className = "worker-error";
      const header = document.createElement("div");
      header.className = "worker-error-header";
      const label = w.last_failed_variant != null
        ? `Variant ${w.last_failed_variant} failed`
        : "Last failure";
      const term = w.last_term ? ` <span class="worker-error-term">${escapeHtml(w.last_term)}</span>` : "";
      header.innerHTML = `<span>${label}</span>${term}`;
      err.appendChild(header);
      if (w.last_error) {
        const pre = document.createElement("pre");
        pre.className = "worker-error-msg";
        pre.textContent = w.last_error;
        pre.title = "Click to copy";
        pre.addEventListener("click", () => {
          try { navigator.clipboard.writeText(w.last_error); } catch (_) {}
        });
        err.appendChild(pre);
      }
      card.appendChild(err);
    }

    return card;
  }

  function fmtDuration(seconds) {
    seconds = Math.max(0, Math.floor(seconds));
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    if (h > 0) return `${h}h ${m}m`;
    if (m > 0) return `${m}m ${s}s`;
    return `${s}s`;
  }

  function fmtBytes(n) {
    if (!n || n <= 0) return "0 B";
    const units = ["B", "KB", "MB", "GB", "TB"];
    let v = n, i = 0;
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return `${v >= 10 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`;
  }

  function escapeHtml(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  // ===========================================================================
  // Public hook + bootstrap
  // ===========================================================================
  window.IESAScenario = {
    populateForm: populateForm,
    setCustomWorkbook: setCustomWorkbook,
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();

