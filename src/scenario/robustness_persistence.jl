# =============================================================================
# scenario/robustness_persistence.jl -- append-safe scenario run store
# =============================================================================

using DuckDB
import DBInterface
using JSON3

const ROBUSTNESS_RUNS_DB = "scenario_robustness.duckdb"

function _robustness_runs_path(root::AbstractString = _repo_root())
    dir = joinpath(root, "Output_Batch", "scenario_robustness")
    mkpath(dir)
    return joinpath(dir, ROBUSTNESS_RUNS_DB)
end

function _ensure_robustness_schema!(db)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS scenario_runs (
            scenario_id VARCHAR PRIMARY KEY,
            campaign_id VARCHAR NOT NULL,
            variant_id INTEGER NOT NULL,
            run_timestamp VARCHAR NOT NULL,
            campaign_name VARCHAR NOT NULL,
            input_workbook VARCHAR NOT NULL,
            sampling_method VARCHAR NOT NULL,
            seed INTEGER NOT NULL,
            solver VARCHAR NOT NULL,
            mode VARCHAR NOT NULL,
            objective DOUBLE,
            term_status VARCHAR NOT NULL,
            primal_status VARCHAR NOT NULL,
            feasible BOOLEAN NOT NULL,
            error VARCHAR,
            runtime_seconds DOUBLE
        )
    """)
    DBInterface.execute(db, "ALTER TABLE scenario_runs ADD COLUMN IF NOT EXISTS input_workbook VARCHAR DEFAULT ''")
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS scenario_inputs (
            scenario_id VARCHAR NOT NULL,
            target_id INTEGER NOT NULL,
            label VARCHAR NOT NULL,
            field VARCHAR NOT NULL,
            indices_json VARCHAR NOT NULL,
            mutation_type VARCHAR NOT NULL,
            sampled_value DOUBLE NOT NULL,
            PRIMARY KEY (scenario_id, target_id)
        )
    """)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS scenario_designs (
            scenario_id VARCHAR NOT NULL,
            variable VARCHAR NOT NULL,
            variable_name VARCHAR NOT NULL,
            value DOUBLE NOT NULL,
            PRIMARY KEY (scenario_id, variable_name)
        )
    """)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS scenario_kpis (
            scenario_id VARCHAR NOT NULL,
            kpi VARCHAR NOT NULL,
            value DOUBLE,
            PRIMARY KEY (scenario_id, kpi)
        )
    """)
end

