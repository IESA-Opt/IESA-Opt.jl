#!/usr/bin/env julia
# =============================================================================
# scripts/run_annual_smoke.jl
#
# Phase 2 smoke test — build + solve the annual LP (no flex, no hourly).
#
# Run from the repository root:
#   julia --project=. scripts/run_annual_smoke.jl
# =============================================================================

using IESA_J
using JuMP
using HiGHS
using Logging
import MathOptInterface as MOI

@info "Loading data"
xlsx_path = joinpath(@__DIR__, "..", "data", "default_data.xlsx")
if !isfile(xlsx_path)
    error("Input XLSX not found at $xlsx_path")
end

md = read_data(xlsx_path; periods = [2022, 2025, 2030, 2035, 2040, 2045, 2050])
derive_sets!(md)
compute_derived_params!(md)

@info "Data summary" n_periods=length(md.sets.periods_solve) n_tech=length(md.sets.technologies) n_tb=length(md.sets.tech_balancers) n_act=length(md.sets.activities) n_retro=length(md.params.retrofit_relations)

@info "Building annual LP"
optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => true, "log_to_console" => true)
rr, vars, m = solve_annual!(md, optimizer; out_dir = joinpath(@__DIR__, "..", "Output", "annual_smoke"), mode = :annual)

@info "Solve done" status=rr.termination_status objective=rr.objective_value rows=rr.n_rows cols=rr.n_cols solve_seconds=rr.solve_seconds

if rr.termination_status in ("OPTIMAL", "LOCALLY_SOLVED")
    @info "✓ Phase 2 smoke test PASSED"
    exit(0)
else
    @warn "Solve did not reach optimum; check log"
    exit(1)
end
