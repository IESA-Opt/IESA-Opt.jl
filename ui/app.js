const state = { options: null, solvers: [], outputs: [], selectedOutputId: "", comparedOutputIds: [], currentJobId: null, pollTimer: null, resultsLoaded: false, statusTimer: null, statusPollIntervalMs: 1500, lastJobStatus: null, connectionLost: false, connRestoreTimer: null, connRestoreHide: null, latestResults: null, dispatchLegendOff: new Set(), customWorkbookPath: "", lastClickedOutputId: "", dispatchPayload: null, dispatchSelectedNode: "", dispatchSelectedPeriod: 0, dispatchFromHour: 1, dispatchToHour: 8760, dispatchLoading: false };
const DAYS_PER_YEAR = 365;
const stages = [["reading","Read"],["preparing","Prepare"],["clustering","Cluster"],["generation","Generate"],["solve","Solve"],["writing","Write"]];
const stageDescriptions = { idle:"Start a run to see each stage and solver output.", reading:"Julia is opening the workbook and loading the input tables into model data.", preparing:"Sets and derived parameters are being built for the selected solve years.", clustering:"Representative days and time-slice profiles are being prepared, unless full-hourly mode skipped this step.", generation:"JuMP variables, objective terms, and constraints are being generated before the solver starts.", solve:"The optimizer is running. Native solver messages and iteration lines appear in the log below when the solver writes them.", writing:"Solved values are being converted into DuckDB result tables, one output file at a time.", done:"The run finished and result tables are ready in the Results tab.", failed:"The run stopped during the last active stage. The log below contains the error details.", cancelled:"The run was stopped by the user. No results were saved." };
const chartColors = ["#1d5f8f", "#5a9f3f", "#00a3c7", "#b77800", "#8c5a9f", "#ba3a2f"];
const timingPhases = [
  { label:"Data read", keys:["dataRead_sec", "data_read_sec", "read_sec"], color:"#1d5f8f" },
  { label:"Prepare", keys:["derive_sec", "prepare_sec"], color:"#00a3c7" },
  { label:"Cluster", keys:["cluster_sec", "clustering_sec"], color:"#5a9f3f" },
  { label:"Generate", keys:["generation_sec", "generate_sec"], color:"#b77800" },
  { label:"Solve", keys:["solve_sec", "solveSeconds"], color:"#ba3a2f" },
  { label:"Write", keys:["resultsWrite_sec", "results_write_sec", "write_sec", "writing_sec"], color:"#4a7c7a" },
];
const $ = id => document.getElementById(id);

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
else init();

async function init() {
  // Each setup step is isolated so one synchronous throw cannot starve the others.
  // Most importantly, loadOutputs() must always run so the Results sidebar stops
  // showing "Loading outputs." even if a downstream binding fails.
  safeRun("bindTabs", bindTabs);
  safeRun("bindControls", bindControls);
  safeRun("renderJob(null)", () => renderJob(null));
  safeRun("startStatusPolling", startStatusPolling);
  // Fire the outputs request immediately and in parallel with options/solvers so the
  // sidebar populates even if /api/options or /api/solvers stalls.
  const outputsPromise = loadOutputs();
  try {
    const [options, solverPayload] = await Promise.all([fetchJson("/api/options"), fetchJson("/api/solvers")]);
    state.options = options; state.solvers = solverPayload.solvers || [];
    safeRun("populateOptions", populateOptions);
    safeRun("populateSolvers", populateSolvers);
    safeRun("updateRunSummary", updateRunSummary);
    $("connectionStatus").textContent = "Local UI connected";
  } catch (error) {
    console.error("init: failed to load options/solvers", error);
    $("connectionStatus").textContent = "Could not load local UI options";
  }
  try { await outputsPromise; } catch (error) { console.error("init: loadOutputs failed", error); }
}

function safeRun(label, fn) {
  try { fn(); }
  catch (error) {
    console.error(`init: ${label} threw`, error);
    const status = document.getElementById("connectionStatus");
    if (status) status.textContent = `UI init error in ${label}: ${error.message || error}`;
  }
}

function startStatusPolling() {
  if (state.statusTimer) { clearInterval(state.statusTimer); state.statusTimer = null; }
  pollJuliaStatus();
  state.statusTimer = setInterval(pollJuliaStatus, 1500);
}

async function pollJuliaStatus() {
  try {
    const status = await fetchJson("/api/status");
    setConnectionState(true);
    renderJuliaStatus(status);
    if ((status.state === "ready" || status.state === "failed" || status.state === "missing")
        && state.statusTimer && state.statusPollIntervalMs !== 3000) {
      // Warm-up is done: slow the heartbeat but keep it running so we still detect server drops.
      clearInterval(state.statusTimer);
      state.statusPollIntervalMs = 3000;
      state.statusTimer = setInterval(pollJuliaStatus, 3000);
    }
  } catch (e) {
    setConnectionState(false);
  }
}

function setConnectionState(ok) {
  const banner = $("connectionBanner");
  if (!banner) return;
  const textEl = banner.querySelector(".conn-banner-text");
  if (!ok) {
    if (state.connRestoreTimer) { clearTimeout(state.connRestoreTimer); state.connRestoreTimer = null; }
    if (state.connRestoreHide) { clearTimeout(state.connRestoreHide); state.connRestoreHide = null; }
    banner.classList.remove("restored", "fading");
    banner.classList.add("show");
    banner.setAttribute("aria-hidden", "false");
    if (textEl) textEl.innerHTML = "Connection lost &mdash; retrying&hellip;";
    state.connectionLost = true;
    return;
  }
  if (state.connectionLost) {
    state.connectionLost = false;
    banner.classList.add("restored");
    banner.classList.remove("fading");
    if (textEl) textEl.textContent = "Connection restored";
    // Trigger fade on the next frame so the opacity transition runs.
    state.connRestoreTimer = setTimeout(() => {
      banner.classList.add("fading");
      state.connRestoreHide = setTimeout(() => {
        banner.classList.remove("show", "restored", "fading");
        banner.setAttribute("aria-hidden", "true");
        state.connRestoreHide = null;
      }, 550);
      state.connRestoreTimer = null;
    }, 30);
  }
}

function renderJuliaStatus(status) {
  const el = $("juliaStatus");
  if (!el) return;
  el.classList.remove("warming", "ready", "failed", "muted");
  let label = "Julia: idle";
  if (!status || !status.state || status.state === "idle") { el.classList.add("muted"); label = "Julia: idle"; }
  else if (status.state === "warming") { el.classList.add("warming"); label = "Julia warming up\u2026"; }
  else if (status.state === "ready") { el.classList.add("ready"); label = status.elapsedSec ? `Julia ready (warm-up ${fmt(status.elapsedSec)} s)` : "Julia ready"; }
  else if (status.state === "failed") { el.classList.add("failed"); label = "Julia warm-up failed"; }
  else if (status.state === "missing") { el.classList.add("failed"); label = "Workbook not found"; }
  else { el.classList.add("muted"); label = `Julia: ${status.state}`; }
  el.innerHTML = `<span class="status-dot"></span><span class="status-label">${escapeHtml(label)}</span>`;
  el.title = status && status.message ? status.message : "";
}

async function fetchJson(url, options) { const r = await fetch(url, options); const p = await r.json(); if (!r.ok) throw new Error(p.error || r.statusText); return p; }
function bindTabs() { document.querySelectorAll(".tab-button").forEach(b => b.addEventListener("click", () => switchTab(b.dataset.tab))); }
function switchTab(tab) { document.querySelectorAll(".tab-button").forEach(b => b.classList.toggle("active", b.dataset.tab === tab)); document.querySelectorAll(".tab-panel").forEach(p => p.classList.toggle("active", p.id === `tab-${tab}`)); }

function bindControls() {
  $("runForm").addEventListener("submit", onRunButtonClick);
  $("stopRunButtonProgress").addEventListener("click", cancelCurrentJob);
  $("viewResultsButton").addEventListener("click", () => switchTab("results"));
  $("refreshOutputsButton").addEventListener("click", loadOutputs);
  $("compareOutputsButton").addEventListener("click", compareSelectedOutputs);
  $("deleteOutputsButton").addEventListener("click", deleteSelectedOutputs);
  $("browseInputButton").addEventListener("click", browseInputFile);
  $("clearCustomInputButton").addEventListener("click", clearCustomInput);
  $("inputWorkbook").addEventListener("change", () => { if (state.customWorkbookPath) clearCustomInput(); else updateRunSummary(); });
  $("outputMode").addEventListener("change", e => $("outputNameWrap").classList.toggle("hidden", e.target.value !== "custom"));
  $("timeSlicingToggle").addEventListener("change", () => { updateTimeSlicingControls(); updateTotalSlices(); });
  syncRange("representativeDays", "representativeDaysNumber", updateTotalSlices); syncRange("threads", "threadsNumber");
  $("solver").addEventListener("change", updateSolverDetails);
  const dispatchPeriod = $("hourlyDispatchPeriod"); if (dispatchPeriod) dispatchPeriod.addEventListener("change", () => { state.dispatchSelectedPeriod = Number(dispatchPeriod.value) || 0; refreshHourlyDispatch(); });
  const dispatchNode = $("hourlyDispatchNode"); if (dispatchNode) dispatchNode.addEventListener("change", () => { state.dispatchSelectedNode = dispatchNode.value || ""; refreshHourlyDispatch(); });
  const dispatchFrom = $("hourlyDispatchFrom"); if (dispatchFrom) dispatchFrom.addEventListener("change", () => { state.dispatchFromHour = clampHour(dispatchFrom.value, 1, state.dispatchToHour); dispatchFrom.value = state.dispatchFromHour; renderHourlyDispatch(state.dispatchPayload); });
  const dispatchTo = $("hourlyDispatchTo"); if (dispatchTo) dispatchTo.addEventListener("change", () => { state.dispatchToHour = clampHour(dispatchTo.value, state.dispatchFromHour, 8760); dispatchTo.value = state.dispatchToHour; renderHourlyDispatch(state.dispatchPayload); });
  const dispatchReset = $("hourlyDispatchReset"); if (dispatchReset) dispatchReset.addEventListener("click", () => { state.dispatchFromHour = 1; state.dispatchToHour = 8760; const f=$("hourlyDispatchFrom"); if (f) f.value = 1; const t=$("hourlyDispatchTo"); if (t) t.value = 8760; renderHourlyDispatch(state.dispatchPayload); });
  const emGroup = $("emissionsGroupBy"); if (emGroup) emGroup.addEventListener("change", refreshEmissions);
  const emPeriod = $("emissionsPeriod"); if (emPeriod) emPeriod.addEventListener("change", refreshEmissions);
  const sdAct = $("supplyDemandActivity"); if (sdAct) sdAct.addEventListener("change", refreshSupplyDemand);
  const sdPeriod = $("supplyDemandPeriod"); if (sdPeriod) sdPeriod.addEventListener("change", refreshSupplyDemand);
  document.querySelectorAll(".toggle-table-button").forEach(btn => {
    btn.addEventListener("click", () => {
      const targetId = btn.dataset.target;
      const target = document.getElementById(targetId);
      if (!target) return;
      const isHidden = target.classList.toggle("hidden");
      btn.textContent = isHidden ? "Show table" : "Hide table";
    });
  });
}
function clampHour(value, lo, hi) { const v = Math.round(Number(value)); if (!Number.isFinite(v)) return lo; return Math.max(lo, Math.min(hi, v)); }
function syncRange(a, b, fn) { const r=$(a), n=$(b); const u=v=>{ r.value=v; n.value=v; if(fn) fn(); }; r.addEventListener("input",()=>u(r.value)); n.addEventListener("input",()=>u(n.value)); }

