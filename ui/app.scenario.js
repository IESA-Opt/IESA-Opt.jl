// =============================================================================
// app.scenario.js -- Scenario Space tab (Phase 1: spec table + preview)
//
// Owns the parameter-space table, sampling-config form, and the preview pane
// on tab-scenario. Talks to two server endpoints:
//   * POST /api/scenario/validate -> errors/warnings + impliedSampleSize
//   * POST /api/scenario/preview  -> first N rows of the sampled matrix
//
// The campaign runner (start, progress, results) is added in later phases.
// =============================================================================
(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);

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
    selected: new Set(),  // selected row indices
    bound: false,
  };

  function init() {
    if (state.bound) return;
    if (!$("scTableBody")) return; // tab markup not present (older HTML)
    state.bound = true;
    renderTable();
    bindControls();
    // Kick off an implicit validate so the implied count appears right away.
    validateNow().catch(() => {});
  }

  function bindControls() {
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
      if (el) el.addEventListener("change", scheduleValidate);
      if (el) el.addEventListener("input", scheduleValidate);
    });
  }

  function renderTable() {
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

      // Editable text columns
      ["parameter", "subparameter", "sheet", "cell"].forEach((field) => {
        const td = document.createElement("td");
        td.appendChild(makeInput(row, field, "text"));
        tr.appendChild(td);
      });

      // Type dropdown
      const tdType = document.createElement("td");
      const sel = document.createElement("select");
      ["set", "multiply"].forEach((opt) => {
        const o = document.createElement("option");
        o.value = opt;
        o.textContent = opt;
        if (row.type === opt) o.selected = true;
        sel.appendChild(o);
      });
      sel.addEventListener("change", () => {
        row.type = sel.value;
        scheduleValidate();
      });
      tdType.appendChild(sel);
      tr.appendChild(tdType);

      // Numeric columns
      ["min", "max", "step"].forEach((field) => {
        const td = document.createElement("td");
        td.appendChild(makeInput(row, field, "number"));
        tr.appendChild(td);
      });

      // Notes
      const tdN = document.createElement("td");
      tdN.appendChild(makeInput(row, "notes", "text"));
      tr.appendChild(tdN);

      tbody.appendChild(tr);
    });
  }

  function makeInput(row, field, kind) {
    const inp = document.createElement("input");
    inp.type = kind;
    if (kind === "number") inp.step = "any";
    inp.value = row[field] === undefined || row[field] === null ? "" : row[field];
    inp.addEventListener("change", () => {
      row[field] = kind === "number" ? (inp.value === "" ? "" : Number(inp.value)) : inp.value;
      scheduleValidate();
    });
    return inp;
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

  // --- server round-trips --------------------------------------------------

  let validateTimer = null;
  function scheduleValidate() {
    if (validateTimer) clearTimeout(validateTimer);
    validateTimer = setTimeout(() => { validateTimer = null; validateNow().catch(() => {}); }, 300);
  }

  async function validateNow() {
    const body = collectSpec();
    setStatus("Validating…", "");
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
    $("scPreviewStatus").textContent = "Sampling…";
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
      : "—";
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

  // --- bootstrap ----------------------------------------------------------
  // We attach init() to the same lifecycle that app.js uses: run on
  // DOMContentLoaded, but be defensive in case app.scenario.js loads after
  // the document is already complete (e.g. cached reload).
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
