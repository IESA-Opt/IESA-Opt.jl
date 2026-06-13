#!/usr/bin/env julia
# =============================================================================
# scripts/bench_lp_names_ts.jl
#
# Time-slice (TS) variant of `bench_lp_names.jl`.  Measures the impact of
# `set_string_names_on_creation(model, false)` on TS LP generation for two
# rep-day counts (defaults: 30 and 120), single 2050 period.
#
# Honours `IESA_OPT_KEEP_NAMES=1` to force names ON globally (only useful
# when comparing to a baseline outside this script).
#
# Run from the repo root:
#     julia --project=. scripts/bench_lp_names_ts.jl
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
const RD_LIST  = [30, 120]   # representative-day counts to benchmark

isfile(DB_PATH) || error("Database not found at $DB_PATH")

println("="^72)
println("LP generation benchmark — TIME SLICES")
println("Names ON vs names OFF, period $(PERIOD), rep-days = $(RD_LIST)")
println("="^72)

println("\n[step 1] Loading + deriving data (once) …")
t0 = time()
md_base = read_data(DB_PATH; periods = [PERIOD])
derive_sets!(md_base)
compute_derived_params!(md_base)
println(@sprintf("       data ready in %.2f s", time() - t0))
println(@sprintf("       hours=%d  days=%d  tech=%d  tb=%d",
                  length(md_base.sets.hours), length(md_base.sets.days),
                  length(md_base.sets.technologies),
                  length(md_base.sets.tech_balancers)))

# -------------------------------------------------------------------------
# Build a fresh ModelData copy with the requested rep-day count and run
# clustering. Returns the ready-to-build md.
# -------------------------------------------------------------------------
function _prepare_ts(rd::Int)
    md = deepcopy(md_base)
    md.params.n_repDays            = rd
    md.params.hoursPer_day_cluster = 24
    md.params.clustering_approach  = :kmeans_avg
    derive_sets!(md)
    compute_derived_params!(md)
    t0 = time()
    IESAOpt.build_temporal_clusters!(md)
    cluster_s = time() - t0
    return md, cluster_s
end

# -------------------------------------------------------------------------
# Build a single TS LP with the requested name policy.
# -------------------------------------------------------------------------
function _bench_one(md, label::String; keep_names::Bool)
    GC.gc(); GC.gc()
    rss_before  = Sys.maxrss()
    alloc_before = Base.gc_bytes()

    m = Model()
    IESAOpt.apply_lp_generation_speedups!(m; keep_names = keep_names)

    t0 = time()
    IESAOpt.build_ts_lp!(m, md)
    build_s = time() - t0

    n_rows = num_constraints(m; count_variable_in_set_constraints = false)
    n_cols = num_variables(m)

    GC.gc(); GC.gc()
    rss_after  = Sys.maxrss()
    alloc_after = Base.gc_bytes()

    model_bytes = try
        Base.summarysize(m)
    catch
        0
    end

    println()
    println("---- $label  (keep_names = $keep_names) ----")
    println(@sprintf("  rows                : %d",        n_rows))
    println(@sprintf("  cols                : %d",        n_cols))
    println(@sprintf("  build_seconds       : %.2f s",    build_s))
    println(@sprintf("  model summarysize   : %.1f MB",   model_bytes / 2^20))
    println(@sprintf("  Sys.maxrss (HWM)    : %.1f MB",   rss_after / 2^20))
    println(@sprintf("  Δ Sys.maxrss        : %+.1f MB",  (rss_after - rss_before) / 2^20))
    println(@sprintf("  Δ gc_bytes          : %+.1f MB",  (alloc_after - alloc_before) / 2^20))

    m = nothing
    GC.gc(); GC.gc()
    return (label = label, keep_names = keep_names,
            rows = n_rows, cols = n_cols,
            build_s = build_s, model_bytes = model_bytes,
            rss_after = rss_after,
            d_rss = rss_after - rss_before)
end

function _fmt_pct(a, b)
    b == 0 && return "n/a"
    return @sprintf("%+.1f%%", 100 * (a - b) / b)
end

# -------------------------------------------------------------------------
# JIT warm-up (smallest case, names OFF).  We do this once so the first
# real timing isn't dominated by precompilation.
# -------------------------------------------------------------------------
println("\n[step 2] Warm-up: TS rd=$(first(RD_LIST)), names OFF …")
md_warm, _ = _prepare_ts(first(RD_LIST))
_ = _bench_one(md_warm, "warmup (rd=$(first(RD_LIST)))"; keep_names = false)
md_warm = nothing
GC.gc(); GC.gc()

# -------------------------------------------------------------------------
# Real benchmark: ON then OFF for each rep-day count.
# -------------------------------------------------------------------------
results = NamedTuple[]
for rd in RD_LIST
    println("\n" * "="^72)
    println("Benchmark   rep-days = $(rd)")
    println("="^72)

    md, cluster_s = _prepare_ts(rd)
    println(@sprintf("  clustering done in %.2f s  (n_repDays=%d, hours_cluster=%d)",
                      cluster_s, length(md.sets.repDays),
                      length(md.sets.hours_cluster)))

    r_on  = _bench_one(md, "rd=$(rd)  names ON";  keep_names = true)
    r_off = _bench_one(md, "rd=$(rd)  names OFF"; keep_names = false)
    push!(results, (rd = rd, on = r_on, off = r_off,
                    cluster_s = cluster_s,
                    hours_cluster = length(md.sets.hours_cluster)))
    md = nothing
    GC.gc(); GC.gc()
end

# -------------------------------------------------------------------------
# Summary table
# -------------------------------------------------------------------------
println()
println("="^88)
println("SUMMARY (Time-slice LP generation, period $(PERIOD))")
println("="^88)
@printf("%4s %8s %10s %10s %12s | %10s %10s %12s | %8s %8s\n",
        "rd", "h_clust", "rows",  "cols",
        "build_ON_s",
        "build_OFF_s",  "Δbuild",
        "Δsumsize",
        "sum_ON",       "sum_OFF")
println("-"^88)
for r in results
    @printf("%4d %8d %10d %10d %12.2f | %10.2f %10s %12s | %8.0f %8.0f\n",
            r.rd, r.hours_cluster, r.on.rows, r.on.cols,
            r.on.build_s,
            r.off.build_s,
            _fmt_pct(r.off.build_s, r.on.build_s),
            _fmt_pct(r.off.model_bytes, r.on.model_bytes),
            r.on.model_bytes / 2^20,
            r.off.model_bytes / 2^20)
end
println()
println("Δbuild / Δsumsize: percentage change relative to names-ON baseline.")
println("sum_ON / sum_OFF: model summarysize in MB (Base.summarysize).")