function populateOptions() {
  const o = state.options, d = o.defaults;
  fillSelect("inputWorkbook", o.scenarios || [], d.inputWorkbook); fillSelect("clusteringApproach", o.clusteringApproaches || [], d.clusteringApproach); fillSelect("constraintGroup", o.constraintGroups || [], d.constraintGroup);
  renderPeriods(o.periods || [], d.periods || []); renderHours(o.hoursPerDayOptions || [], d.hoursPerDay); renderSolveMethods(o.solveMethods || [], d.solveMethod);
  $("representativeDays").value = d.representativeDays; $("representativeDaysNumber").value = d.representativeDays;
  const cores = String(Math.max(4, navigator.hardwareConcurrency || 64)); $("threads").max = cores; $("threadsNumber").max = cores; updateTotalSlices();
  updateTimeSlicingControls();
}
function fillSelect(id, values, selected) { const s=$(id); s.innerHTML=""; const opts = values.includes(selected) ? values : [selected, ...values].filter(Boolean); opts.forEach(v=>{ const o=document.createElement("option"); o.value=v; o.textContent=v; o.selected=v===selected; s.appendChild(o); }); }
function populateSolvers() { const select=$("solver"); select.innerHTML=""; const defaultSolver = state.solvers.find(x => x.default && x.available) || state.solvers.find(x => x.id === state.options.defaults.solver && x.available) || state.solvers.find(x => x.available); state.solvers.forEach(solver=>{ const option=document.createElement("option"); option.value=solver.id; option.textContent=solver.available ? solverLabel(solver) : `${solver.label} unavailable`; option.disabled=!solver.available; option.selected=defaultSolver && solver.id===defaultSolver.id; select.appendChild(option); }); updateSolverDetails(); }
function solverLabel(solver) { return solver.version ? `${solver.label} (${solver.version})` : solver.label; }
function renderPeriods(periods, selected) { const w=$("periods"); w.innerHTML=""; periods.forEach(p=>{ const l=document.createElement("label"); l.innerHTML=`<input type="checkbox" value="${p}"><span>${p}</span>`; l.querySelector("input").checked=selected.includes(p); l.querySelector("input").addEventListener("change", updateRunSummary); w.appendChild(l); }); }
function renderHours(hours, selected) {
  const w = $("hoursPerDay"); w.innerHTML = "";
  hours.forEach(h => {
    const l = document.createElement("label");
    l.innerHTML = `<input type="radio" name="hoursPerDay" value="${h}"><span>${h}</span>`;
    const input = l.querySelector("input");
    input.checked = h === selected;
    input.addEventListener("change", updateTotalSlices);
    w.appendChild(l);
  });
}
function renderSolveMethods(methods, selected) { const w=$("solveMethod"); w.innerHTML=""; methods.forEach(m=>{ const l=document.createElement("label"); l.innerHTML=`<input type="radio" name="solveMethod" value="${m.id}"><span>${escapeHtml(m.label)}</span>`; l.querySelector("input").checked=m.id===selected; w.appendChild(l); }); }
function currentHoursPerDay() {
  const checked = document.querySelector("input[name='hoursPerDay']:checked");
  return checked ? Number(checked.value) : 24;
}
function updateTotalSlices() {
  const tsOn = $("timeSlicingToggle").checked;
  const total = tsOn
    ? Number($("representativeDays").value || 0) * 24
    : DAYS_PER_YEAR * currentHoursPerDay();
  $("totalSlices").value = String(total);
}
function updateTimeSlicingControls() {
  const tsOn = $("timeSlicingToggle").checked;
  // Time slicing OFF (full-hourly): only Hours-per-day matters; hide rep days, clustering and extreme days.
  // Time slicing ON: rep days + clustering + extreme days drive the slicing; hide hours-per-day.
  $("hoursPerDayField").classList.toggle("hidden", tsOn);
  $("representativeDaysField").classList.toggle("hidden", !tsOn);
  $("clusteringApproachField").classList.toggle("hidden", !tsOn);
  $("extremeDaysField").classList.toggle("hidden", !tsOn);
}
function updateSolverDetails() { const solver = state.solvers.find(x => x.id === $("solver").value); if(!solver) return; const detail = solver.message || ""; $("solverDetails").textContent = detail; $("solverDetails").classList.toggle("hidden", !detail); $("selectedSolverLabel").textContent = solver.label; $("selectedSolverVersion").textContent = solver.version || "Not reported"; setRunHint(`Ready to run with ${solverLabel(solver)}.`); }
function currentWorkbook() { return state.customWorkbookPath || $("inputWorkbook").value; }
function updateRunSummary() {
  const workbook = currentWorkbook();
  const periods = [...document.querySelectorAll("#periods input:checked")].map(i => i.value);
  $("scenarioSummary").textContent = `${workbook || "No workbook"} - ${periods.length ? periods.join(", ") : "no years"}`;
}
async function browseInputFile() {
  const btn = $("browseInputButton");
  const original = btn.textContent;
  btn.disabled = true; btn.textContent = "Opening\u2026";
  try {
    const response = await fetchJson("/api/browseInputFile", { method: "POST" });
    const picked = (response && response.path) ? String(response.path).trim() : "";
    if (picked) setCustomWorkbook(picked);
  } catch (error) {
    console.error("browseInputFile failed", error);
    setRunHint(`Browse failed: ${error.message || error}`, "error");
  } finally {
    btn.disabled = false; btn.textContent = original;
  }
}
function setCustomWorkbook(path) {
  state.customWorkbookPath = path;
  const display = $("customInputDisplay");
  const pathEl = $("customInputDisplayPath");
  if (pathEl) pathEl.textContent = path;
  if (display) display.classList.remove("hidden");
  $("clearCustomInputButton").classList.remove("hidden");
  updateRunSummary();
}
function clearCustomInput() {
  state.customWorkbookPath = "";
  const display = $("customInputDisplay");
  if (display) display.classList.add("hidden");
  const pathEl = $("customInputDisplayPath");
  if (pathEl) pathEl.textContent = "";
  $("clearCustomInputButton").classList.add("hidden");
  updateRunSummary();
}

async function onRunButtonClick(event) {
  event.preventDefault();
  if (isJobActive()) { await cancelCurrentJob(); return; }
  await startRun(event);
}

function isJobActive() {
  const s = state.lastJobStatus;
  return s === "queued" || s === "running";
}

async function cancelCurrentJob() {
  if (!state.currentJobId) return;
  const stopButtons = [$("runButton"), $("stopRunButtonProgress")].filter(Boolean);
  stopButtons.forEach(b => { b.disabled = true; });
  try {
    await fetchJson(`/api/jobs/${state.currentJobId}/cancel`, { method:"POST" });
    setRunHint("Stop requested. Waiting for the run to wind down.", "warning");
  } catch (error) { setRunHint(error.message, "error"); }
  finally { stopButtons.forEach(b => { b.disabled = false; }); }
}

async function startRun(event) {
  event.preventDefault(); state.lastJobStatus = "queued"; setRunButtonMode("stop"); $("stopRunButtonProgress").classList.remove("hidden"); $("runTitle").textContent="Run in progress"; setRunHint("Submitting model run."); $("viewResultsButton").classList.add("hidden"); state.resultsLoaded=false;
  try { const result = await fetchJson("/api/run", { method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify(collectRunConfig()) }); state.currentJobId=result.jobId; switchTab("progress"); renderJob(result.job); startPolling(); }
  catch (error) { setRunHint(error.message, "error"); resetRunButton(); $("runTitle").textContent="Ready to run"; }
}

function setRunButtonMode(mode) {
  const btn = $("runButton");
  if (!btn) return;
  if (mode === "stop") {
    btn.dataset.mode = "stop";
    btn.textContent = "Stop run";
    btn.classList.remove("primary-button");
    btn.classList.add("danger-button", "primary-stop");
    btn.disabled = false;
  } else {
    btn.dataset.mode = "run";
    btn.textContent = "Run model";
    btn.classList.add("primary-button");
    btn.classList.remove("danger-button", "primary-stop");
    btn.disabled = false;
  }
}

