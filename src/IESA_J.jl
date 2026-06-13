"""
    IESA_J

IESA-Opt 2.0 / IESA-Opt.jl, the Julia/JuMP implementation of the IESA-Opt 1.0 formulation.

The package exposes data loading, clustering, JuMP model construction, solver
configuration, and result-writing helpers for IESA-Opt.jl.
"""
module IESA_J

using JuMP
using DataFrames
using XLSX
using CSV
using Clustering
using Statistics
using LinearAlgebra
using SparseArrays
using Printf
using Random
using Dates
using Logging
import MathOptInterface as MOI

# Solver backends (loaded lazily — Gurobi requires a valid license + GUROBI_HOME)
using HiGHS
try
    @eval using Gurobi
catch err
    @warn "Gurobi.jl not available — Gurobi-based runs will fail. Use highs_optimizer() instead." err=err
end

# Parquet2 is still used for legacy cluster-map inputs; DuckDB is used by the UI runtime cache and result database.

# ---------------------------------------------------------------------------
# Core types
include("types.jl")

# ---------------------------------------------------------------------------
# Phase 1: data layer
include("data_reading.jl")
include("data_cache.jl")
include("sets.jl")
include("parameters.jl")
include("data_writing.jl")

# ---------------------------------------------------------------------------
# Solver wiring (Phase 7 production defaults)
include("solver_settings.jl")

# ---------------------------------------------------------------------------
# Phase 2+: model assembly (skeleton includes; bodies land per phase)
include("model/variables.jl")
include("model/stock.jl")
include("model/balance.jl")
include("model/objective.jl")
# Phase 3: full-hourly (FH) constraint families — single consolidated module
include("model/hourly.jl")
# Phase 5/6: time-slice (TS) constraint families
include("model/ts.jl")
# Phase 4 (new): infrastructure-volume + policy / regulatory constraints
include("model/infrastructure.jl")
include("model/policy.jl")
include("model/cyclic_closures.jl")
# include("model/capacity.jl")
# include("model/ramping.jl")
# include("model/emissions.jl")
# include("model/shedding.jl")
# include("model/chp.jl")
# include("model/storage.jl")
# include("model/backlog.jl")
# include("model/reservoir.jl")
# include("model/gasbuffer.jl")
# include("model/interconnect.jl")
# include("model/ts_extras.jl")

# ---------------------------------------------------------------------------
# Phase 5+: clustering
include("clustering.jl")

# ---------------------------------------------------------------------------
# Orchestration (Phase 2+)
include("solve.jl")
# include("postprocess.jl")
include("writers.jl")
include("ui_server.jl")
# include("sweeps.jl")

# ---------------------------------------------------------------------------
# Exports
export ModelSets, ModelParams, ModelData, RunResult
export read_data, derive_sets!, compute_derived_params!
export read_data_cached, clear_data_cache
export compute_temporal_helpers!, compute_period_indicators!
export compute_financial_params!, compute_investment_matrices!
export compute_activity_balances!, compute_chp_eps!, compute_activity_indicators!
export compute_decom_planned_sel!, compute_flex_loss_split!
export compute_emission_target_aggregates!
export compute_tech_activity!, init_policy_targets!
export write_sets_dump, write_params_dump, write_run_summary, write_run_statistics
export default_gurobi_attributes, default_highs_attributes
export gurobi_optimizer, highs_optimizer, apply_solver_attributes!
# Phase 2: annual LP
export AnnualVars, add_annual_variables!
export add_stock_constraints!, add_balance_constraints!, add_objective!
export build_annual_lp!, solve_annual!, extract_annual_results
# Phase 3: full-hourly LP
export add_hourly_variables!, add_hourly_constraints!
export build_fh_lp!
# Phase 5/6: time-slice LP
export build_temporal_clusters!
export add_ts_variables!, add_ts_constraints!
export build_ts_lp!
# Phase 4 (new): infrastructure / policy / cyclic closures
export add_infrastructure_constraints!
export add_policy_constraints!
export add_cyclic_closures!
# Phase 7: writers
export write_parquet_results, write_duckdb_results
export serve_ui!
# Phase 7+: export sweep_ts_postfix

end # module
