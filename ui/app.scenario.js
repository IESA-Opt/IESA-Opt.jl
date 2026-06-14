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

  // Default rows mirror the SSDashboard parameter_space_example.xlsx so the
  // user immediately sees a valid spec they can edit/extend.
  const DEFAULT_ROWS = [
    { parameter: "CO2 cap",              subparameter: "CO2 cap",              sheet: "Technologies", cell: "AA10", type: "set",      min: 0,   max: 10,  step: "",  notes: "" },
    { parameter: "RES capex multiplier", subparameter: "Wind",                 sheet: "Technologies", cell: "AB6",  type: "multiply", min: 0.5, max: 2.5, step: "",  notes: "" },
    { parameter: "RES capex multiplier", subparameter: "Solar",                sheet: "Technologies", cell: "AB7",  type: "multiply", min: "",  max: "",  step: "",  notes: "" },
    { parameter: "Import price biomass", subparameter: "Import price biomass", sheet: "Technologies", cell: "AC3",  type: "set",      min: 0,   max: 10,  step: 2,   notes: "" },
  ];

  const state = {
    rows: DEFAULT_ROWS.map((r) => Object.assign({}, r)),
    selected: new Set(),
    visibleColumns: new Set(COLUMNS.map((c) => c.id)),
    customWorkbookPath: "",
    bound: false,
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
    failures: [],
  };

  // ===========================================================================
  // Init / bindings
  // ===========================================================================
  function init() {
    if (state.bound) return;
    if (!$("scTableBody")) return; // tab markup not present (older HTML)
    state.bound = true;
    renderTable();
    bindRowControls();
    bindColumnControls();
    bindScenarioFormControls();
    bindProgressControls();
    renderProgress();
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
    $("scValidateBtn").addEventListener("click", () => validateNow());
    $("scPreviewBtn").addEventListener("click", () => previewNow());
    ["scCampaignName", "scMethod", "scNVariants", "scSeed"].forEach((id) => {
      const el = $(id);
      if (!el) return;
      el.addEventListener("change", onCampaignFieldChange);
      el.addEventListener("input", onCampaignFieldChange);
    });
  }

  function onCampaignFieldChange() {
    updateCampaignSummary();
    scheduleValidate();
  }

  function bindColumnControls() {
    const addBtn = $("scAddColumnBtn");
    const menu = $("scAddColumnMenu");
    if (!addBtn || !menu) return;
    addBtn.addEventListener("click", (e) => {
      e.stopPropagation();
      const hidden = COLUMNS.filter((c) => !state.visibleColumns.has(c.id));
      if (!hidden.length) {
        menu.innerHTML = '<div class="sc-col-menu-empty">All columns visible.</div>';
      } else {
        menu.innerHTML = "";
        hidden.forEach((c) => {
          const b = document.createElement("button");
          b.type = "button";
          b.textContent = c.label;
          b.addEventListener("click", () => {
            state.visibleColumns.add(c.id);
            menu.classList.add("hidden");
            renderTable();
          });
          menu.appendChild(b);
        });
      }
      menu.classList.toggle("hidden");
    });
    document.addEventListener("click", (e) => {
      if (!menu.classList.contains("hidden") && !menu.contains(e.target) && e.target !== addBtn) {
        menu.classList.add("hidden");
      }
    });
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
      if (!state.visibleColumns.has(col.id)) return;
      const th = document.createElement("th");
      const wrap = document.createElement("span");
      wrap.className = "sc-col-head";
      const label = document.createElement("span");
      label.textContent = col.label;
      wrap.appendChild(label);
      if (!col.essential) {
        const hide = document.createElement("button");
        hide.type = "button";
        hide.className = "sc-col-hide";
        hide.textContent = "\u2212"; // minus sign
        hide.title = "Hide " + col.label + " column";
        hide.addEventListener("click", (e) => {
          e.stopPropagation();
          state.visibleColumns.delete(col.id);
          renderTable();
        });
        wrap.appendChild(hide);
      }
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
        if (!state.visibleColumns.has(col.id)) return;
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
    if (wb) wb.addEventListener("change", () => { if (state.customWorkbookPath) clearCustomInput(); else updateScenarioSummary(); });

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
    if ($("scRepresentativeDays")) { $("scRepresentativeDays").value = d.representativeDays; }
    if ($("scRepresentativeDaysNumber")) { $("scRepresentativeDaysNumber").value = d.representativeDays; }
    const cores = String(Math.max(4, navigator.hardwareConcurrency || 64));
    if ($("scThreads")) $("scThreads").max = cores;
    if ($("scThreadsNumber")) $("scThreadsNumber").max = cores;
    if ($("scWorkers")) $("scWorkers").max = cores;
    if ($("scWorkersNumber")) $("scWorkersNumber").max = cores;
    // Sensible defaults so the user immediately sees a real Threads-per-worker
    // number instead of "auto": total cores = detected, workers = half.
    const detected = Number(navigator.hardwareConcurrency) || 0;
    const defaultCores   = Math.max(1, Math.min(detected || 4, Number(cores)));
    const defaultWorkers = Math.max(1, Math.min(detected ? Math.floor(detected / 2) : 4, Number(cores)));
    if ($("scThreads") && !$("scThreads").dataset.touched) $("scThreads").value = defaultCores;
    if ($("scThreadsNumber") && !$("scThreadsNumber").dataset.touched) $("scThreadsNumber").value = defaultCores;
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
  //   - Total CPU cores (scThreads): cap on cores allocated to the campaign.
  //     0 means "let the solver pick".
  //   - Parallel workers (scWorkers): how many variants run in parallel.
  //   - Threads per worker = floor(totalCores / workers), with a floor of 1.
  //
  // When totalCores is 0 (auto), we report "auto" instead of dividing by the
  // detected hardware concurrency since the actual core count the solver
  // claims at runtime is decided by HiGHS/Gurobi internally.
  // ---------------------------------------------------------------------------
  function updateThreadsPerWorker() {
    const out = $("scThreadsPerWorker");
    if (!out) return;
    const totalCores = Number(($("scThreads") || {}).value || 0);
    const workers = Math.max(1, Number(($("scWorkers") || {}).value || 1));
    if (totalCores <= 0) {
      out.innerHTML = `<strong>auto</strong> <span class="subtle">(solver picks; \u00f7 ${workers} workers)</span>`;
      out.title = `Total CPU cores = 0 -> solver decides per worker.`;
      return;
    }
    // floor(total / workers) is the threads-per-worker we send to the solver.
    const perWorker = Math.max(1, Math.floor(totalCores / workers));
    const allocated = perWorker * workers;
    const slack = totalCores - allocated;
    out.innerHTML = `<strong>${perWorker}</strong> <span class="subtle">= floor(${totalCores} \u00f7 ${workers})${slack > 0 ? `, ${slack} core(s) unused` : ""}</span>`;
    out.title = `threads_per_worker = floor(total_cores / workers) = floor(${totalCores} / ${workers}) = ${perWorker}`;
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
    const variants = ($("scNVariants") || {}).value || "—";
    if ($("scSelectedCampaignLabel")) $("scSelectedCampaignLabel").textContent = name;
    const methodLabels = { lhs: "Latin hypercube", morris: "Morris", sobol: "Sobol", factorial: "Factorial" };
    if ($("scSelectedMethod")) $("scSelectedMethod").textContent = methodLabels[method] || method;
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
      method: $("scMethod").value,
      n_variants: Number($("scNVariants").value) || 0,
      seed: Number($("scSeed").value) || 0,
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
    // Switch the user to the Progress sub-tab so they can watch it run.
    activateProgressTab();
    startPolling(payload.campaign_id);
  }

  function buildRunBody() {
    const spec = collectSpec();
    // Prefer a user-browsed file over the dropdown selection.
    spec.inputWorkbook = state.customWorkbookPath
      || (($("scInputWorkbook") || {}).value)
      || "data/default_data.xlsx";
    spec.n_workers = Number(($("scWorkers") || {}).value) || 1;
    spec.threads_per_worker = computeThreadsPerWorker();
    spec.solver = ($("scSolver") || {}).value || "highs";
    spec.mode = computeMode();
    spec.periods = collectPeriods();
    return spec;
  }

  function computeThreadsPerWorker() {
    const totalCores = Number(($("scThreads") || {}).value) || 0;
    const workers = Math.max(1, Number(($("scWorkers") || {}).value) || 1);
    return totalCores > 0 ? Math.max(1, Math.floor(totalCores / workers)) : 1;
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
      error: snap.error || null,
    };
    progressState.workers = (snap.workers || []).map((w) => ({
      id: w.id,
      status: w.status,
      variant_id: w.variant_id,
      assigned: w.assigned || 0,
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
      : Math.min(8, Math.max(2, Math.floor((navigator.hardwareConcurrency || 4) / 2)));
    const total = Math.max(nWorkers, Number(($("scNVariants") || {}).value) || 60);
    const variantsPerWorker = Math.ceil(total / nWorkers);
    progressState.active = true;
    progressState.startedAt = Date.now();
    progressState.campaign = { name: ($("scCampaignName") || {}).value || "demo_campaign", total, started_at: progressState.startedAt };
    progressState.workers = [];
    progressState.failures = [];
    for (let i = 1; i <= nWorkers; i++) {
      progressState.workers.push({
        id: i,
        status: "running",
        variant_id: i,
        completed: 0,
        failed: 0,
        assigned: variantsPerWorker,
        progress: 0,
        started_at: progressState.startedAt,
        last_change: progressState.startedAt,
        next_finish_in: 800 + Math.random() * 2400, // ms
        pid: 1000 + i,
        rss_bytes: (350 + Math.random() * 200) * 1024 * 1024, // 350-550 MB fake
      });
    }
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
      clearInterval(progressState.demoTimer);
      progressState.demoTimer = null;
      if ($("campaignDemoStart")) $("campaignDemoStart").classList.remove("hidden");
      if ($("campaignDemoStop")) $("campaignDemoStop").classList.add("hidden");
    }
    renderProgress();
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
      const finished = done + failed;
      if (progressState.active && finished > 0 && total > 0) {
        const perVariant = elapsedMs / finished;
        const remaining = (total - finished) * perVariant / Math.max(1, running);
        etaEl.textContent = "ETA: " + fmtDuration(remaining / 1000);
      } else if (!progressState.active && total === 0) {
        etaEl.textContent = "ETA: \u2014";
      } else {
        etaEl.textContent = "ETA: estimating\u2026";
      }
    }

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
    const fill = document.createElement("div");
    fill.className = "worker-progress-bar";
    const pct = w.status === "done" ? 100
              : w.status === "failed" ? 100
              : w.status === "running" ? (w.progress || 0)
              : 0;
    fill.style.width = pct + "%";
    bar.appendChild(fill);
    card.appendChild(bar);

    const meta = document.createElement("div");
    meta.className = "worker-meta";
    const left = document.createElement("span");
    const total = w.assigned || 0;
    const finished = (w.completed || 0) + (w.failed || 0);
    left.textContent = `${finished}/${total} done${w.failed ? ` (${w.failed} failed)` : ""}`;
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