function resetRunButton() {
  setRunButtonMode("run");
  $("stopRunButtonProgress").classList.add("hidden");
}
function collectRunConfig() { return { inputWorkbook: currentWorkbook(), periods:[...document.querySelectorAll("#periods input:checked")].map(i=>Number(i.value)), mode:$("timeSlicingToggle").checked ? "timeslice" : "full_hourly", hoursPerDay:currentHoursPerDay(), representativeDays:Number($("representativeDays").value), solver:$("solver").value, solveMethod:document.querySelector("input[name='solveMethod']:checked").value, threads:Number($("threads").value), clusteringApproach:$("clusteringApproach").value, extremePeriods:$("extremePeriods").checked, extremeDays:Number($("extremeDays").value), boundaryRamping:$("boundaryRamping").checked, hourlyReports:$("hourlyReports").checked, saveCase:$("saveCase").checked, showViolations:$("showViolations").checked, outputMode:$("outputMode").value, outputName:$("outputName").value, constraintGroup:$("constraintGroup").value }; }
function startPolling() { if (state.pollTimer) clearInterval(state.pollTimer); state.pollTimer=setInterval(pollJob,800); pollJob(); }
async function pollJob() {
  if(!state.currentJobId) return;
  try {
    const job=await fetchJson(`/api/jobs/${state.currentJobId}`);
    state.lastJobStatus = job && job.status ? job.status : null;
    renderJob(job);
    if(job.status==="completed") {
      clearInterval(state.pollTimer);
      await loadResults(state.currentJobId);
      await loadOutputs();
      $("viewResultsButton").classList.remove("hidden");
      resetRunButton();
      $("runTitle").textContent="Run complete";
      setRunHint("Results tab is updated.", "success");
    } else if(job.status==="failed") {
      clearInterval(state.pollTimer);
      resetRunButton();
      $("runTitle").textContent="Run failed";
      setRunHint(job.error || "The run failed.", "error");
    } else if(job.status==="cancelled") {
      clearInterval(state.pollTimer);
      resetRunButton();
      $("runTitle").textContent="Run stopped";
      setRunHint("The run was stopped before results were saved.", "warning");
    }
  } catch(error) { $("jobStatus").textContent=error.message; }
}
function renderJob(job) {
  const status = job && job.status ? job.status : "Idle";
  $("jobStatus").textContent = status;
  $("jobStatus").classList.toggle("muted", !job || status === "queued");
  $("jobSubtitle").textContent = job && job.id ? `Job ${job.id}` : "No run has started.";
  $("jobExplanation").textContent = jobDescription(job);
  updateActivityLights(job);
  renderStages(job);
  const logs = job && job.logs ? job.logs : [];
  const logEl = $("runLog");
  if (!logs.length) {
    logEl.innerHTML = `<div class="log-info">Waiting for run output.</div>`;
  } else {
    logEl.innerHTML = logs.map(entry => {
      const cls = logLineClass(entry);
      const text = `[${entry.time}] ${entry.stage}: ${entry.message}`;
      return `<div class="${cls}">${escapeHtml(text)}</div>`;
    }).join("");
  }
  logEl.scrollTop = logEl.scrollHeight;
}
function logLineClass(entry) {
  const stage = (entry && entry.stage ? entry.stage : "").toLowerCase();
  const msg = entry && entry.message ? String(entry.message) : "";
  if (stage === "failed" || /\b(error|exception|traceback|infeasible|unbounded)\b/i.test(msg)) return "log-error";
  if (/\brun\s+complete\b/i.test(msg) || (stage === "done" && /\bcomplete\b/i.test(msg))) return "log-complete";
  if (/\b(warn(?:ing)?)\b/i.test(msg)) return "log-warning";
  if (/\boptimal\b/i.test(msg) || /\bobjective(?:\s*(?:value|=))/i.test(msg) || /\bsolve\s+complete\b/i.test(msg)) return "log-success";
  return "log-info";
}
function setRunHint(text, kind) {
  const el = $("runHint");
  if (!el) return;
  el.textContent = text || "";
  el.classList.remove("error-text", "warning-text", "success-text");
  if (kind === "error") el.classList.add("error-text");
  else if (kind === "warning") el.classList.add("warning-text");
  else if (kind === "success") el.classList.add("success-text");
}
function jobDescription(job) { if(!job||!job.status) return stageDescriptions.idle; if(job.status==="completed") return stageDescriptions.done; if(job.status==="failed") return stageDescriptions.failed; return stageDescriptions[job.stage] || "Julia is working on the current stage."; }
function updateActivityLights(job) { const node=$("activityLights"), status=job&&job.status?job.status:"", current=job&&job.stage?job.stage:"", idx=stages.findIndex(([id])=>id===current), completed=status==="completed", failed=status==="failed"; node.classList.toggle("running", status==="queued"||status==="running"); node.classList.toggle("idle", !job||!status); node.innerHTML=stages.map(([id,label],i)=>{ let cls="future"; if(completed||i<idx) cls="done"; else if(failed&&id===current) cls="failed"; else if(i===idx&&(status==="queued"||status==="running")) cls="active"; return `<span class="${cls}" title="${escapeHtml(label)}"></span>`; }).join(""); }
function renderStages(job) {
  const completed = job && job.status === "completed";
  const current = job && job.stage;
  const idx = stages.findIndex(([id]) => id === current);
  const failed = job && job.status === "failed";
  const w = $("stageSteps");
  w.innerHTML = "";
  stages.forEach(([id, label], i) => {
    const item = document.createElement("div");
    item.className = "stage-step";
    if (completed) item.classList.add("done");
    else if (failed && id === current) item.classList.add("failed");
    else if (idx >= 0 && i < idx) item.classList.add("done");
    else if (id === current) item.classList.add("active");
    item.innerHTML = `<strong>${label}</strong>`;
    w.appendChild(item);
  });
}
async function loadResults(jobId) {
  setResultsLoadingState("Loading run results…");
  try { renderResults(await fetchJson(`/api/jobs/${jobId}/results`)); state.resultsLoaded = true; }
  catch (error) { setResultsErrorState(error.message); }
}

async function loadOutputs() {
  try { const payload = await fetchJson("/api/outputs"); state.outputs = payload.outputs || []; renderOutputList(); setOutputStatus(`${state.outputs.length} output folder${state.outputs.length === 1 ? "" : "s"} found.`); }
  catch (error) { setOutputStatus(error.message); }
}

function renderOutputList() {
  const node = $("outputList");
  if (!state.outputs.length) { node.className = "output-list empty-state"; node.textContent = "No output folders found."; return; }
  node.className = "output-list";
  const compared = new Set(state.comparedOutputIds);
  node.innerHTML = state.outputs.map(output => {
    const id = escapeHtml(output.id);
    const selectedCls = output.id === state.selectedOutputId ? "selected" : "";
    const comparedCls = compared.has(output.id) ? "compared" : "";
    return `<div class="output-row ${selectedCls} ${comparedCls}" data-output-id="${id}" role="button" tabindex="0" title="Click to view; Ctrl/Cmd-click to toggle for compare; Shift-click to range-select">`
      + `<div class="output-body"><div class="output-name">${escapeHtml(output.name)}</div>`
      + `<div class="output-meta">${escapeHtml(output.solver || "solver?")} ${escapeHtml(output.solverVersion || "")} | ${escapeHtml(output.status || "status?")} | ${escapeHtml(fmt(output.objective))}</div>`
      + `<div class="output-meta">${escapeHtml(output.path)}</div></div></div>`;
  }).join("");
  document.querySelectorAll("#outputList .output-row").forEach(row => {
    row.addEventListener("click", e => handleOutputRowClick(e, row.dataset.outputId));
    row.addEventListener("keydown", e => {
      if (e.key === "Enter" || e.key === " ") { e.preventDefault(); handleOutputRowClick(e, row.dataset.outputId); }
    });
  });
}
function handleOutputRowClick(e, id) {
  const ids = state.outputs.map(o => o.id);
  const idx = ids.indexOf(id);
  if (idx < 0) return;
  if (e.shiftKey && state.lastClickedOutputId) {
    const lastIdx = ids.indexOf(state.lastClickedOutputId);
    if (lastIdx >= 0) {
      const [lo, hi] = lastIdx < idx ? [lastIdx, idx] : [idx, lastIdx];
      const range = ids.slice(lo, hi + 1);
      const set = new Set([...state.comparedOutputIds, ...range]);
      state.comparedOutputIds = ids.filter(x => set.has(x));
      renderOutputList();
      setOutputStatus(`${state.comparedOutputIds.length} output(s) selected for compare.`);
      return;
    }
  }
  if (e.ctrlKey || e.metaKey) {
    const set = new Set(state.comparedOutputIds);
    if (set.has(id)) set.delete(id); else set.add(id);
    state.comparedOutputIds = ids.filter(x => set.has(x));
    state.lastClickedOutputId = id;
    renderOutputList();
    setOutputStatus(`${state.comparedOutputIds.length} output(s) selected for compare.`);
    return;
  }
  // Plain click — view this run AND make it the sole compare anchor.
  state.lastClickedOutputId = id;
  state.comparedOutputIds = [id];
  viewOutput(id);
}

function selectedOutputIds() { return [...state.comparedOutputIds]; }
function setOutputStatus(message) { $("outputStatus").textContent = message; }

async function viewOutput(outputId) {
  state.selectedOutputId = outputId;
  setResultsLoadingState(`Loading ${outputId}…`);
  setOutputStatus(`Loading ${outputId}…`);
  try { const results = await fetchJson("/api/outputs/results", { method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify({ outputDir: outputId }) }); state.selectedOutputId = results.outputDir || outputId; renderResults(results); renderOutputList(); setOutputStatus("Loaded selected output."); }
  catch (error) { setResultsErrorState(error.message); setOutputStatus(error.message); }
}

async function deleteSelectedOutputs() {
  const ids = selectedOutputIds();
  if (!ids.length) { setOutputStatus("Select output folders to delete."); return; }
  if (!confirm(`Delete ${ids.length} output folder${ids.length === 1 ? "" : "s"}?`)) return;
  try {
    const payload = await fetchJson("/api/outputs/delete", { method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify({ outputDirs: ids }) });
    state.outputs = payload.outputs || [];
    const deletedIds = new Set(payload.deleted || []);
    state.comparedOutputIds = state.comparedOutputIds.filter(id => !deletedIds.has(id));
    if (deletedIds.has(state.selectedOutputId)) state.selectedOutputId = "";
    renderOutputList();
    const okCount = (payload.deleted || []).length;
    const fails = payload.failed || [];
    if (fails.length) {
      const first = fails[0];
      const more = fails.length > 1 ? ` (and ${fails.length - 1} more)` : "";
      setOutputStatus(`Deleted ${okCount}. Failed: ${first.id} \u2014 ${first.error}${more}`);
    } else {
      setOutputStatus(`Deleted ${okCount} output folder${okCount === 1 ? "" : "s"}.`);
    }
  } catch (error) { setOutputStatus(error.message); }
}

async function compareSelectedOutputs() {
  const ids = selectedOutputIds();
  if (ids.length < 2) { setOutputStatus("Select at least two output folders to compare."); return; }
  state.comparedOutputIds = ids; state.selectedOutputId = ""; renderOutputList();
  setComparisonMode(true);
  $("compareStatus").textContent = `Loading ${ids.length} outputs…`;
  setResultsLoadingState(`Loading ${ids.length} outputs for comparison…`);
  setLoadingChart("compareChart", "Loading comparison…", "bar-chart compact-chart");
  setLoadingChart("compareTimeChart", "Loading timing…", "bar-chart compact-chart");
  setLoadingTable("compareTable");
  setLoadingTable("compareCostTable");
  setOutputStatus(`Loading ${ids.length} outputs…`);
  try { const comparison = await fetchJson("/api/outputs/compare", { method:"POST", headers:{"Content-Type":"application/json"}, body:JSON.stringify({ outputDirs: ids }) }); renderComparison(comparison); setOutputStatus(`Compared ${comparison.runs.length} output folders.`); }
  catch (error) { setResultsErrorState(error.message); $("compareStatus").textContent = error.message; setOutputStatus(error.message); }
}

