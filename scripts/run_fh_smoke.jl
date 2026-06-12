#!/usr/bin/env julia
# =============================================================================
# scripts/run_fh_smoke.jl
#
# Phase 3 BUILD smoke test — verify the full-hourly (FH) LP assembles cleanly.
#
# NO SOLVE. This script checks full-hourly model assembly only; production
# solves should use the dedicated run scripts with Gurobi.
#
# This script only confirms:
#   - data loads
#   - variables declare
#   - all hourly constraint families add without error
#   - JuMP reports row/col counts
#
# Run from the repository root:
#   julia --project=. scripts/run_fh_smoke.jl
# =============================================================================

using IESA_J
using JuMP
using Logging

@info "Loading data"
xlsx_path = joinpath(@__DIR__, "..", "data", "default_data.xlsx")
if !isfile(xlsx_path)
    error("Input XLSX not found at $xlsx_path")
end

# Single 2050 solve period for the build sanity check.
md = read_data(xlsx_path; periods = [2050])
derive_sets!(md)
compute_derived_params!(md)

@info "Data summary" n_hours=length(md.sets.hours) n_days=length(md.sets.days) n_periods=length(md.sets.periods_solve) n_tech=length(md.sets.technologies) n_tb=length(md.sets.tech_balancers) n_act=length(md.sets.activities)

@info "Building FH LP (no optimizer attached — pure model assembly)"
t_build = time()
m = Model()
vars = build_fh_lp!(m, md)
build_seconds = time() - t_build
n_rows = num_constraints(m; count_variable_in_set_constraints = false)
n_cols = num_variables(m)
@info "Build done" build_seconds n_rows n_cols

@info "FH build smoke passed — LP assembled cleanly."
exit(0)
