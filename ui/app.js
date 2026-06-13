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

// Plotly defaults shared by every chart in the dashboard. We strip the
// modebar buttons we don't use and force PNG export to 2x scale so saved
// images are crisp on hi-DPI displays.
const PLOTLY_CONFIG = {
  responsive: true,
  displaylogo: false,
  modeBarButtonsToRemove: ["lasso2d", "select2d"],
  toImageButtonOptions: { format: "png", scale: 2, filename: "iesa-opt-chart" },
};
function plotlyBaseLayout(extras = {}) {
  return Object.assign({
    margin: { t: 24, r: 20, b: 64, l: 80 },
    paper_bgcolor: "#fff",
    plot_bgcolor: "#fff",
    font: { family: "system-ui,Segoe UI,Roboto,sans-serif", size: 12, color: "#0f2436" },
    legend: { orientation: "h", x: 0, y: -0.2, yanchor: "top", xanchor: "left", font: { size: 11 } },
    hovermode: "closest",
    xaxis: { gridcolor: "#eef2f5", zerolinecolor: "#0f2436", tickfont: { size: 11 } },
    yaxis: { gridcolor: "#eef2f5", zerolinecolor: "#0f2436", tickfont: { size: 11 } },
  }, extras);
}
function plotlyRender(id, traces, layout, baseClass = "bar-chart plotly-chart", config = {}) {
  const c = $(id); if (!c) return;
  if (!traces || !traces.length) { plotlyEmpty(id, "No data available.", baseClass); return; }
  c.className = baseClass;
  c.classList.remove("empty-state");
  c.textContent = "";
  // Plotly.react reuses the chart instance for cheaper re-renders on filter
  // changes (legend toggles, From/To hour adjustments) but degrades to
  // newPlot when the container has not yet been initialised.
  Plotly.react(c, traces, layout || plotlyBaseLayout(), Object.assign({}, PLOTLY_CONFIG, config));
}
function plotlyEmpty(id, message, className = "bar-chart") {
  const c = $(id); if (!c) return;
  if (window.Plotly && c._fullLayout) Plotly.purge(c);
  c.className = `${className} empty-state`;
  c.textContent = message;
}

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
function collectRunConfig() { return { inputWorkbook: currentWorkbook(), periods:[...document.querySelectorAll("#periods input:checked")].map(i=>Number(i.value)), mode:$("timeSlicingToggle").checked ? "timeslice" : "full_hourly", hoursPerDay:currentHoursPerDay(), representativeDays:Number($("representativeDays").value), solver:$("solver").value, solveMethod:document.querySelector("input[name='solveMethod']:checked").value, threads:Number($("threads").value), clusteringApproach:$("clusteringApproach").value, extremePeriods:$("extremePeriods").checked, extremeDays:Number($("extremeDays").value), boundaryRamping:$("boundaryRamping").checked, hourlyReports:$("hourlyReports").checked, showViolations:$("showViolations").checked, outputMode:$("outputMode").value, outputName:$("outputName").value, constraintGroup:$("constraintGroup").value }; }
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
      autoCompareOrView();
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
    autoCompareOrView();
    return;
  }
  // Plain click — view this run AND make it the sole compare anchor.
  state.lastClickedOutputId = id;
  state.comparedOutputIds = [id];
  viewOutput(id);
}
// Decide what to render based on the current selection set: 0 selected does
// nothing (sidebar already up to date), 1 falls back to the single-run
// view, 2+ kicks off the comparison API request and hides the single-only
// panels. This is wired into Ctrl-click and Shift-click handlers so the
// user does not have to click the explicit "Compare selected" button.
function autoCompareOrView() {
  const ids = state.comparedOutputIds;
  if (ids.length >= 2) {
    compareSelectedOutputs();
    return;
  }
  if (ids.length === 1) {
    if (state.selectedOutputId !== ids[0]) viewOutput(ids[0]);
    else setComparisonMode(false);
  }
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
  setLoadingChart("systemCostsChart", "Loading comparison…");
  setLoadingChart("timingChart", "Loading timing…");
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
  renderStackedBars("systemCostsChart", costStacks, "MEUR");
  renderTable("systemCostsTable", totals, 80);
  renderTable("compareTable", timing, 50);
  renderTable("compareCostTable", costs, 160);
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
  // paint and remain responsive. Top-of-page panels render first, with a
  // visible pause before each subsequent panel so the cascade reads as
  // top-to-bottom even when individual renders are fast.
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
  // Disconnect any IntersectionObserver from a previous render so it
  // cannot fire mid-cascade and force a panel to render out of order.
  if (state.lazyResultsObserver) { state.lazyResultsObserver.disconnect(); state.lazyResultsObserver = null; }

  // Strictly sequential cascade: render stage i, paint a frame, wait
  // cascadeMs, then move to stage i+1. Two animation frames between the
  // call and the timer guarantee Plotly has finished its layout pass
  // before the next stage starts working.
  const cascadeMs = 250;
  const runStage = (i) => {
    if (myToken !== state.renderToken) return;
    if (i >= stages.length) return;
    try { stages[i](); } catch (err) { console.error(`Render stage ${i} failed`, err); }
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (myToken !== state.renderToken) return;
      setTimeout(() => runStage(i + 1), cascadeMs);
    }));
  };
  // Render the first stage on the next animation frame so the
  // metric-grid + sidebar paint we already issued can hit the screen
  // before Plotly starts reflowing the layout.
  requestAnimationFrame(() => runStage(0));
}
function setComparisonMode(active) {
  $("comparisonPanel").classList.toggle("hidden", !active);
  // In compare mode the single-run panels (Hourly Dispatch, Emissions,
  // Supply/Demand, CO2 Price, Activity Prices, Power Capacities) are
  // meaningless because their data refers to one run; hide them so the
  // page only shows comparison content.
  document.querySelectorAll(".results-main .single-only").forEach(el => el.classList.toggle("hidden", active));
}
function clearComparisonPanels() { setComparisonMode(false); $("compareStatus").textContent="Select outputs in the sidebar."; $("compareTable").innerHTML=""; $("compareCostTable").innerHTML=""; }
function setEmptyChart(id, message, className="bar-chart") { const c=$(id); if (!c) return; if (window.Plotly && c._fullLayout) Plotly.purge(c); c.className=`${className} empty-state`; c.textContent=message; }
function setLoadingChart(id, message="Loading…", className="bar-chart") {
  const c = $(id); if (!c) return;
  if (window.Plotly && c._fullLayout) Plotly.purge(c);
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
// Horizontal stacked bar chart. Each input row becomes a y-axis tick, with
// segment labels stacked across the x-axis. Plotly's barmode:'relative' is
// what makes negative segments fall left of zero rather than colliding with
// positives, which we rely on for cost stacks where some components (e.g.
// salvage) come back negative.
function renderStackedBars(id, rows, unit, className = "bar-chart plotly-chart compact-chart") {
  if (!rows || !rows.length) { plotlyEmpty(id, "No data available.", className.replace("plotly-chart", "").trim() || "bar-chart"); return; }
  const shown = rows.slice(0, 12);
  const rowLabels = shown.map(r => String(r.label || ""));
  // Preserve first-seen segment order so colors stay stable across renders.
  const segOrder = [];
  const segColor = new Map();
  shown.forEach(r => (r.segments || []).forEach(s => {
    if (!segColor.has(s.label)) { segOrder.push(s.label); segColor.set(s.label, s.color); }
  }));
  const traces = segOrder.map(label => {
    const x = shown.map(r => {
      const seg = (r.segments || []).find(s => s.label === label);
      return seg ? Number(seg.value || 0) : 0;
    });
    return {
      type: "bar", orientation: "h", name: label,
      x, y: rowLabels,
      marker: { color: segColor.get(label), line: { color: "#fff", width: 0.5 } },
      hovertemplate: `<b>%{fullData.name}</b><br>%{y}: %{x:.4g} ${unit}<extra></extra>`,
    };
  });
  const layout = plotlyBaseLayout({
    barmode: "relative",
    height: Math.max(220, 36 * rowLabels.length + 110),
    xaxis: { title: unit ? unit : "", gridcolor: "#eef2f5", zeroline: true, zerolinecolor: "#0f2436" },
    yaxis: { autorange: "reversed", automargin: true, gridcolor: "transparent" },
    legend: { orientation: "h", x: 0, y: -0.18, yanchor: "top", xanchor: "left", font: { size: 11 } },
  });
  plotlyRender(id, traces, layout, className);
}
// Single-series horizontal bar chart, used for the CO2 price chart and as
// a fallback for system costs when no component breakdown is available.
function renderBars(id, rows, labelFn, valueFn, unit) {
  if (!rows || !rows.length) { plotlyEmpty(id, "No data available.", "bar-chart"); return; }
  const shown = rows.slice(0, 12);
  const labels = shown.map(labelFn);
  const values = shown.map(valueFn);
  const colors = values.map(v => v < 0 ? "#ba3a2f" : "#1d5f8f");
  const trace = {
    type: "bar", orientation: "h",
    x: values, y: labels,
    marker: { color: colors },
    text: values.map(v => `${fmt(v)}${unit ? " " + unit : ""}`),
    textposition: "auto",
    hovertemplate: `%{y}<br><b>%{x:.4g}</b>${unit ? " " + unit : ""}<extra></extra>`,
  };
  const layout = plotlyBaseLayout({
    height: Math.max(180, 32 * labels.length + 90),
    xaxis: { title: unit || "", gridcolor: "#eef2f5", zeroline: true, zerolinecolor: "#0f2436" },
    yaxis: { autorange: "reversed", automargin: true, gridcolor: "transparent" },
    showlegend: false,
  });
  plotlyRender(id, [trace], layout, "bar-chart plotly-chart");
}
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
  if (!payload) { plotlyEmpty("hourlyDispatchChart", "No dispatch data available.", "profile-chart"); if (legend) legend.textContent=""; return; }
  const techs = payload.techs || [];
  const series = payload.series || [];
  const hours = payload.hours || [];
  if (!techs.length || !series.length || !hours.length) {
    const msg = payload.selectedNode
      ? `No dispatch data for node ${payload.selectedNode} in period ${payload.selectedPeriod || ""}.`
      : "No dispatch data available.";
    plotlyEmpty("hourlyDispatchChart", msg, "profile-chart");
    if (legend) legend.textContent="";
    return;
  }
  const hoursLen = hours.length;
  const fromHour = clampHour(state.dispatchFromHour, 1, hoursLen);
  const toHour = clampHour(state.dispatchToHour, fromHour, hoursLen);
  const sliceStart = fromHour - 1;
  const sliceEnd = toHour;
  const totalPoints = sliceEnd - sliceStart;
  if (totalPoints <= 0) { plotlyEmpty("hourlyDispatchChart", "Empty range \u2014 adjust From/To hours.", "profile-chart"); if (legend) legend.textContent=""; return; }

  // Downsample so the trace count stays light when zoomed out across 8760 h.
  // Plotly handles ~50k points easily but each tech becomes two traces (one
  // for the positive stack, one for the negative stack), so even ~22 techs
  // means ~44 traces \u00d7 8760 points = lots of layout work.
  const maxSamples = 2400;
  const step = Math.max(1, Math.floor(totalPoints / maxSamples));
  const xs = [];
  for (let i = 0; i < totalPoints; i += step) xs.push(fromHour + i);
  if (xs[xs.length - 1] !== fromHour + totalPoints - 1) xs.push(fromHour + totalPoints - 1);

  // Build per-tech traces split into positive and negative stack groups so
  // values stack symmetrically above and below zero.
  const traces = [];
  series.forEach((s, idx) => {
    const tech = String(s.tech);
    const color = chartColors[idx % chartColors.length];
    const slice = (s.values || []).slice(sliceStart, sliceEnd);
    const yPos = xs.map(h => Math.max(0, Number(slice[h - fromHour] || 0)));
    const yNeg = xs.map(h => Math.min(0, Number(slice[h - fromHour] || 0)));
    const hasPos = yPos.some(v => v > 0);
    const hasNeg = yNeg.some(v => v < 0);
    const visible = state.dispatchLegendOff.has(tech) ? "legendonly" : true;
    if (hasPos) {
      traces.push({
        type: "scatter", mode: "lines", name: tech, legendgroup: tech, showlegend: true,
        x: xs, y: yPos,
        stackgroup: "pos",
        fillcolor: color,
        line: { color: color, width: 0.6 },
        hovertemplate: `<b>${tech}</b><br>Hour %{x}: %{y:.4g}<extra></extra>`,
        visible,
      });
    }
    if (hasNeg) {
      traces.push({
        type: "scatter", mode: "lines", name: tech, legendgroup: tech, showlegend: !hasPos,
        x: xs, y: yNeg,
        stackgroup: "neg",
        fillcolor: color,
        line: { color: color, width: 0.6 },
        hovertemplate: `<b>${tech}</b><br>Hour %{x}: %{y:.4g}<extra></extra>`,
        visible,
      });
    }
  });

  const layout = plotlyBaseLayout({
    height: 420,
    xaxis: { title: "Hour of year", gridcolor: "#eef2f5", range: [fromHour, toHour] },
    yaxis: { title: "Dispatch", gridcolor: "#eef2f5", zeroline: true, zerolinecolor: "#0f2436", zerolinewidth: 1 },
    hovermode: "x unified",
    legend: { orientation: "v", x: 1.02, y: 1, xanchor: "left", yanchor: "top", font: { size: 11 } },
    margin: { t: 24, r: 200, b: 56, l: 80 },
  });
  plotlyRender("hourlyDispatchChart", traces, layout, "profile-chart plotly-chart");
  if (legend) legend.textContent = `${series.length} tech(s) \u00b7 hours ${fromHour}\u2013${toHour} of ${hoursLen} \u00b7 node ${payload.selectedNode || "(all)"} \u00b7 period ${payload.selectedPeriod || ""}`;

  // Persist the user's legend-toggle choices into state.dispatchLegendOff so
  // re-renders triggered by From/To changes keep the same series hidden.
  if (!c.__plotlyDispatchBound) {
    c.on("plotly_restyle", () => {
      try {
        const off = new Set();
        const seen = new Map();
        (c.data || []).forEach(t => {
          const isLegendOnly = t.visible === "legendonly";
          if (!seen.has(t.name)) seen.set(t.name, isLegendOnly);
          else if (!isLegendOnly) seen.set(t.name, false);
        });
        seen.forEach((isOff, name) => { if (isOff) off.add(name); });
        state.dispatchLegendOff = off;
      } catch (_) { /* ignore */ }
    });
    c.__plotlyDispatchBound = true;
  }
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
// black diamond marker for the per-category net total. Plotly's
// barmode:'relative' stacks negatives below zero and positives above so the
// chart axis stays anchored at zero. The Net marker is drawn as a separate
// scatter trace so it always overlays the stack.
function renderVerticalStackedBars(id, options) {
  const c = $(id); if (!c) return;
  const categories = options.categories || [];
  const allSeries = options.series || [];
  if (!categories.length || !allSeries.length) { plotlyEmpty(id, "No data available.", "vstack-chart"); return; }
  const xLabels = categories.map(cat => options.categoryLabel ? options.categoryLabel(cat) : String(cat));
  const unit = options.unit || "";
  const traces = allSeries.map(s => ({
    type: "bar",
    name: s.label,
    x: xLabels,
    y: (s.values || []).slice(),
    marker: { color: s.color, line: { color: "#fff", width: 0.6 } },
    hovertemplate: `<b>${escapeHtml(s.label)}</b><br>%{x}: %{y:.4g} ${unit}<extra></extra>`,
  }));
  if (options.showNet) {
    const nets = categories.map((_, i) => allSeries.reduce((sum, s) => sum + Number((s.values || [])[i] || 0), 0));
    traces.push({
      type: "scatter", mode: "markers",
      name: "Net",
      x: xLabels, y: nets,
      marker: { color: "#000", size: 11, symbol: "diamond", line: { color: "#fff", width: 1.2 } },
      hovertemplate: `<b>Net</b><br>%{x}: %{y:.4g} ${unit}<extra></extra>`,
    });
  }
  const layout = plotlyBaseLayout({
    barmode: "relative",
    height: 380,
    xaxis: { type: "category", gridcolor: "transparent", tickangle: 0 },
    yaxis: { title: unit, gridcolor: "#eef2f5", zeroline: true, zerolinecolor: "#0f2436", zerolinewidth: 1.2 },
    legend: { orientation: "h", x: 0, y: -0.15, yanchor: "top", xanchor: "left", font: { size: 11 } },
  });
  plotlyRender(id, traces, layout, "vstack-chart plotly-chart");
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