function renderComparison(comparison) {
  const runs = comparison.runs || [], totals = comparisonTotals(comparison), timing = comparison.timing || [], costs = comparison.costByComponent || [];
  setComparisonMode(true);
  $("compareStatus").textContent = `${runs.length} outputs selected`;
  $("resultsOutput").textContent = `Comparing ${runs.length} outputs`;
  renderComparisonMetrics(comparison, totals);
  const costStacks = buildCostStacks(costs, runs, totals), timingStacks = buildTimingStacks(timing);
  renderStackedBars("compareChart", costStacks, "MEUR", "bar-chart stacked-chart compact-chart");
  renderStackedBars("compareTimeChart", timingStacks, "sec", "bar-chart stacked-chart compact-chart");
  renderTable("compareTable", timing, 50);
  renderTable("compareCostTable", costs, 160);
  renderStackedBars("systemCostsChart", costStacks, "MEUR");
  renderTable("systemCostsTable", totals, 80);
  renderComparisonProfilePlaceholder();
  renderStackedBars("timingChart", timingStacks, "sec");
  renderTable("solverSettingsTable", runs, 80);
}

function comparisonTotals(comparison) { const by=new Map(); (comparison.totalCosts||[]).forEach(row=>{ const key=String(row.output||row.outputId||"output"), value=Number(row.value||row.objective||0); const item=by.get(key)||{output:key, outputId:row.outputId||"", periods:[], value:0}; item.value+=value; if(row.period!==undefined&&row.period!==null) item.periods.push(row.period); by.set(key,item); }); if(!by.size) (comparison.runs||[]).forEach(run=>by.set(run.name||run.id,{output:run.name||run.id, outputId:run.id||"", periods:String(run.periods||"").split(",").filter(Boolean), value:Number(run.objective||0)})); return [...by.values()].map(row=>({output:row.output, outputId:row.outputId, periods:[...new Set(row.periods)].join(", "), value:row.value})); }
function renderComparisonMetrics(comparison, totals) { const runs=comparison.runs||[], timing=comparison.timing||[], best=totals.reduce((a,b)=>!a||Number(b.value)<Number(a.value)?b:a,null), timed=timing.map(row=>({output:row.output||row.outputId||"output", seconds:timingTotal(row)})).filter(row=>Number.isFinite(row.seconds)&&row.seconds>0), fastest=timed.reduce((a,b)=>!a||b.seconds<a.seconds?b:a,null), solvers=[...new Set(runs.map(r=>`${r.solver||"solver?"}${r.solverVersion?` ${r.solverVersion}`:""}`))], statuses=[...new Set(runs.map(r=>r.status||"status?"))]; const items=[["Outputs",runs.length],["Lowest objective",best?`${best.output}: ${fmt(best.value)}`:""],["Fastest total time",fastest?`${fastest.output}: ${fmt(fastest.seconds)} sec`:""],["Solvers",solvers.join(", ")],["Statuses",statuses.join(", ")],["Compared periods",[...new Set(runs.flatMap(r=>String(r.periods||"").split(",").map(x=>x.trim()).filter(Boolean)))].join(", ")]]; $("metricGrid").innerHTML=items.map(([k,v])=>`<div class="metric"><span>${escapeHtml(k)}</span><strong>${escapeHtml(v)}</strong></div>`).join(""); }
function renderComponentComparison(id, rows, runs) { const c=$(id); if(!c) return; if(!rows.length){ c.className="bar-chart empty-state"; c.textContent="No component costs available."; return; } c.className="bar-chart"; let outputs=(runs||[]).map(r=>r.name).filter(Boolean); if(!outputs.length) outputs=[...new Set(rows.map(row=>String(row.output||"output")))]; const totals=new Map(), values=new Map(); rows.forEach(row=>{ const component=String(row.component||"component"), output=String(row.output||"output"), value=Number(row.cost_MEUR||0), key=`${component}\u0000${output}`; values.set(key,(values.get(key)||0)+value); totals.set(component,(totals.get(component)||0)+Math.abs(value)); }); const components=[...totals.entries()].sort((a,b)=>b[1]-a[1]).slice(0,8).map(([component])=>component), max=Math.max(1,...[...values.values()].map(Math.abs)); c.innerHTML=components.map(component=>`<div class="compare-group"><div class="compare-group-title">${escapeHtml(component)}</div>${outputs.map((output,i)=>{ const value=values.get(`${component}\u0000${output}`)||0, width=Math.max(2,Math.abs(value)/max*100); return `<div class="compare-row"><div class="compare-output" title="${escapeHtml(output)}">${escapeHtml(output)}</div><div class="bar-track"><div class="bar-fill ${value<0?"negative":""}" style="width:${width}%;background:${chartColors[i%chartColors.length]}"></div></div><div class="bar-value">${escapeHtml(fmt(value))} MEUR</div></div>`; }).join("")}</div>`).join(""); }
function renderComparisonProfilePlaceholder() {
  const msg = "Open one output run to inspect dispatch and supply/demand.";
  ["powerCapacityChart","emissionsChart","supplyDemandChart","co2PriceChart"].forEach(id => setEmptyChart(id, msg));
  setEmptyChart("hourlyDispatchChart", msg, "profile-chart");
  ["powerCapacityTable","emissionsTable","supplyDemandTable","co2PriceTable"].forEach(id => { const c=$(id); if (c) c.innerHTML=""; });
  const legend = $("hourlyDispatchLegend"); if (legend) legend.textContent="";
  const sdStatus = $("supplyDemandStatus"); if (sdStatus) sdStatus.textContent="";
  const emStatus = $("emissionsStatus"); if (emStatus) emStatus.textContent="";
}

