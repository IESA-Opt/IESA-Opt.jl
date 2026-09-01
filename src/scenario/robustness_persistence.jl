# =============================================================================
# scenario/robustness_persistence.jl -- append-safe scenario run store
# =============================================================================

using CSV
using DataFrames
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
            periods_json VARCHAR NOT NULL DEFAULT '[]',
            sampling_method VARCHAR NOT NULL,
            seed INTEGER NOT NULL,
            solver VARCHAR NOT NULL,
            mode VARCHAR NOT NULL,
            objective DOUBLE,
            term_status VARCHAR NOT NULL,
            primal_status VARCHAR NOT NULL,
            feasible BOOLEAN NOT NULL,
            worker_pid INTEGER,
            error VARCHAR,
            runtime_seconds DOUBLE
        )
    """)
    DBInterface.execute(db, "ALTER TABLE scenario_runs ADD COLUMN IF NOT EXISTS input_workbook VARCHAR DEFAULT ''")
    DBInterface.execute(db, "ALTER TABLE scenario_runs ADD COLUMN IF NOT EXISTS periods_json VARCHAR DEFAULT '[]'")
    DBInterface.execute(db, "ALTER TABLE scenario_runs ADD COLUMN IF NOT EXISTS worker_pid INTEGER")
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
                                  periods::AbstractVector{<:Integer} = Int[],
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
                                    campaign_name, input_workbook, periods_json, sampling_method, seed,
                                    solver, mode, objective, term_status, primal_status,
                                    feasible, worker_pid, error, runtime_seconds
                                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """, [scenario_id, String(campaign_id), result.variant_id, string(now()),
                                    spec.name, String(input_workbook), String(JSON3.write(Int.(periods))), String(spec.method), spec.seed,
                                    String(solver), String(mode),
                  isfinite(result.objective) ? result.objective : missing,
                  result.term_status, result.primal_status, feasible,
                  result.worker_pid,
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
    periods::Vector{Int}
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
            periods = try Int.(JSON3.read(String(run.periods_json))) catch; Int[] end
            push!(loaded, SavedScenarioRun(
                sid, String(run.campaign_id), Int(run.variant_id), String(run.input_workbook), periods, inputs,
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

function _flatten_csv_column_name(raw::AbstractString, fallback::AbstractString = "value")
    candidate = String(raw)
    candidate = replace(candidate, r"[^A-Za-z0-9_]+" => "_")
    candidate = replace(candidate, r"_+" => "_")
    candidate = strip(candidate, '_')
    if isempty(candidate)
        candidate = fallback
    end
    return lowercase(candidate)
end

function _flatten_robustness_rows(db_path::AbstractString)
    db = DuckDB.DB(db_path)
    try
        runs = DBInterface.execute(db, "SELECT * FROM scenario_runs ORDER BY variant_id") |> DataFrame
        inputs = DBInterface.execute(db, "SELECT * FROM scenario_inputs ORDER BY scenario_id, target_id") |> DataFrame
        designs = DBInterface.execute(db, "SELECT * FROM scenario_designs ORDER BY scenario_id, variable_name") |> DataFrame
        kpis = DBInterface.execute(db, "SELECT * FROM scenario_kpis ORDER BY scenario_id, kpi") |> DataFrame

        if isempty(runs)
            return DataFrame()
        end

        base_cols = [
            "scenario_id", "campaign_id", "variant_id", "run_timestamp", "campaign_name",
            "input_workbook", "sampling_method", "seed", "solver", "mode", "objective",
            "term_status", "primal_status", "feasible", "error", "runtime_seconds"
        ]

        input_names = String[]
        design_names = String[]
        kpi_names = String[]
        for row in eachrow(inputs)
            name = _flatten_csv_column_name(String(row.label), "input_value")
            if name ∉ input_names
                push!(input_names, name)
            end
        end
        for row in eachrow(designs)
            name = _flatten_csv_column_name(String(row.variable_name), "design_value")
            if name ∉ design_names
                push!(design_names, name)
            end
        end
        for row in eachrow(kpis)
            name = _flatten_csv_column_name(String(row.kpi), "kpi")
            if name ∉ kpi_names
                push!(kpi_names, name)
            end
        end

        rows = Dict{String,Any}[]
        for run in eachrow(runs)
            row = Dict{String,Any}()
            for col in base_cols
                row[col] = getproperty(run, Symbol(col))
            end
            sid = String(run.scenario_id)
            for input_row in eachrow(filter(r -> String(r.scenario_id) == sid, inputs))
                input_name = _flatten_csv_column_name(String(input_row.label), "input_value")
                row[input_name] = input_row.sampled_value
            end
            for design_row in eachrow(filter(r -> String(r.scenario_id) == sid, designs))
                design_name = _flatten_csv_column_name(String(design_row.variable_name), "design_value")
                row[design_name] = design_row.value
            end
            for kpi_row in eachrow(filter(r -> String(r.scenario_id) == sid, kpis))
                kpi_name = _flatten_csv_column_name(String(kpi_row.kpi), "kpi")
                row[kpi_name] = kpi_row.value
            end
            push!(rows, row)
        end

        if isempty(rows)
            return DataFrame()
        end

        flattened = DataFrame(rows)
        ordered = String[]
        for col in base_cols
            if col ∈ names(flattened)
                push!(ordered, col)
            end
        end
        for col in vcat(input_names, design_names, kpi_names)
            if col ∈ names(flattened) && col ∉ ordered
                push!(ordered, col)
            end
        end
        for col in names(flattened)
            if col ∉ ordered
                push!(ordered, col)
            end
        end
        return flattened[:, ordered]
    finally
        DBInterface.close!(db)
        finalize(db)
        GC.gc(true)
    end
end

"""
    flatten_robustness_runs_csv(; path=nothing, output_path=nothing, overwrite=false)

Write a one-row-per-scenario CSV export from the canonical DuckDB robustness
store. The DuckDB file remains the source of truth; this CSV is a derived,
analysis-friendly export.
"""
function flatten_robustness_runs_csv(; path::Union{Nothing,AbstractString} = nothing,
                                    output_path::Union{Nothing,AbstractString} = nothing,
                                    overwrite::Bool = false)
    db_path = path === nothing ? _robustness_runs_path() : String(path)
    isfile(db_path) || throw(ArgumentError("Scenario robustness database not found: $db_path"))
    out_path = output_path === nothing ? joinpath(dirname(db_path), "scenario_robustness_flat.csv") : String(output_path)
    mkpath(dirname(out_path))
    if isfile(out_path) && !overwrite
        throw(ArgumentError("Output file already exists: $out_path. Use overwrite=true."))
    end
    df = _flatten_robustness_rows(db_path)
    if isempty(df)
        # Create a blank CSV with just the canonical column order so callers can
        # still inspect the empty export without making the DB look missing.
        empty_df = DataFrame(
            scenario_id = String[],
            campaign_id = String[],
            variant_id = Int[],
            run_timestamp = String[],
            campaign_name = String[],
            input_workbook = String[],
            sampling_method = String[],
            seed = Int[],
            solver = String[],
            mode = String[],
            objective = Union{Missing,Float64}[],
            term_status = String[],
            primal_status = String[],
            feasible = Bool[],
            error = Union{Missing,String}[],
            runtime_seconds = Union{Missing,Float64}[]
        )
        CSV.write(out_path, empty_df)
        return abspath(out_path)
    end
    CSV.write(out_path, df)
    return abspath(out_path)
end

export DesignValue, save_robustness_variant!, SavedScenarioRun, load_saved_scenario_runs, flatten_robustness_runs_csv
