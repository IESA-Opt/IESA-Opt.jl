(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const state = { sessionId: null, session: null, lastSummary: null, lastError: null };

  function escapeHtml(value) {
    return String(value == null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  function show(id) { const el = $(id); if (el) el.classList.remove("hidden"); }
  function hide(id) { const el = $(id); if (el) el.classList.add("hidden"); }

  // ---------------------------------------------------------------------
  // Session lifecycle
  // ---------------------------------------------------------------------
  async function createSession() {
    const r = await fetch("/api/merge/session", { method: "POST" });
    const payload = await r.json();
    state.sessionId = payload.session.id;
    state.session = payload.session;
    state.lastSummary = null;
    state.lastError = null;
  }

  async function refreshSession() {
    if (!state.sessionId) return;
    const r = await fetch(`/api/merge/session/${encodeURIComponent(state.sessionId)}`);
    const payload = await r.json();
    if (payload && payload.session) state.session = payload.session;
    render();
  }

  async function startOver() {
    resetFormFields();
    try { await createSession(); } catch (err) { console.error("merge: startOver failed", err); }
    render();
  }

  function resetFormFields() {
    ["mergeFile1Display", "mergeFile2Display"].forEach(hide);
    ["mergeFile1Path", "mergeFile2Path"].forEach((id) => { const el = $(id); if (el) el.textContent = ""; });
    ["mergeFile1Report", "mergeFile2Report"].forEach((id) => { const el = $(id); if (el) el.innerHTML = ""; });
    const opt = $("mergePriorityOpt"); if (opt) opt.checked = false;
    const sim = $("mergePrioritySim"); if (sim) sim.checked = false;
    const outputPath = $("mergeOutputPath"); if (outputPath) outputPath.value = "";
    const saveStatus = $("mergeSaveStatus"); if (saveStatus) saveStatus.textContent = "";
  }

  // ---------------------------------------------------------------------
  // Job polling (generic /api/jobs/{id}, shared with every run type)
  // ---------------------------------------------------------------------
  function pollJob(jobId, { onDone, onError } = {}) {
    const timer = setInterval(async () => {
      try {
        const r = await fetch("/api/jobs/" + encodeURIComponent(jobId));
        const snap = await r.json();
        if (!r.ok) { clearInterval(timer); if (onError) onError(snap); return; }
        if (snap.status === "done") { clearInterval(timer); if (onDone) onDone(snap); }
        else if (snap.status === "error") { clearInterval(timer); if (onError) onError(snap); }
      } catch (err) {
        clearInterval(timer);
        if (onError) onError({ logs: [{ message: String((err && err.message) || err) }] });
      }
    }, 1000);
    return timer;
  }

  function lastJobMessage(snap, fallback) {
    if (snap && Array.isArray(snap.logs) && snap.logs.length) {
      return snap.logs[snap.logs.length - 1].message || fallback;
    }
    return fallback;
  }

  // ---------------------------------------------------------------------
  // Step 1/2: file loading
  // ---------------------------------------------------------------------
  async function browseFile(slot) {
    const btnId = slot === 1 ? "mergeBrowseFile1" : "mergeBrowseFile2";
    const btn = $(btnId);
    const original = btn.textContent;
    btn.disabled = true; btn.textContent = "Opening…";
    try {
      const r = await fetch("/api/merge/browseFile", { method: "POST" });
      const payload = await r.json();
      const picked = payload && payload.path ? String(payload.path).trim() : "";
      if (picked) await loadFile(slot, picked);
    } catch (err) {
      console.error("merge: browseFile failed", err);
    } finally {
      btn.disabled = false; btn.textContent = original;
    }
  }

  async function loadFile(slot, path) {
    const displayId = slot === 1 ? "mergeFile1Path" : "mergeFile2Path";
    const wrapId = slot === 1 ? "mergeFile1Display" : "mergeFile2Display";
    const reportId = slot === 1 ? "mergeFile1Report" : "mergeFile2Report";
    $(displayId).textContent = path;
    show(wrapId);
    $(reportId).innerHTML = '<p class="subtle">Checking compatibility…</p>';
    try {
      const r = await fetch(`/api/merge/session/${encodeURIComponent(state.sessionId)}/loadFile`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ slot, path }),
      });
      const payload = await r.json();
      if (!r.ok || !payload.jobId) throw new Error(payload.error || "loadFile failed");
      pollJob(payload.jobId, {
        onDone: async () => { await refreshSession(); },
        onError: (snap) => {
          $(reportId).innerHTML = `<p class="merge-report-note">${escapeHtml(lastJobMessage(snap, "Compatibility check failed"))}</p>`;
        },
      });
    } catch (err) {
      $(reportId).innerHTML = `<p class="merge-report-note">${escapeHtml((err && err.message) || String(err))}</p>`;
    }
  }

  function renderCompatPill(label, ok) {
    return `<span class="status-pill ${ok ? "ready" : "failed"}">${escapeHtml(label)}: ${ok ? "Compatible" : "Not compatible"}</span>`;
  }

  function missingList(items) {
    if (!items || !items.length) return "";
    const shown = items.slice(0, 20).map((m) => `<li>${escapeHtml(m)}</li>`).join("");
    const more = items.length > 20 ? `<li>&hellip; and ${items.length - 20} more</li>` : "";
    return `<ul class="merge-report-missing">${shown}${more}</ul>`;
  }

  function renderReport(containerId, report) {
    const el = $(containerId);
    if (!el) return;
    if (!report) { el.innerHTML = ""; return; }
    const opt = report.iesaOpt || {};
    const sim = report.iesaSim || {};
    const simNote = (report.kind === "excel" && sim.compatible && sim.mergeCapable === false)
      ? '<p class="merge-report-note">This workbook has the shape IESA-Sim expects, but there is no Julia parser for IESA-Sim Excel files yet, so it cannot fill an IESA-Sim gap here. Use an IESA-Sim DuckDB file instead.</p>'
      : "";
    el.innerHTML = `
      <div class="merge-report-model">
        <div class="merge-report-model-title"><span>IESA-Opt</span>${renderCompatPill("IESA-Opt", opt.compatible)}</div>
        ${missingList(opt.missing)}
      </div>
      <div class="merge-report-model">
        <div class="merge-report-model-title"><span>IESA-Sim</span>${renderCompatPill("IESA-Sim", sim.compatible)}</div>
        ${missingList(sim.missing)}
        ${simNote}
      </div>
    `;
  }

  // ---------------------------------------------------------------------
  // Step 3: priority
  // ---------------------------------------------------------------------
  async function setPriority(choice) {
    try {
      const r = await fetch(`/api/merge/session/${encodeURIComponent(state.sessionId)}/priority`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ priority: choice }),
      });
      const payload = await r.json();
      if (!r.ok) throw new Error(payload.error || "priority failed");
      state.session = payload.session;
      render();
    } catch (err) {
      console.error("merge: setPriority failed", err);
    }
  }

  // ---------------------------------------------------------------------
  // Step 4: save
  // ---------------------------------------------------------------------
  async function saveMerge() {
    const outputPath = (($("mergeOutputPath") || {}).value || "").trim();
    const btn = $("mergeSaveButton");
    btn.disabled = true; btn.textContent = "Merging…";
    $("mergeSaveStatus").textContent = "Starting merge…";
    try {
      const r = await fetch(`/api/merge/session/${encodeURIComponent(state.sessionId)}/save`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ outputPath }),
      });
      const payload = await r.json();
      if (!r.ok || !payload.jobId) throw new Error(payload.error || "save failed");
      await refreshSession();
      pollJob(payload.jobId, {
        onDone: async (snap) => {
          state.lastSummary = snap.summary || null;
          await refreshSession();
        },
        onError: async (snap) => {
          state.lastError = lastJobMessage(snap, "Merge failed");
          await refreshSession();
        },
      });
    } catch (err) {
      state.lastError = (err && err.message) || String(err);
      await refreshSession();
    }
  }

  function renderSummaryTable(summary) {
    const el = $("mergeSummaryTable");
    if (!el) return;
    const tables = (summary && summary.tables) || {};
    const names = Object.keys(tables).sort();
    if (!names.length) { el.innerHTML = '<div class="empty-state">No tables in merged output.</div>'; return; }
    const rows = names.map((name) => {
      const t = tables[name] || {};
      return `<tr><td>${escapeHtml(name)}</td><td>${escapeHtml(String(t.rows != null ? t.rows : "-"))}</td><td>${escapeHtml(t.origin || "-")}</td></tr>`;
    }).join("");
    el.innerHTML = `<table><thead><tr><th>Table</th><th>Rows</th><th>Origin</th></tr></thead><tbody>${rows}</tbody></table>`;
  }

  // ---------------------------------------------------------------------
  // Step bar + panel visibility
  // ---------------------------------------------------------------------
  function updateSteps(session) {
    const map = { mergeStepFile1: "pending", mergeStepFile2: "pending", mergeStepPriority: "pending", mergeStepSave: "pending" };
    const status = session.status;
    const hasGap = !!session.gapModel;

    if (status === "awaiting_file1") {
      map.mergeStepFile1 = "active";
    } else if (status === "error_incompatible") {
      map.mergeStepFile1 = "failed";
    } else {
      map.mergeStepFile1 = "done";
      if (hasGap) {
        if (status === "awaiting_file2") map.mergeStepFile2 = "active";
        else if (status === "error_file2_insufficient") map.mergeStepFile2 = "failed";
        else map.mergeStepFile2 = "done";
      } else {
        map.mergeStepFile2 = "done";
      }
      if (hasGap && status === "awaiting_priority") map.mergeStepPriority = "active";
      else if (["awaiting_save", "merging", "complete", "error_merge_failed"].includes(status)) map.mergeStepPriority = "done";

      if (status === "awaiting_save") map.mergeStepSave = "active";
      else if (status === "merging") map.mergeStepSave = "active";
      else if (status === "complete") map.mergeStepSave = "done";
      else if (status === "error_merge_failed") map.mergeStepSave = "failed";
    }

    Object.entries(map).forEach(([id, cls]) => {
      const el = $(id);
      if (!el) return;
      el.classList.remove("done", "active", "failed");
      if (cls !== "pending") el.classList.add(cls);
    });
  }

  function render() {
    const session = state.session;
    if (!session) return;
    updateSteps(session);
    const status = session.status;

    show("mergeFile1Panel");
    renderReport("mergeFile1Report", session.file1.report);
    if (session.file1.path) {
      $("mergeFile1Path").textContent = session.file1.path;
      show("mergeFile1Display");
    }

    hide("mergeFile2Panel"); hide("mergePriorityPanel"); hide("mergeSavePanel");
    hide("mergeSummaryPanel"); hide("mergeErrorPanel");

    if (status === "awaiting_file1") {
      $("mergeStepSummary").textContent = "Load a file to check IESA-Opt / IESA-Sim compatibility.";
      return;
    }

    if (status === "error_incompatible") {
      show("mergeErrorPanel");
      $("mergeErrorMessage").textContent = "This file is not compatible with IESA-Opt or IESA-Sim. Start a new merge with a different file.";
      $("mergeStepSummary").textContent = "Incompatible file.";
      return;
    }

    if (session.gapModel) {
      show("mergeFile2Panel");
      const gapLabel = session.gapModel === "iesaOpt" ? "IESA-Opt" : "IESA-Sim";
      const haveLabel = session.gapModel === "iesaOpt" ? "IESA-Sim" : "IESA-Opt";
      $("mergeFile2Hint").textContent = `The first file only covers ${haveLabel}. Load a second file that covers ${gapLabel} to continue.`;
      renderReport("mergeFile2Report", session.file2.report);
      if (session.file2.path) {
        $("mergeFile2Path").textContent = session.file2.path;
        show("mergeFile2Display");
      }
    }

    if (status === "awaiting_file2") {
      $("mergeStepSummary").textContent = "Load a second file to cover the gap.";
      return;
    }

    if (status === "error_file2_insufficient") {
      show("mergeErrorPanel");
      $("mergeErrorMessage").textContent = "The second file still does not cover the missing model. Start a new merge with a different file.";
      $("mergeStepSummary").textContent = "Second file insufficient.";
      return;
    }

    if (status === "awaiting_priority") {
      show("mergePriorityPanel");
      $("mergeStepSummary").textContent = "Choose which model wins on overlapping data.";
      return;
    }

    if (status === "error_merge_failed") {
      show("mergeErrorPanel");
      $("mergeErrorMessage").textContent = state.lastError || "The merge failed. Start a new merge to try again.";
      $("mergeStepSummary").textContent = "Merge failed.";
      return;
    }

    if (status === "awaiting_save" || status === "merging") {
      show("mergeSavePanel");
      const btn = $("mergeSaveButton");
      if (status === "merging") {
        btn.disabled = true; btn.textContent = "Merging…";
        $("mergeSaveStatus").textContent = "Merging tables…";
      } else {
        btn.disabled = false; btn.textContent = "Merge & Save";
        $("mergeSaveStatus").textContent = "";
      }
      $("mergeStepSummary").textContent = status === "merging" ? "Merging…" : "Ready to merge and save.";
      return;
    }

    if (status === "complete") {
      show("mergeSummaryPanel");
      $("mergeSummaryPath").textContent = `Saved to ${session.outputPath}`;
      $("mergeStepSummary").textContent = "Merge complete.";
      renderSummaryTable(state.lastSummary);
      return;
    }
  }

  // ---------------------------------------------------------------------
  // Wiring
  // ---------------------------------------------------------------------
  function bind() {
    $("mergeBrowseFile1").addEventListener("click", () => browseFile(1));
    $("mergeBrowseFile2").addEventListener("click", () => browseFile(2));
    $("mergeSaveButton").addEventListener("click", saveMerge);
    $("mergeStartOverButton").addEventListener("click", startOver);
    $("mergeErrorStartOverButton").addEventListener("click", startOver);
    document.querySelectorAll('input[name="mergePriority"]').forEach((el) => {
      el.addEventListener("change", () => { if (el.checked) setPriority(el.value); });
    });
  }

  async function init() {
    bind();
    try {
      await createSession();
      render();
    } catch (err) {
      console.error("merge wizard: init failed", err);
    }
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