"""
    save_robustness_variant!(campaign_id, spec, samples, result; ...)

Append one completed Scenario Space variant to the persistent DuckDB store.
The exact JuMP indexed variable name is retained in `scenario_designs`, while
inputs are normalised by target and linked through the same scenario ID.
Existing IDs are skipped unless `overwrite=true`.
"""
function save_robustness_variant!(campaign_id::AbstractString,
                                  spec::ScenarioSpec,
                                  samples::AbstractMatrix,
                                  result::VariantResult;
                                  solver::AbstractString = "",
                                  mode::Symbol = :ts,
                                  input_workbook::AbstractString = "",
                                  runtime_seconds::Real = NaN,
                                  overwrite::Bool = false,
                                  path::Union{Nothing,AbstractString} = nothing)
    scenario_id = string(campaign_id, "_v", result.variant_id)
    db_path = path === nothing ? _robustness_runs_path() : String(path)
    mkpath(dirname(db_path))
    db = DuckDB.DB(db_path)
    try
        _ensure_robustness_schema!(db)
        DBInterface.execute(db, "BEGIN TRANSACTION")
        try
            existing = DBInterface.execute(db,
                "SELECT scenario_id FROM scenario_runs WHERE scenario_id = ?",
                [scenario_id]) |> DataFrame
            if !isempty(existing) && !overwrite
                DBInterface.execute(db, "ROLLBACK")
                return (path = abspath(db_path), scenario_id = scenario_id, inserted = false)
            end
            DBInterface.execute(db, "DELETE FROM scenario_inputs WHERE scenario_id = ?", [scenario_id])
            DBInterface.execute(db, "DELETE FROM scenario_designs WHERE scenario_id = ?", [scenario_id])
            DBInterface.execute(db, "DELETE FROM scenario_kpis WHERE scenario_id = ?", [scenario_id])
            DBInterface.execute(db, "DELETE FROM scenario_runs WHERE scenario_id = ?", [scenario_id])

            feasible = result.term_status in ("OPTIMAL", "LOCALLY_SOLVED", "ALMOST_OPTIMAL") &&
                       isfinite(result.objective)
            DBInterface.execute(db, """
                                INSERT INTO scenario_runs (
                                    scenario_id, campaign_id, variant_id, run_timestamp,
                                    campaign_name, input_workbook, sampling_method, seed,
                                    solver, mode, objective, term_status, primal_status,
                                    feasible, error, runtime_seconds
                                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [scenario_id, String(campaign_id), result.variant_id, string(now()),
                                    spec.name, String(input_workbook), String(spec.method), spec.seed,
                                    String(solver), String(mode),
                  isfinite(result.objective) ? result.objective : missing,
                  result.term_status, result.primal_status, feasible,
                  result.error === nothing ? missing : result.error,
                  isfinite(Float64(runtime_seconds)) ? Float64(runtime_seconds) : missing])

            row = min(result.variant_id, size(samples, 1))
            for (target_id, target) in enumerate(spec.targets)
                sampled_value = Float64(samples[row, target_id])
                indices_json = String(JSON3.write(string.(target.indices)))
                DBInterface.execute(db, "INSERT INTO scenario_inputs VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [scenario_id, target_id, target.label, String(target.field), indices_json,
                     String(target.type), sampled_value])
            end
            for design in result.design_values
                DBInterface.execute(db, "INSERT INTO scenario_designs VALUES (?, ?, ?, ?)",
                    [scenario_id, design.variable, design.variable_name, design.value])
            end
            DBInterface.execute(db, "INSERT INTO scenario_kpis VALUES (?, ?, ?)",
                [scenario_id, "co2_price", isfinite(result.co2_price) ? result.co2_price : missing])
            DBInterface.execute(db, "COMMIT")
        catch
            try DBInterface.execute(db, "ROLLBACK") catch end
            rethrow()
        end
        try DBInterface.execute(db, "CHECKPOINT") catch end
    finally
        DBInterface.close!(db)
        finalize(db)
        GC.gc(true)
    end
    return (path = abspath(db_path), scenario_id = scenario_id, inserted = true)
end

struct SavedScenarioRun
    scenario_id::String
    campaign_id::String
    variant_id::Int
    input_workbook::String
    inputs::Vector{LeafChange}
    objective::Union{Float64,Missing}
    term_status::String
    primal_status::String
    feasible::Bool
    designs::Vector{DesignValue}
end

function _robustness_index_value(value)
    text = String(value)
    parsed = tryparse(Int, text)
    parsed === nothing ? Symbol(text) : parsed
end

"""
    load_saved_scenario_runs(; path=nothing, include_incomplete=false)

Load completed scenario-optimal runs and validate that every included run has
inputs, an objective, and a complete long-lived design snapshot.
"""
function load_saved_scenario_runs(; path::Union{Nothing,AbstractString} = nothing,
                                  include_incomplete::Bool = false)
    db_path = path === nothing ? _robustness_runs_path() : String(path)
    isfile(db_path) || throw(ArgumentError("Scenario robustness database not found: $db_path"))
    db = DuckDB.DB(db_path)
    try
        runs = DBInterface.execute(db, "SELECT * FROM scenario_runs ORDER BY scenario_id") |> DataFrame
        inputs_df = DBInterface.execute(db, "SELECT * FROM scenario_inputs ORDER BY scenario_id, target_id") |> DataFrame
        designs_df = DBInterface.execute(db, "SELECT * FROM scenario_designs ORDER BY scenario_id, variable_name") |> DataFrame
        loaded = SavedScenarioRun[]
        for run in eachrow(runs)
            sid = String(run.scenario_id)
            input_rows = filter(r -> String(r.scenario_id) == sid, inputs_df)
            design_rows = filter(r -> String(r.scenario_id) == sid, designs_df)
            inputs = LeafChange[]
            for row in eachrow(input_rows)
                raw_indices = JSON3.read(String(row.indices_json))
                indices = Tuple(_robustness_index_value(x) for x in raw_indices)
                push!(inputs, LeafChange(Symbol(row.field), indices,
                                         Float64(row.sampled_value), Symbol(row.mutation_type)))
            end
            designs = [DesignValue(String(row.variable), String(row.variable_name), Float64(row.value))
                       for row in eachrow(design_rows)]
            complete = !ismissing(run.objective) && !isempty(inputs) &&
                       String(run.term_status) in ("OPTIMAL", "LOCALLY_SOLVED", "ALMOST_OPTIMAL") &&
                       !isempty(designs)
            complete || include_incomplete || continue
            push!(loaded, SavedScenarioRun(
                sid, String(run.campaign_id), Int(run.variant_id), String(run.input_workbook), inputs,
                run.objective, String(run.term_status), String(run.primal_status),
                Bool(run.feasible), designs))
        end
        isempty(loaded) && @warn "No complete scenario-optimal runs found" path = db_path
        return loaded
    finally
        DBInterface.close!(db)
        finalize(db)
        GC.gc(true)
    end
end

export DesignValue, save_robustness_variant!, SavedScenarioRun, load_saved_scenario_runs
