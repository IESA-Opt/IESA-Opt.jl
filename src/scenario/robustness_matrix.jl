# =============================================================================
# scenario/robustness_matrix.jl -- materialise cross-scenario matrices
# =============================================================================

using CSV
using DataFrames

const ROBUSTNESS_MATRIX_DIR = "scenario_robustness"

function _robustness_matrix_dir()
    dir = joinpath(_repo_root(), "Output_Batch", ROBUSTNESS_MATRIX_DIR)
    mkpath(dir)
    return dir
end

function _matrix_value_column(kind::Symbol)
    kind === :objective && return :objective_value
    kind === :absolute_regret && return :absolute_regret
    kind === :relative_regret && return :relative_regret
    kind === :feasible && return :feasible
    throw(ArgumentError("Unknown matrix kind $(repr(kind)). Use :objective, :absolute_regret, :relative_regret, or :feasible."))
end

"""
    robustness_matrix(rows; kind=:objective) -> DataFrame

Pivot long-format cross-evaluation rows into an N x N matrix. Rows are
candidate designs and columns are evaluation futures. Missing or infeasible
cells remain missing, except for `kind=:feasible`, which uses `false`.
"""
function robustness_matrix(rows::DataFrame; kind::Symbol = :objective)
    required = ["candidate_design_id", "originating_future_id", "evaluation_future_id", String(_matrix_value_column(kind))]
    all(name in names(rows) for name in required) || throw(ArgumentError(
        "Cross-evaluation data is missing one of: $(join(required, ", "))"))
    candidates = sort!(unique(String.(rows.candidate_design_id)))
    futures = sort!(unique(String.(rows.evaluation_future_id)))
    matrix = DataFrame(candidate_design_id = candidates,
                       originating_future_id = [begin
                           matches = rows[rows.candidate_design_id .== candidate, :originating_future_id]
                           isempty(matches) ? "" : String(first(matches))
                       end for candidate in candidates])
    value_column = _matrix_value_column(kind)
    for future in futures
        column = Symbol(_matrix_column_name(future))
        values = Vector{Union{Missing,Float64}}(undef, length(candidates))
        for (i, candidate) in enumerate(candidates)
            matches = rows[(String.(rows.candidate_design_id) .== candidate) .&
                           (String.(rows.evaluation_future_id) .== future), value_column]
            if isempty(matches)
                values[i] = kind === :feasible ? 0.0 : missing
            else
                raw = first(matches)
                values[i] = kind === :feasible ? (raw === missing ? 0.0 : (Bool(raw) ? 1.0 : 0.0)) :
                             (raw === missing ? missing : Float64(raw))
            end
        end
        matrix[!, column] = values
    end
    return matrix
end

function _matrix_column_name(value::AbstractString)
    clean = replace(value, r"[^A-Za-z0-9_]+" => "_")
    clean = replace(clean, r"_+" => "_")
    clean = strip(clean, '_')
    isempty(clean) ? "future" : clean
end

"""
    write_robustness_matrices(rows; output_dir=nothing, overwrite=false)

Write objective, absolute-regret, relative-regret, and feasibility matrices as
separate CSV files. The canonical long-format DuckDB data remains unchanged.
"""
function write_robustness_matrices(rows::DataFrame;
                                    output_dir::Union{Nothing,AbstractString} = nothing,
                                    overwrite::Bool = false)
    dir = output_dir === nothing ? _robustness_matrix_dir() : String(output_dir)
    mkpath(dir)
    outputs = Dict{Symbol,String}()
    for kind in (:objective, :absolute_regret, :relative_regret, :feasible)
        path = joinpath(dir, string(kind, "_matrix.csv"))
        isfile(path) && !overwrite && throw(ArgumentError("File already exists: $path. Use overwrite=true."))
        CSV.write(path, robustness_matrix(rows; kind = kind))
        outputs[kind] = abspath(path)
    end
    return outputs
end

function _scenario_ids_from_csv(path::AbstractString)
    isfile(path) || throw(ArgumentError("Scenario CSV not found: $path"))
    csv = CSV.read(path, DataFrame; stringtype = String)
    "scenario_id" in names(csv) || throw(ArgumentError("Scenario CSV must contain a scenario_id column."))
    ids = String[]
    for value in csv.scenario_id
        ismissing(value) && continue
        text = strip(String(value))
        isempty(text) || text in ids || push!(ids, text)
    end
    isempty(ids) && throw(ArgumentError("Scenario CSV contains no scenario IDs."))
    return ids
end

function _cross_rows_from_db(path::AbstractString, scenario_ids::Vector{String})
    isfile(path) || throw(ArgumentError("Cross-evaluation database not found: $path. Run the cross-scenario evaluation first."))
    db = DuckDB.DB(path; readonly = true)
    try
        rows = DBInterface.execute(db, "SELECT * FROM cross_evaluations") |> DataFrame
        wanted = Set(scenario_ids)
        keep = [String(row.candidate_design_id) in wanted && String(row.evaluation_future_id) in wanted for row in eachrow(rows)]
        return rows[keep, :]
    finally
        DBInterface.close!(db)
        finalize(db)
        GC.gc()
    end
end

"""
    create_robustness_matrix_from_csv(csv_path; cross_path=nothing,
                                      output_dir=nothing, overwrite=false)

Build matrix CSVs for exactly the scenarios listed in a downloaded Scenario
Space CSV. The CSV supplies the scenario/design universe and ordering; the
cross-evaluation DuckDB supplies the off-diagonal performance cells. This
function never substitutes original scenario costs for missing cross cells.
"""
function create_robustness_matrix_from_csv(csv_path::AbstractString;
                                           cross_path::Union{Nothing,AbstractString} = nothing,
                                           output_dir::Union{Nothing,AbstractString} = nothing,
                                           overwrite::Bool = true)
    scenario_ids = _scenario_ids_from_csv(csv_path)
    db_path = cross_path === nothing ? _cross_evaluation_path(nothing) : String(cross_path)
    rows = _cross_rows_from_db(db_path, scenario_ids)
    paths = write_robustness_matrices(rows; output_dir = output_dir, overwrite = overwrite)
    return (rows = rows, scenario_ids = scenario_ids, paths = paths)
end

"""
    create_robustness_matrix(; scenario_path=nothing, cross_path=nothing,
                             output_dir=nothing, overwrite=false, kwargs...)

Load the persistent scenario-optimal runs, resume or complete the N x N
cross-evaluation, and write matrix CSVs in the robustness output folder.
Already completed candidate/future pairs are skipped by the underlying
cross-evaluation database.
"""
function create_robustness_matrix(; scenario_path::Union{Nothing,AbstractString} = nothing,
                                   cross_path::Union{Nothing,AbstractString} = nothing,
                                   output_dir::Union{Nothing,AbstractString} = nothing,
                                   overwrite::Bool = false,
                                   kwargs...)
    rows = run_cross_scenario_robustness(; scenario_path = scenario_path,
                                         cross_path = cross_path,
                                         overwrite = overwrite,
                                         kwargs...)
    paths = write_robustness_matrices(rows; output_dir = output_dir, overwrite = overwrite)
    return (rows = rows, paths = paths)
end

export robustness_matrix, write_robustness_matrices, create_robustness_matrix
export create_robustness_matrix_from_csv
