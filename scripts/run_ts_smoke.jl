#!/usr/bin/env julia
# =============================================================================
# run_ts_smoke.jl — Phase 5/6 build-only smoke for the TS LP
#
# Reads default_data.xlsx, derives sets+params, runs temporal clustering
# with rd=25, builds the TS LP via `build_ts_lp!`, reports model size, and
# exits.  NO SOLVE.
#
# Usage:
#     julia --project=. scripts/run_ts_smoke.jl
# =============================================================================

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using IESA_J
using JuMP
using XLSX

const IJ_ROOT = normpath(joinpath(@__DIR__, ".."))
const DB_PATH = joinpath(IJ_ROOT, "data", "default_data.xlsx")

isfile(DB_PATH) || error("Database not found at $DB_PATH")

@info "run_ts_smoke.jl: reading database from $DB_PATH"
t0 = time()
md = IESA_J.read_data_cached(DB_PATH)
@info "read_data_cached done" elapsed_s = round(time() - t0, digits = 1)

# Limit to single 2050 period (matches IESA-Opt 1.0 small-run config)
md.sets.periods_solve = filter(p -> p == 2050, md.sets.periods_solve)
isempty(md.sets.periods_solve) && (push!(md.sets.periods_solve, 2050))
@info "periods_solve restricted to $(md.sets.periods_solve)"

# Configure TS clustering: rd=25
md.params.n_repDays            = 25
md.params.hoursPer_day_cluster = 24
md.params.clustering_approach  = :kmeans_avg

@info "derive_sets! + compute_derived_params!"
IESA_J.derive_sets!(md)
IESA_J.compute_derived_params!(md)

@info "build_temporal_clusters! (rd=$(md.params.n_repDays))"
t0 = time()
IESA_J.build_temporal_clusters!(md)
@info "clustering done" elapsed_s = round(time() - t0, digits = 1) n_repDays = md.params.n_repDays n_hours_cluster = length(md.sets.hours_cluster)

@info "build_ts_lp! (no optimizer)"
m = Model()
t0 = time()
vars = IESA_J.build_ts_lp!(m, md)
build_s = round(time() - t0, digits = 1)

n_rows = num_constraints(m; count_variable_in_set_constraints = false)
n_cols = num_variables(m)
@info "TS LP built" rows = n_rows cols = n_cols build_seconds = build_s

println("="^60)
println("TS LP BUILD COMPLETE")
println("  rows: $n_rows")
println("  cols: $n_cols")
println("  build_s: $build_s")
println("="^60)
