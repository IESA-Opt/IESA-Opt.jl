#!/usr/bin/env julia
# =============================================================================
# scripts/bench_lp_names.jl
#
# Benchmark the impact of `set_string_names_on_creation(model, false)` on
# IESA-Opt LP **generation** (build) time and resident memory.
#
# Two modes are measured (default = full-hourly, single 2050 period):
#   1. names ON  — baseline (every @variable / @constraint stores its
#                  base_name string in the model's name dictionary)
#   2. names OFF — production setting via `apply_lp_generation_speedups!`
#
# For each mode we report:
#   * build_seconds       — wall-clock time of `build_fh_lp!`
#   * model_bytes         — Base.summarysize(model) after build (RAM held by
#                           the JuMP model object, including constraint /
#                           variable refs and the name dict)
#   * peak_proc_bytes     — process working-set after GC.gc() (Windows
#                           Process.WorkingSet64); upper bound on RSS
#                           observable from outside the process
#   * n_rows, n_cols      — sanity check that both modes build the same LP
#
# Run from the repo root:
#     julia --project=. scripts/bench_lp_names.jl
#
# Notes:
#   - Fresh `Model()` per mode; data is loaded once and reused.
#   - We deliberately run names OFF first (warms the JIT) then names ON
#     (also warm), then names OFF again to confirm reproducibility. The
#     printed summary uses the second names-OFF run so JIT-cold time is
#     not attributed to the speedup.
#   - No optimizer attached — this isolates JuMP/MOI assembly cost from
#     anything Gurobi does.
# =============================================================================

using IESAOpt
using JuMP
using Printf
using Logging

# Reduce log noise so the timing printout dominates the output.
Logging.global_logger(Logging.ConsoleLogger(stderr, Logging.Warn))

const IJ_ROOT  = normpath(joinpath(@__DIR__, ".."))
const DB_PATH  = joinpath(IJ_ROOT, "data", "default_data.xlsx")
const PERIOD   = 2050

isfile(DB_PATH) || error("Database not found at $DB_PATH")

println("="^72)
println("LP generation benchmark: names ON vs names OFF (full-hourly, $(PERIOD))")
println("="^72)

println("\n[1/3] Loading + deriving data once …")
t0 = time()
md = read_data(DB_PATH; periods = [PERIOD])
derive_sets!(md)
compute_derived_params!(md)
println(@sprintf("       data ready in %.2f s", time() - t0))
println(@sprintf("       hours=%d  days=%d  tech=%d  tb=%d",
                  length(md.sets.hours), length(md.sets.days),
                  length(md.sets.technologies), length(md.sets.tech_balancers)))

# -------------------------------------------------------------------------
# Helper: snapshot the OS-reported working-set bytes (Windows-friendly).
# -------------------------------------------------------------------------
function _proc_rss_bytes()
    try
        # Sys.maxrss is monotonically non-decreasing across the lifetime of
        # the Julia process (high-water mark of resident set in bytes).
        return Sys.maxrss()
    catch
        return 0
    end
end

# -------------------------------------------------------------------------
# Run a single FH build with the given naming policy.
# -------------------------------------------------------------------------
function bench_one(label::String; keep_names::Bool)
    GC.gc()
    GC.gc()
    rss_before = _proc_rss_bytes()
    alloc_before = Base.gc_bytes()

    m = Model()
    IESAOpt.apply_lp_generation_speedups!(m; keep_names = keep_names)

    t0 = time()
    build_fh_lp!(m, md)
    build_s = time() - t0

    n_rows = num_constraints(m; count_variable_in_set_constraints = false)
    n_cols = num_variables(m)

    GC.gc()
    GC.gc()
    rss_after  = _proc_rss_bytes()
    alloc_after = Base.gc_bytes()

    model_bytes = try
        Base.summarysize(m)
    catch
        0
    end

    println()
    println("---- $label (keep_names = $keep_names) ----")
    println(@sprintf("  rows                : %d",        n_rows))
    println(@sprintf("  cols                : %d",        n_cols))
    println(@sprintf("  build_seconds       : %.2f s",    build_s))
    println(@sprintf("  model summarysize   : %.1f MB",   model_bytes / 2^20))
    println(@sprintf("  Sys.maxrss (HWM)    : %.1f MB",   rss_after / 2^20))
    println(@sprintf("  Δ Sys.maxrss        : %+.1f MB",  (rss_after - rss_before) / 2^20))
    println(@sprintf("  Δ gc_bytes          : %+.1f MB",  (alloc_after - alloc_before) / 2^20))

    m = nothing
    GC.gc()
    GC.gc()
    return (label = label, keep_names = keep_names,
            rows = n_rows, cols = n_cols,
            build_s = build_s, model_bytes = model_bytes,
            rss_after = rss_after,
            d_rss = rss_after - rss_before,
            d_alloc = alloc_after - alloc_before)
end

println("\n[2/3] Warm-up run (JIT) — names OFF")
_ = bench_one("warmup_off"; keep_names = false)

println("\n[3/3] Benchmark runs")
res_on  = bench_one("names ON  (baseline)";        keep_names = true)
res_off = bench_one("names OFF (speedup applied)"; keep_names = false)

# Summary
function _fmt_pct(a, b)
    b == 0 && return "n/a"
    return @sprintf("%+.1f%%", 100 * (a - b) / b)
end

println()
println("="^72)
println("SUMMARY")
println("="^72)
println(@sprintf("                          %-20s %-20s   %-10s",
                  "names ON (baseline)", "names OFF (new)", "Δ"))
println(@sprintf("  build_seconds         : %-20.2f %-20.2f   %s",
                  res_on.build_s, res_off.build_s,
                  _fmt_pct(res_off.build_s, res_on.build_s)))
println(@sprintf("  model summarysize MB  : %-20.1f %-20.1f   %s",
                  res_on.model_bytes / 2^20,
                  res_off.model_bytes / 2^20,
                  _fmt_pct(res_off.model_bytes, res_on.model_bytes)))
println(@sprintf("  Sys.maxrss (HWM) MB   : %-20.1f %-20.1f   %s",
                  res_on.rss_after / 2^20,
                  res_off.rss_after / 2^20,
                  _fmt_pct(res_off.rss_after, res_on.rss_after)))
println(@sprintf("  rows / cols (sanity)  : %d / %d  vs  %d / %d",
                  res_on.rows, res_on.cols, res_off.rows, res_off.cols))
println()
println("Negative Δ = improvement (faster / less RAM).")
println("Sys.maxrss is a process-wide high-water mark, so the benchmark")
println("order matters — we run names ON first to give it the lowest HWM")
println("baseline; if names OFF still reports a smaller per-run model")
println("summarysize the speedup is real.")