function renderResults(results) {
  state.latestResults = results;
  state.comparedOutputIds = [state.selectedOutputId].filter(Boolean);
  state.lastClickedOutputId = state.selectedOutputId;
  clearComparisonPanels();
  state.selectedOutputId = results.outputDir || state.selectedOutputId;
  $("resultsOutput").textContent = results.outputDir || "";

  // Cheap immediate paint: header metrics + sidebar so the user sees
  // something within the first frame after the network response arrives.
  renderMetrics(results);
  renderOutputList();

  // Reset hourly-dispatch state up front so legend toggles and selectors
  // start in a clean state regardless of when the chart actually renders.
  state.dispatchLegendOff = new Set();
  const dispPayload = results.hourlyDispatch || { periods: [], nodes: [], series: [] };
  state.dispatchPayload = dispPayload;
  state.dispatchSelectedNode = String(dispPayload.selectedNode || (dispPayload.nodes?.[0] || ""));
  state.dispatchSelectedPeriod = Number(dispPayload.selectedPeriod || (dispPayload.periods?.[0] || 0));
  state.dispatchFromHour = 1;
  state.dispatchToHour = 8760;
  const fInput = $("hourlyDispatchFrom"); if (fInput) fInput.value = 1;
  const tInput = $("hourlyDispatchTo"); if (tInput) tInput.value = 8760;
  populateDispatchNodes(dispPayload);
  populateDispatchPeriods(dispPayload);
  populatePeriodSelect("emissionsPeriod", results.emissionGroupings?.periods || []);
  populateActivities(results.balanceActivities || { activities: [], periods: [] });
  populatePeriodSelect("supplyDemandPeriod", results.balanceActivities?.periods || []);

  // Each stage renders one panel and yields a frame so the browser can
  // paint and remain responsive. Top-of-page panels render first so the
  // user sees results filling in as they scroll downward.
  const stages = [
    () => {
      const costStacks = buildCostStacks(results.costByComponent || [], [], results.totalCosts || []);
      costStacks.length
        ? renderStackedBars("systemCostsChart", costStacks, "MEUR")
        : renderBars("systemCostsChart", results.totalCosts || [], r => `Period ${r.period}`, r => Number(r.value || 0), "MEUR");
      renderTable("systemCostsTable", results.totalCosts || []);
    },
    () => {
      renderStackedBars("timingChart", buildTimingStacks(results.timingSummary || []), "sec");
      renderTable("solverSettingsTable", results.solverSettings || [], 200);
    },
    () => { renderCO2Price(results.co2Price || []); },
    () => { renderActivityPrices(results.activityPrices || []); },
    () => { renderPowerCapacities(results.powerCapacities || { rows: [], periods: [] }); },
    () => { renderHourlyDispatch(dispPayload); },
    () => { refreshEmissions(); },
    () => { refreshSupplyDemand(); },
  ];
  // Bump the render token so any stages still queued from a previous
  // selection short-circuit and never overwrite the current spinners.
  state.renderToken = (state.renderToken || 0) + 1;
  const myToken = state.renderToken;
  const runStage = (i) => {
    if (myToken !== state.renderToken) return;
    if (i >= stages.length) return;
    try { stages[i](); } catch (err) { console.error(`Render stage ${i} failed`, err); }
    requestAnimationFrame(() => runStage(i + 1));
  };
  requestAnimationFrame(() => runStage(0));
}
function setComparisonMode(active) { $("comparisonPanel").classList.toggle("hidden", !active); }
function clearComparisonPanels() { setComparisonMode(false); $("compareStatus").textContent="Select outputs in the sidebar."; setEmptyChart("compareChart", "Select outputs to compare.", "bar-chart compact-chart"); setEmptyChart("compareTimeChart", "Select outputs to compare.", "bar-chart compact-chart"); $("compareTable").innerHTML=""; $("compareCostTable").innerHTML=""; }
function setEmptyChart(id, message, className="bar-chart") { const c=$(id); if (!c) return; c.className=`${className} empty-state`; c.textContent=message; }
function setLoadingChart(id, message="Loading…", className="bar-chart") {
  const c = $(id); if (!c) return;
  c.className = className;
  c.innerHTML = `<div class="chart-loading"><div class="spinner" aria-hidden="true"></div><span>${escapeHtml(message)}</span></div>`;
}
function setLoadingTable(id, message="Loading…") {
  const c = $(id); if (!c) return;
  c.innerHTML = `<div class="table-loading"><div class="spinner" aria-hidden="true"></div><span>${escapeHtml(message)}</span></div>`;
}
function setResultsLoadingState(message="Loading results…") {
  $("resultsOutput").textContent = message;
  $("metricGrid").innerHTML = `<div class="metric span-2"><div class="chart-loading"><div class="spinner" aria-hidden="true"></div><span>${escapeHtml(message)}</span></div></div>`;
  setLoadingChart("timingChart", message);
  setLoadingChart("systemCostsChart", message);
  setLoadingChart("co2PriceChart", message);
  setLoadingChart("powerCapacityChart", message);
  setLoadingChart("hourlyDispatchChart", message, "profile-chart");
  setLoadingChart("emissionsChart", message);
  setLoadingChart("supplyDemandChart", message);
  ["timingTable","solverSettingsTable","systemCostsTable","co2PriceTable","powerCapacityTable","emissionsTable","supplyDemandTable","activityPricesTable"].forEach(id => setLoadingTable(id));
}
function setResultsErrorState(message) {
  const m = message || "Could not load results.";
  $("resultsOutput").textContent = m;
  ["timingChart","systemCostsChart","co2PriceChart","powerCapacityChart","emissionsChart","supplyDemandChart"].forEach(id => setEmptyChart(id, m));
  setEmptyChart("hourlyDispatchChart", m, "profile-chart");
  ["timingTable","solverSettingsTable","systemCostsTable","co2PriceTable","powerCapacityTable","emissionsTable","supplyDemandTable","activityPricesTable"].forEach(id => { const c=$(id); if (c) c.innerHTML=""; });
}
function first(rows) { return rows && rows.length ? rows[0] : {}; }
function renderMetrics(results) { const t=first(results.timingSummary), s=first(results.runStatistics), c=first(results.totalCosts); const solver = t.solver ? `${t.solver}${t.solverVersion ? ` (${t.solverVersion})` : ""}` : ""; const items=[["Objective",fmt(c.value||s.objective||t.objective)],["Status",s.termination_status||t.termination_status||""],["Solver",solver],["Total seconds",fmt(t.total_sec||s.total_seconds)],["Solve seconds",fmt(t.solve_sec||s.solve_seconds)],["Rows / columns",`${fmt(t.n_rows||s.n_rows)} / ${fmt(t.n_cols||s.n_cols)}`]]; $("metricGrid").innerHTML=items.map(([k,v])=>`<div class="metric"><span>${escapeHtml(k)}</span><strong>${escapeHtml(v)}</strong></div>`).join(""); }
function valueFor(row, keys) { for (const key of keys) { const value = Number(row[key]); if (Number.isFinite(value)) return value; } return 0; }
function timingTotal(row) { const known = timingPhases.reduce((sum, phase) => sum + Math.max(0, valueFor(row, phase.keys)), 0), total = valueFor(row, ["total_sec", "totalSeconds", "total_seconds"]); return Math.max(total, known); }
function buildTimingStacks(rows) { return (rows || []).map(row => { const segments = timingPhases.map(phase => ({ label:phase.label, value:Math.max(0, valueFor(row, phase.keys)), color:phase.color })).filter(segment => segment.value > 0.001); const known = segments.reduce((sum, segment) => sum + segment.value, 0), total = valueFor(row, ["total_sec", "totalSeconds", "total_seconds"]); if (total > known + 0.01) segments.push({ label:"Other / setup", value:total - known, color:"#607080" }); return { label:String(row.output || row.scenario || row.outputId || "Run"), total:Math.max(total, known), segments }; }).filter(row => row.segments.length); }
function buildCostStacks(rows, runs, totals=[]) { const source = (rows || []).filter(row => Number.isFinite(Number(row.cost_MEUR))); if (!source.length) return (totals || []).map(row => { const value = Number(row.value || row.objective || 0); return { label:String(row.output || (row.period === undefined ? "Total cost" : `Period ${row.period}`)), total:value, segments:[{ label:"Total", value, color:chartColors[0] }] }; }).filter(row => Number.isFinite(row.total)); const runNames = (runs || []).map(run => run.name).filter(Boolean); const outputs = runNames.length ? runNames : [...new Set(source.map(row => String(row.output || "Total cost")))]; const values = new Map(), componentTotals = new Map(), outputTotals = new Map(); source.forEach(row => { const output = String(row.output || outputs[0] || "Total cost"), component = String(row.component || "component"), value = Number(row.cost_MEUR || 0), key = `${output}\u0000${component}`; values.set(key, (values.get(key) || 0) + value); componentTotals.set(component, (componentTotals.get(component) || 0) + Math.abs(value)); outputTotals.set(output, (outputTotals.get(output) || 0) + value); }); const components = [...componentTotals.entries()].sort((a,b) => b[1] - a[1]).map(([component]) => component), shown = components.slice(0, 10), other = components.slice(10); return outputs.map(output => { const segments = shown.map((component, i) => ({ label:component, value:values.get(`${output}\u0000${component}`) || 0, color:chartColors[i % chartColors.length] })).filter(segment => Math.abs(segment.value) > 0.001); const otherValue = other.reduce((sum, component) => sum + (values.get(`${output}\u0000${component}`) || 0), 0); if (Math.abs(otherValue) > 0.001) segments.push({ label:"Other", value:otherValue, color:"#607080" }); return { label:output, total:outputTotals.get(output) || segments.reduce((sum, segment) => sum + segment.value, 0), segments }; }).filter(row => row.segments.length); }
function renderStackedBars(id, rows, unit, className="bar-chart stacked-chart") { const c=$(id); if (!c) return; if(!rows.length){ c.className=`${className} empty-state`; c.textContent="No data available."; return; } c.className=className; const labels=[...new Map(rows.flatMap(row=>row.segments.map(segment=>[segment.label,segment.color]))).entries()], max=Math.max(1,...rows.map(row=>Math.max(Math.abs(row.total || 0), row.segments.reduce((sum, segment)=>sum+Math.abs(segment.value),0)))); c.innerHTML=`<div class="stacked-legend">${labels.map(([label,color])=>`<span class="legend-item"><span class="legend-swatch" style="background:${color}"></span>${escapeHtml(label)}</span>`).join("")}</div>` + rows.slice(0,12).map(row=>{ const rowAbs=row.segments.reduce((sum, segment)=>sum+Math.abs(segment.value),0), width=Math.max(2, Math.max(rowAbs, Math.abs(row.total || 0)) / max * 100); return `<div class="stacked-row"><div class="bar-label" title="${escapeHtml(row.label)}">${escapeHtml(row.label)}</div><div class="stacked-track"><div class="stacked-bar" style="width:${width}%">${row.segments.map(segment=>`<div class="stacked-segment" title="${escapeHtml(segment.label)}: ${escapeHtml(fmt(segment.value))} ${unit}" style="flex:${Math.max(Math.abs(segment.value), 0.001)} 1 0;background:${segment.color}"></div>`).join("")}</div></div><div class="bar-value">${escapeHtml(fmt(row.total))} ${unit}</div></div>`; }).join(""); }
function renderBars(id, rows, labelFn, valueFn, unit) { const c=$(id); if (!c) return; if(!rows.length){ c.className="bar-chart empty-state"; c.textContent="No data available."; return; } c.className="bar-chart"; const max=Math.max(...rows.map(r=>Math.abs(valueFn(r))),1); c.innerHTML=rows.slice(0,12).map(r=>{ const v=valueFn(r), w=Math.max(2,Math.abs(v)/max*100); return `<div class="bar-row"><div class="bar-label" title="${escapeHtml(labelFn(r))}">${escapeHtml(labelFn(r))}</div><div class="bar-track"><div class="bar-fill ${v<0?"negative":""}" style="width:${w}%"></div></div><div class="bar-value">${escapeHtml(fmt(v))} ${unit}</div></div>`; }).join(""); }
function renderCO2Price(rows) {
  const c = $("co2PriceChart"); if (!c) return;
  const data = (rows || []).filter(r => Number.isFinite(Number(r.value)));
  if (!data.length) { c.className="bar-chart empty-state"; c.textContent="No CO\u2082 price available (solver may not have returned duals)."; const t=$("co2PriceTable"); if (t) t.innerHTML=""; return; }
  renderBars("co2PriceChart", data, r => `Period ${r.period}`, r => Number(r.value || 0), "EUR/tCO\u2082eq");
  renderTable("co2PriceTable", data, 50);
}
function renderPowerCapacities(payload) {
  const rows = payload?.rows || [];
  const c = $("powerCapacityChart"); if (!c) return;
  if (!rows.length) { setEmptyChart("powerCapacityChart", "No power-system technologies found."); const t=$("powerCapacityTable"); if (t) t.innerHTML=""; return; }
  // Stack per period by tech.
  const periods = payload.periods && payload.periods.length ? payload.periods : [...new Set(rows.map(r => Number(r.period)))].sort((a,b)=>a-b);
  const techTotals = new Map();
  rows.forEach(r => techTotals.set(r.tech, (techTotals.get(r.tech) || 0) + Math.abs(Number(r.value || 0))));
  const topTechs = [...techTotals.entries()].sort((a,b)=>b[1]-a[1]).slice(0, 12).map(([t])=>t);
  const stacks = periods.map(p => {
    const segments = topTechs.map((t, i) => {
      const v = rows.filter(r => r.tech === t && Number(r.period) === p).reduce((s, r) => s + Number(r.value || 0), 0);
      return { label: t, value: v, color: chartColors[i % chartColors.length] };
    }).filter(seg => Math.abs(seg.value) > 1e-6);
    return { label: `Period ${p}`, total: segments.reduce((s, seg) => s + seg.value, 0), segments };
  }).filter(stack => stack.segments.length);
  if (!stacks.length) { setEmptyChart("powerCapacityChart", "No power-system technologies found."); const t=$("powerCapacityTable"); if (t) t.innerHTML=""; return; }
  renderStackedBars("powerCapacityChart", stacks, "");
  renderTable("powerCapacityTable", rows, 200);
}
function populateDispatchPeriods(payload) {
  const sel = $("hourlyDispatchPeriod"); if (!sel) return;
  const periods = (payload?.periods || []).map(Number).filter(Number.isFinite);
  sel.innerHTML = periods.map(p => `<option value="${p}">${p}</option>`).join("");
  const want = String(state.dispatchSelectedPeriod || payload?.selectedPeriod || periods[0] || "");
  if (want && periods.map(String).includes(want)) sel.value = want;
  else if (periods.length) sel.value = String(periods[0]);
  state.dispatchSelectedPeriod = Number(sel.value) || 0;
}
function populateDispatchNodes(payload) {
  const sel = $("hourlyDispatchNode"); if (!sel) return;
  const nodes = payload?.nodes || [];
  sel.innerHTML = nodes.length
    ? nodes.map(n => `<option value="${escapeHtml(n)}">${escapeHtml(n)}</option>`).join("")
    : `<option value="">(all)</option>`;
  const want = state.dispatchSelectedNode || payload?.selectedNode || nodes[0] || "";
  if (want && nodes.includes(want)) sel.value = want;
  else if (nodes.length) sel.value = nodes[0];
  state.dispatchSelectedNode = sel.value || "";
}
async function refreshHourlyDispatch() {
  if (!state.selectedOutputId || state.dispatchLoading) return;
  state.dispatchLoading = true;
  setLoadingChart("hourlyDispatchChart", "Loading hourly dispatch (full year)…", "profile-chart");
  const legend = $("hourlyDispatchLegend"); if (legend) legend.textContent = "Loading…";
  try {
    const body = { outputDir: state.selectedOutputId };
    if (state.dispatchSelectedNode) body.node = state.dispatchSelectedNode;
    if (state.dispatchSelectedPeriod) body.period = state.dispatchSelectedPeriod;
    const payload = await fetchJson("/api/outputs/hourlyDispatch", { method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify(body) });
    state.dispatchPayload = payload;
    state.dispatchSelectedNode = payload.selectedNode || state.dispatchSelectedNode;
    state.dispatchSelectedPeriod = payload.selectedPeriod || state.dispatchSelectedPeriod;
    populateDispatchNodes(payload);
    populateDispatchPeriods(payload);
    renderHourlyDispatch(payload);
  } catch (e) {
    setEmptyChart("hourlyDispatchChart", `Could not load hourly dispatch: ${e.message || e}`, "profile-chart");
    if (legend) legend.textContent = "Error";
  } finally {
    state.dispatchLoading = false;
  }
}
function renderHourlyDispatch(payload) {
  const c = $("hourlyDispatchChart"); const legend = $("hourlyDispatchLegend"); if (!c) return;
  if (!payload) { c.className="profile-chart empty-state"; c.textContent="No dispatch data available."; if (legend) legend.textContent=""; return; }
  const techs = payload.techs || [];
  const series = payload.series || [];
  const hours = payload.hours || [];
  if (!techs.length || !series.length || !hours.length) {
    c.className="profile-chart empty-state";
    c.textContent = payload.selectedNode
      ? `No dispatch data for node ${payload.selectedNode} in period ${payload.selectedPeriod || ""}.`
      : "No dispatch data available.";
    if (legend) legend.textContent="";
    return;
  }
  const hoursLen = hours.length;
  const fromHour = clampHour(state.dispatchFromHour, 1, hoursLen);
  const toHour = clampHour(state.dispatchToHour, fromHour, hoursLen);
  const sliceStart = fromHour - 1;
  const sliceEnd = toHour;
  const totalPoints = sliceEnd - sliceStart;
  if (totalPoints <= 0) { c.className="profile-chart empty-state"; c.textContent="Empty range — adjust From/To hours."; if (legend) legend.textContent=""; return; }
  c.className = "profile-chart dispatch-chart";

  // Build sliced positive/negative stacks (biggest segment goes on the BOTTOM
  // of the positive stack and on the TOP of the negative stack — the backend
  // already ordered techs by descending |total|).
  const techData = series.map((s, idx) => ({
    tech: String(s.tech),
    values: (s.values || []).slice(sliceStart, sliceEnd),
    color: chartColors[idx % chartColors.length],
    hidden: state.dispatchLegendOff.has(String(s.tech)),
  })).filter(s => s.values.length === totalPoints);
  if (!techData.length) { c.className="profile-chart empty-state"; c.textContent="No samples in range."; if (legend) legend.textContent=""; return; }

  // Downsample for screen: keep at most ~960 segments so the SVG stays light.
  const maxSamples = 960;
  const step = Math.max(1, Math.floor(totalPoints / maxSamples));
  const sampledIdx = [];
  for (let i = 0; i < totalPoints; i += step) sampledIdx.push(i);
  if (sampledIdx[sampledIdx.length - 1] !== totalPoints - 1) sampledIdx.push(totalPoints - 1);
  const sampledCount = sampledIdx.length;

  const W = 1100, H = 360, p = { l: 70, r: 24, t: 18, b: 36 };
  const sx = i => p.l + i / Math.max(1, sampledCount - 1) * (W - p.l - p.r);

  // Per-sample stacked positive and negative cumulative arrays.
  const visibleTechs = techData.filter(t => !t.hidden);
  const posCum = new Array(sampledCount).fill(0);
  const negCum = new Array(sampledCount).fill(0);
  // For each tech, store its [y0, y1] band per sample as cumulative.
  const techBands = visibleTechs.map(t => {
    const lower = new Array(sampledCount);
    const upper = new Array(sampledCount);
    for (let k = 0; k < sampledCount; k++) {
      const v = Number(t.values[sampledIdx[k]] || 0);
      if (v >= 0) { lower[k] = posCum[k]; posCum[k] += v; upper[k] = posCum[k]; }
      else        { upper[k] = negCum[k]; negCum[k] += v; lower[k] = negCum[k]; }
    }
    return { tech: t.tech, color: t.color, lower, upper };
  });
  const yMax = Math.max(1e-9, ...posCum);
  const yMin = Math.min(0,    ...negCum);
  const sy = y => H - p.b - (y - yMin) / Math.max(1e-9, (yMax - yMin)) * (H - p.t - p.b);

  // Build a polygon path for each tech band.
  const pathFor = band => {
    let d = "";
    for (let k = 0; k < sampledCount; k++) {
      const x = sx(k).toFixed(1);
      const y = sy(band.upper[k]).toFixed(1);
      d += (k === 0 ? "M" : "L") + x + "," + y + " ";
    }
    for (let k = sampledCount - 1; k >= 0; k--) {
      const x = sx(k).toFixed(1);
      const y = sy(band.lower[k]).toFixed(1);
      d += "L" + x + "," + y + " ";
    }
    d += "Z";
    return d;
  };
  const areaEls = techBands.map(band => `<path class="dispatch-area" data-tech="${escapeHtml(band.tech)}" d="${pathFor(band)}" fill="${band.color}" fill-opacity="0.85" stroke="${band.color}" stroke-width="0.4"></path>`).join("");

  // Gridlines (x = hour, y = value)
  const xTicks = 12, yTicks = 5;
  const xGrid = Array.from({length: xTicks + 1}, (_, i) => {
    const sampleIdx = Math.round(i * (sampledCount - 1) / xTicks);
    const hour = fromHour + sampledIdx * step;
    const x = sx(sampleIdx);
    return `<line x1="${x.toFixed(1)}" y1="${p.t}" x2="${x.toFixed(1)}" y2="${H - p.b}" stroke="#eef2f5" stroke-width="1"></line>`
      + `<text x="${x.toFixed(1)}" y="${H - p.b + 16}" font-size="11" fill="#647280" text-anchor="middle">${hour}</text>`;
  }).join("");
  const yGrid = Array.from({length: yTicks + 1}, (_, i) => {
    const y = yMin + i * (yMax - yMin) / yTicks;
    return `<line x1="${p.l}" y1="${sy(y).toFixed(1)}" x2="${W - p.r}" y2="${sy(y).toFixed(1)}" stroke="#eef2f5" stroke-width="1"></line>`
      + `<text x="${p.l - 8}" y="${(sy(y) + 4).toFixed(1)}" font-size="11" fill="#647280" text-anchor="end">${fmt(y)}</text>`;
  }).join("");

  c.innerHTML = `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Hourly dispatch stacked area">${xGrid}${yGrid}${areaEls}`
    + `<line x1="${p.l}" y1="${H - p.b}" x2="${W - p.r}" y2="${H - p.b}" stroke="#d8e1e8"></line>`
    + `<line x1="${p.l}" y1="${p.t}" x2="${p.l}" y2="${H - p.b}" stroke="#d8e1e8"></line>`
    + `<rect class="dispatch-brush" x="0" y="0" width="0" height="0" fill="#1d5f8f" fill-opacity="0.15" stroke="#1d5f8f" stroke-width="1" stroke-dasharray="4 2" pointer-events="none"></rect>`
    + `<rect class="dispatch-hit" x="${p.l}" y="${p.t}" width="${W - p.l - p.r}" height="${H - p.t - p.b}" fill="transparent" cursor="crosshair"></rect>`
    + `<line class="dispatch-cursor" x1="0" y1="${p.t}" x2="0" y2="${H - p.b}" stroke="#0f2436" stroke-width="0.8" stroke-dasharray="2 2" opacity="0" pointer-events="none"></line>`
    + `</svg>`
    + `<div class="dispatch-tooltip" role="tooltip" aria-hidden="true"></div>`
    + `<div class="dispatch-legend">${techData.map(t => `<span class="legend-item${t.hidden?" disabled":""}" data-tech="${escapeHtml(t.tech)}"><span class="legend-swatch" style="background:${t.color}"></span>${escapeHtml(t.tech)}</span>`).join("")}</div>`;
  if (legend) legend.textContent = `${visibleTechs.length}/${techData.length} tech(s) shown · hours ${fromHour}–${toHour} of ${hoursLen} · node ${payload.selectedNode || "(all)"} · period ${payload.selectedPeriod || ""}`;
  bindDispatchInteraction(c, techBands, sampledIdx, sampledCount, fromHour, step, sx, sy, W, H, p);
}
function bindDispatchInteraction(container, techBands, sampledIdx, sampledCount, fromHour, step, sx, sy, W, H, p) {
  const svg = container.querySelector("svg");
  const tooltip = container.querySelector(".dispatch-tooltip");
  const cursor = container.querySelector(".dispatch-cursor");
  const brush = container.querySelector(".dispatch-brush");
  function svgPt(clientX) {
    const rect = svg.getBoundingClientRect();
    return (clientX - rect.left) / rect.width * W;
  }
  function nearestSample(svgX) {
    if (sampledCount <= 1) return 0;
    const ratio = (svgX - p.l) / Math.max(1, W - p.l - p.r);
    const idx = Math.round(ratio * (sampledCount - 1));
    return Math.max(0, Math.min(sampledCount - 1, idx));
  }
  function showTooltip(k, clientX) {
    if (k == null || !techBands.length) { tooltip.classList.remove("show"); cursor.setAttribute("opacity","0"); return; }
    const x = sx(k);
    cursor.setAttribute("x1", x.toFixed(1));
    cursor.setAttribute("x2", x.toFixed(1));
    cursor.setAttribute("opacity","1");
    const hour = fromHour + sampledIdx[k] * step;
    const lines = techBands.map(b => {
      const v = b.upper[k] - b.lower[k];
      if (Math.abs(v) < 1e-6) return "";
      return `<div><span class="legend-swatch" style="background:${b.color}"></span> <strong>${escapeHtml(b.tech)}</strong>: ${escapeHtml(fmt(v))}</div>`;
    }).filter(Boolean).join("");
    const total = techBands.reduce((s, b) => s + (b.upper[k] - b.lower[k]), 0);
    tooltip.innerHTML = `<div><strong>Hour ${hour}</strong> (day ${Math.ceil(hour/24)}, h-of-day ${((hour-1)%24)+1})</div>${lines}<div style="margin-top:4px"><strong>Total:</strong> ${escapeHtml(fmt(total))}</div>`;
    const cRect = container.getBoundingClientRect();
    const svgRect = svg.getBoundingClientRect();
    const px = svgRect.left + x / W * svgRect.width - cRect.left;
    tooltip.style.left = `${px}px`;
    tooltip.style.top = `${svgRect.top - cRect.top + 8}px`;
    tooltip.classList.add("show");
  }
  let dragStart = null;
  svg.addEventListener("mousemove", e => {
    const x = svgPt(e.clientX);
    const k = nearestSample(x);
    showTooltip(k, e.clientX);
    if (dragStart != null) {
      const lo = Math.min(dragStart, x), hi = Math.max(dragStart, x);
      brush.setAttribute("x", lo.toFixed(1));
      brush.setAttribute("y", String(p.t));
      brush.setAttribute("width", (hi - lo).toFixed(1));
      brush.setAttribute("height", String(H - p.t - p.b));
    }
  });
  svg.addEventListener("mouseleave", () => { showTooltip(null); dragStart = null; brush.setAttribute("width","0"); });
  svg.addEventListener("mousedown", e => {
    if (e.button !== 0) return;
    dragStart = svgPt(e.clientX);
    brush.setAttribute("x", String(dragStart));
    brush.setAttribute("y", String(p.t));
    brush.setAttribute("width","0");
    brush.setAttribute("height", String(H - p.t - p.b));
  });
  svg.addEventListener("mouseup", e => {
    if (dragStart == null) return;
    const x = svgPt(e.clientX);
    const lo = Math.min(dragStart, x), hi = Math.max(dragStart, x);
    dragStart = null;
    brush.setAttribute("width","0");
    if (hi - lo < 6) return;  // ignore click-like drags
    const k0 = nearestSample(lo), k1 = nearestSample(hi);
    const newFrom = fromHour + sampledIdx[k0] * step;
    const newTo   = fromHour + sampledIdx[k1] * step;
    state.dispatchFromHour = Math.max(1, Math.min(newFrom, newTo));
    state.dispatchToHour   = Math.min(8760, Math.max(newFrom, newTo));
    const f = $("hourlyDispatchFrom"); if (f) f.value = state.dispatchFromHour;
    const t = $("hourlyDispatchTo"); if (t) t.value = state.dispatchToHour;
    renderHourlyDispatch(state.dispatchPayload);
  });
  // Legend toggle (hide/show a tech)
  container.querySelectorAll(".dispatch-legend .legend-item").forEach(el => {
    el.addEventListener("click", () => {
      const t = el.dataset.tech;
      if (state.dispatchLegendOff.has(t)) state.dispatchLegendOff.delete(t); else state.dispatchLegendOff.add(t);
      renderHourlyDispatch(state.dispatchPayload);
    });
  });
}
function renderActivityPrices(rows) {
  const c = $("activityPricesTable"); if (!c) return;
  const data = (rows || []).filter(r => Number.isFinite(Number(r.price)) && Math.abs(Number(r.price)) > 1e-6);
  if (!data.length) { c.className="table-wrap empty-state"; c.textContent="No activity prices available (solver may not have returned duals)."; return; }
  c.className = "table-wrap";
  // Sort by descending abs(price) so the most informative rows are first.
  data.sort((a, b) => Math.abs(Number(b.price)) - Math.abs(Number(a.price)));
  renderTable("activityPricesTable", data, 100);
}
function populatePeriodSelect(id, periods) {
  const sel = $(id); if (!sel) return;
  const prev = sel.value;
  const opts = [`<option value="">All</option>`].concat((periods || []).map(p => `<option value="${p}">Period ${p}</option>`));
  sel.innerHTML = opts.join("");
  if (prev && (prev === "" || (periods || []).map(String).includes(prev))) sel.value = prev;
}
function populateActivities(payload) {
  const sel = $("supplyDemandActivity"); if (!sel) return;
  const items = payload?.activities || [];
  const prev = sel.value;
  sel.innerHTML = items.map(a => `<option value="${escapeHtml(a.activity)}">${escapeHtml(a.activity)}${a.label ? ` · ${escapeHtml(a.label)}` : ""}</option>`).join("");
  if (prev && items.map(a => a.activity).includes(prev)) sel.value = prev;
}
async function refreshEmissions() {
  if (!state.selectedOutputId) return;
  const groupBy = $("emissionsGroupBy")?.value || "activity";
  const periodVal = $("emissionsPeriod")?.value || "";
  setLoadingChart("emissionsChart", "Loading emissions\u2026", "vstack-chart");
  setLoadingTable("emissionsTable");
  const status = $("emissionsStatus"); if (status) status.textContent = "Loading\u2026";
  try {
    const payload = await fetchJson("/api/outputs/emissions", { method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify({ outputDir: state.selectedOutputId, groupBy }) });
    const rows = (payload.rows || []).filter(r => periodVal === "" || String(r.period) === String(periodVal));
    if (!rows.length) { setEmptyChart("emissionsChart", "No emissions data.", "vstack-chart"); $("emissionsTable").innerHTML=""; if (status) status.textContent = ""; return; }
    const { categories, series } = buildVerticalSeriesFromRows(rows, "period", "group", "value");
    renderVerticalStackedBars("emissionsChart", { categories, series, unit:"MtonCO\u2082eq", showNet:true, categoryLabel: per => `${per}` });
    // Show the per-tech detail in the optional table so the user can see
    // which technologies sit inside each emission group.
    const detail = (payload.detailRows || []).filter(r => periodVal === "" || String(r.period) === String(periodVal));
    renderTable("emissionsTable", detail.length ? detail : rows, 1000);
    if (status) status.textContent = `${rows.length} group row(s) \u00b7 ${detail.length} tech row(s) \u00b7 group by ${groupBy}`;
  } catch (e) {
    setEmptyChart("emissionsChart", `Could not load emissions: ${e.message || e}`, "vstack-chart");
    if (status) status.textContent = "Error";
  }
}
async function refreshSupplyDemand() {
  if (!state.selectedOutputId) return;
  const activity = $("supplyDemandActivity")?.value || "";
  const periodVal = $("supplyDemandPeriod")?.value || "";
  if (!activity) { setEmptyChart("supplyDemandChart", "Select an activity to view supply and demand.", "vstack-chart"); $("supplyDemandTable").innerHTML=""; return; }
  setLoadingChart("supplyDemandChart", "Loading supply/demand\u2026", "vstack-chart");
  setLoadingTable("supplyDemandTable");
  const status = $("supplyDemandStatus"); if (status) status.textContent = "Loading\u2026";
  try {
    const body = { outputDir: state.selectedOutputId, activity };
    if (periodVal !== "") body.period = Number(periodVal);
    const payload = await fetchJson("/api/outputs/supplyDemand", { method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify(body) });
    renderSupplyDemand(payload);
    if (status) status.textContent = `${payload.rows?.length || 0} row(s)`;
  } catch (e) {
    setEmptyChart("supplyDemandChart", `Could not load supply/demand: ${e.message || e}`, "vstack-chart");
    if (status) status.textContent = "Error";
  }
}
function renderSupplyDemand(payload) {
  const c = $("supplyDemandChart"); if (!c) return;
  const rows = payload?.rows || [];
  if (!rows.length) { setEmptyChart("supplyDemandChart", "No supply or demand for this activity.", "vstack-chart"); $("supplyDemandTable").innerHTML=""; return; }
  const { categories, series } = buildVerticalSeriesFromRows(rows, "period", "tech", "value");
  renderVerticalStackedBars("supplyDemandChart", { categories, series, unit:"PJ", showNet:true, categoryLabel: per => `${per}` });
  renderTable("supplyDemandTable", rows, 250);
}
// Build categories + series for the vertical stacked-bar renderer from a flat
// list of rows. `categoryKey` typically points at `period`, `seriesKey` at the
// stack dimension (group/tech), `valueKey` at the numeric value.
function buildVerticalSeriesFromRows(rows, categoryKey, seriesKey, valueKey) {
  const categories = [...new Set(rows.map(r => Number(r[categoryKey])))].filter(v => Number.isFinite(v)).sort((a,b)=>a-b);
  const seriesNames = [...new Set(rows.map(r => String(r[seriesKey])))];
  const seriesTotals = new Map();
  for (const name of seriesNames) seriesTotals.set(name, 0);
  for (const r of rows) {
    const v = Number(r[valueKey] || 0);
    if (!Number.isFinite(v)) continue;
    seriesTotals.set(String(r[seriesKey]), (seriesTotals.get(String(r[seriesKey])) || 0) + Math.abs(v));
  }
  // Sort series by absolute total contribution so the largest stack segments
  // get the most distinctive colors.
  const ordered = [...seriesNames].sort((a, b) => (seriesTotals.get(b) || 0) - (seriesTotals.get(a) || 0));
  const series = ordered.map((name, idx) => {
    const values = categories.map(cat => {
      let sum = 0;
      for (const r of rows) {
        if (String(r[seriesKey]) !== name) continue;
        if (Number(r[categoryKey]) !== cat) continue;
        const v = Number(r[valueKey] || 0);
        if (Number.isFinite(v)) sum += v;
      }
      return sum;
    });
    return { label: name, color: chartColors[idx % chartColors.length], values };
  }).filter(s => s.values.some(v => Math.abs(v) > 1e-9));
  return { categories, series };
}
// Vertical stacked bar chart with native support for negative values and a
// black diamond marker for the per-category net total. Uses raw SVG so the
// chart can be embedded without any external dependency. Hover interactions
// dim non-hovered segments and surface a tooltip with the segment label and
// value. Clicking a legend entry toggles the series visibility.
function renderVerticalStackedBars(id, options) {
  const c = $(id); if (!c) return;
  const categories = options.categories || [];
  const allSeries = (options.series || []).map(s => ({ ...s }));
  if (!categories.length || !allSeries.length) { setEmptyChart(id, "No data available.", "vstack-chart"); return; }
  c.className = "vstack-chart";
  const stateKey = `__vstackHidden_${id}`;
  if (!Array.isArray(c[stateKey])) c[stateKey] = [];
  const hiddenSet = new Set(c[stateKey]);
  const series = allSeries.map(s => ({ ...s, hidden: hiddenSet.has(s.label) }));
  const W = Math.max(420, c.clientWidth || 720);
  const H = 360;
  const padL = 64, padR = 18, padT = 18, padB = 44;
  const innerW = W - padL - padR, innerH = H - padT - padB;
  const showNet = !!options.showNet;
  const unit = options.unit || "";
  const fmtVal = options.formatValue || (v => fmt(v));
  // Compute the worst-case +/- envelope per category, taking only currently
  // visible series into account. The y-scale spans both sides symmetrically
  // around 0 so the zero line sits at a stable position across periods.
  let maxPos = 0, maxNeg = 0;
  const nets = categories.map((cat, i) => {
    let pos = 0, neg = 0;
    series.forEach(s => {
      if (s.hidden) return;
      const v = Number(s.values[i] || 0);
      if (v >= 0) pos += v; else neg += v;
    });
    if (pos > maxPos) maxPos = pos;
    if (neg < maxNeg) maxNeg = neg;
    return pos + neg;
  });
  const yMaxRaw = Math.max(maxPos, Math.abs(maxNeg), 1e-6);
  const niceStep = niceTickStep(yMaxRaw);
  const yMax = Math.ceil(maxPos / niceStep) * niceStep || niceStep;
  const yMin = Math.floor(maxNeg / niceStep) * niceStep;
  const span = (yMax - yMin) || 1;
  const yScale = v => padT + innerH * (1 - (v - yMin) / span);
  const barWidth = Math.max(20, Math.min(72, innerW / categories.length * 0.55));
  const xCenter = i => padL + innerW * ((i + 0.5) / categories.length);
  const ticks = [];
  for (let v = yMin; v <= yMax + 1e-9; v += niceStep) ticks.push(Number(v.toFixed(6)));
  const grid = ticks.map(t => `<line class="vstack-grid" x1="${padL}" y1="${yScale(t).toFixed(2)}" x2="${padL+innerW}" y2="${yScale(t).toFixed(2)}"></line>`).join("");
  const tickLabels = ticks.map(t => `<text class="vstack-tick" x="${padL-8}" y="${(yScale(t)+3).toFixed(2)}" text-anchor="end">${escapeHtml(fmtVal(t))}</text>`).join("");
  const zeroLine = `<line class="vstack-zero" x1="${padL}" y1="${yScale(0).toFixed(2)}" x2="${padL+innerW}" y2="${yScale(0).toFixed(2)}"></line>`;
  const catLabels = categories.map((cat, i) => `<text class="vstack-cat" x="${xCenter(i).toFixed(2)}" y="${(padT+innerH+22).toFixed(2)}" text-anchor="middle">${escapeHtml(options.categoryLabel ? options.categoryLabel(cat) : String(cat))}</text>`).join("");
  // Stack the segments around 0 — positives accumulate upward, negatives
  // downward. Hidden series simply skip their slot.
  const segs = [];
  categories.forEach((cat, i) => {
    let posAcc = 0, negAcc = 0;
    series.forEach(s => {
      if (s.hidden) return;
      const v = Number(s.values[i] || 0);
      if (Math.abs(v) < 1e-9) return;
      const x = xCenter(i) - barWidth / 2;
      let y0, y1;
      if (v >= 0) { y0 = posAcc; y1 = posAcc + v; posAcc = y1; }
      else        { y0 = negAcc; y1 = negAcc + v; negAcc = y1; }
      const yTop = Math.min(yScale(y0), yScale(y1));
      const yBot = Math.max(yScale(y0), yScale(y1));
      const h = Math.max(0.6, yBot - yTop);
      segs.push({ cat, label:s.label, value:v, color:s.color, x, y:yTop, w:barWidth, h });
    });
  });
  const segsSvg = segs.map((s, idx) => `<rect class="vstack-segment" data-idx="${idx}" x="${s.x.toFixed(2)}" y="${s.y.toFixed(2)}" width="${s.w.toFixed(2)}" height="${s.h.toFixed(2)}" fill="${s.color}" stroke="#fff" stroke-width="0.6"></rect>`).join("");
  // Black diamond marker on each bar at the visible-series net total. Drawn
  // last so the stroke sits above the segments.
  const netSvg = !showNet ? "" : categories.map((cat, i) => {
    const cx = xCenter(i), cy = yScale(nets[i]);
    const sz = 7;
    return `<polygon class="vstack-net" points="${cx},${cy-sz} ${cx+sz},${cy} ${cx},${cy+sz} ${cx-sz},${cy}" data-net="1" data-cat-idx="${i}"></polygon>`;
  }).join("");
  const svg = `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none">${grid}${zeroLine}${segsSvg}${netSvg}<line class="vstack-axis" x1="${padL}" y1="${padT}" x2="${padL}" y2="${padT+innerH}"></line><line class="vstack-axis" x1="${padL}" y1="${padT+innerH}" x2="${padL+innerW}" y2="${padT+innerH}"></line>${tickLabels}${catLabels}</svg>`;
  const legendItems = allSeries.map(s => {
    const dis = hiddenSet.has(s.label) ? " disabled" : "";
    return `<span class="legend-item${dis}" data-label="${escapeHtml(s.label)}"><span class="legend-swatch" style="background:${s.color}"></span>${escapeHtml(s.label)}</span>`;
  }).join("");
  const netLegend = showNet ? `<span class="legend-item net-marker" title="Net (sum of visible series)"><span class="legend-swatch"></span>Net</span>` : "";
  const legend = `<div class="vstack-legend">${netLegend}${legendItems}</div>`;
  c.innerHTML = `${svg}<div class="vstack-tooltip" id="${id}_tip"></div>${legend}`;
  const tip = $(`${id}_tip`);
  c.querySelectorAll(".legend-item[data-label]").forEach(el => {
    el.addEventListener("click", () => {
      const label = el.dataset.label;
      const cur = new Set(c[stateKey] || []);
      if (cur.has(label)) cur.delete(label); else cur.add(label);
      c[stateKey] = [...cur];
      renderVerticalStackedBars(id, options);
    });
  });
  c.querySelectorAll(".vstack-segment").forEach(rect => {
    rect.addEventListener("mousemove", evt => {
      const idx = Number(rect.dataset.idx);
      const s = segs[idx]; if (!s) return;
      const r = c.getBoundingClientRect();
      tip.style.left = `${evt.clientX - r.left}px`;
      tip.style.top  = `${evt.clientY - r.top - 32}px`;
      tip.innerHTML = `<strong>${escapeHtml(s.label)}</strong><br>${escapeHtml(options.categoryLabel ? options.categoryLabel(s.cat) : String(s.cat))}: ${escapeHtml(fmtVal(s.value))} ${escapeHtml(unit)}`;
      tip.classList.add("show");
    });
    rect.addEventListener("mouseleave", () => { tip.classList.remove("show"); });
  });
  c.querySelectorAll(".vstack-net").forEach(poly => {
    poly.addEventListener("mousemove", evt => {
      const i = Number(poly.dataset.catIdx);
      const r = c.getBoundingClientRect();
      tip.style.left = `${evt.clientX - r.left}px`;
      tip.style.top  = `${evt.clientY - r.top - 32}px`;
      tip.innerHTML = `<strong>Net</strong><br>${escapeHtml(options.categoryLabel ? options.categoryLabel(categories[i]) : String(categories[i]))}: ${escapeHtml(fmtVal(nets[i]))} ${escapeHtml(unit)}`;
      tip.classList.add("show");
    });
    poly.addEventListener("mouseleave", () => { tip.classList.remove("show"); });
  });
}
// Pick a "nice" tick step that yields ~5-7 gridlines for the given absolute
// y-extent. Returns one of 1, 2, 2.5 or 5 times a power of ten.
function niceTickStep(maxAbs) {
  const target = maxAbs / 5;
  const pow = Math.pow(10, Math.floor(Math.log10(target || 1)));
  const norm = target / pow;
  let mult;
  if (norm < 1.5) mult = 1;
  else if (norm < 3) mult = 2;
  else if (norm < 4) mult = 2.5;
  else if (norm < 7) mult = 5;
  else mult = 10;
  return mult * pow;
}
// Column hierarchy for tabular result panes. Lower priority = earlier in the
// rendered table. Unknown columns fall into bucket 50 (between time and
// value). Identifiers come first, then time keys, then "config" attributes,
// then numeric values at the very end.
const COL_PRIORITY = {
  group: 1, name: 1, attribute: 1, component: 1, output: 1, outputId: 1, scenario: 1,
  tech: 2, activity: 3,
  sector: 5, subsector: 6, sector_kev: 7, category: 8, process_type: 9,
  node: 10, mode: 11, constraint: 12,
  termination_status: 13, solver: 14, solverVersion: 14, engine: 14,
  inputWorkbook: 15, solveMethod: 15, clustering_approach: 15,
  period: 20, year: 20, vintage: 21, periods: 22,
  time_index: 25, hour: 25, day: 25,
  hoursPer_day: 30, n_repDays: 30,
  coef: 80, use: 81,
  value: 90, price: 90, cost_MEUR: 90, "cost MEUR": 90,
  total: 91, total_sec: 92, solve_sec: 92, generation_sec: 92, dataRead_sec: 92,
  cluster_sec: 92, derive_sec: 92, queue_sec: 92, resultsWrite_sec: 92,
  objective: 93, n_rows: 95, n_cols: 95,
};
// Columns that hold a year-like integer (period, vintage, hour-index, etc.).
// They are rendered as plain digits with NO thousands separator so "2050"
// does not show up as "2,050" in the result tables.
const INT_COLS = new Set(["period", "year", "vintage", "time_index", "hour", "day", "hoursPer_day", "n_repDays"]);
function reorderColumns(cols) {
  return cols.map((c, i) => ({ c, i, p: COL_PRIORITY[c] ?? 50 }))
             .sort((a, b) => (a.p - b.p) || (a.i - b.i))
             .map(x => x.c);
}
function formatCell(col, v) {
  if (INT_COLS.has(col)) {
    const n = Number(v);
    return Number.isFinite(n) ? String(Math.round(n)) : (v ?? "");
  }
  return cell(v);
}
function renderTable(id, rows, limit=60) { const c=$(id); if (!c) return; if(!rows.length){ c.innerHTML=""; return; } const cols=reorderColumns(Object.keys(rows[0])); c.innerHTML=`<table><thead><tr>${cols.map(x=>`<th>${escapeHtml(x)}</th>`).join("")}</tr></thead><tbody>${rows.slice(0,limit).map(r=>`<tr>${cols.map(x=>`<td>${escapeHtml(formatCell(x, r[x]))}</td>`).join("")}</tr>`).join("")}</tbody></table>`; }
function cell(v) { return typeof v === "number" ? fmt(v) : (v ?? ""); }
function fmt(v) { const n=Number(v); if(!Number.isFinite(n)) return v===undefined||v===null?"":String(v); if(Math.abs(n)>=1000) return n.toLocaleString(undefined,{maximumFractionDigits:0}); if(Math.abs(n)>=1) return n.toLocaleString(undefined,{maximumFractionDigits:2}); return n.toLocaleString(undefined,{maximumFractionDigits:4}); }
function escapeHtml(v) { return String(v ?? "").replace(/[&<>'"]/g, ch => ({"&":"&amp;","<":"&lt;",">":"&gt;","'":"&#39;","\"":"&quot;"}[ch])); }