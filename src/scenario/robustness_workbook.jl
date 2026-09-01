# =============================================================================
# scenario/robustness_workbook.jl -- CSV-driven Excel robustness report
# =============================================================================

using CSV
using DataFrames
using XLSX
using Statistics

function _robustness_evaluations_from_csv(csv_path::AbstractString;
                                          cross_path::Union{Nothing,AbstractString} = nothing)
    scenario_ids = _scenario_ids_from_csv(csv_path)
    db_path = cross_path === nothing ? _cross_evaluation_path(nothing) : String(cross_path)
    rows = _cross_rows_from_db(db_path, scenario_ids)
    isempty(rows) && throw(ArgumentError("No cross-evaluation rows found for the scenarios in $csv_path."))
    return scenario_ids, rows
end

function _robustness_metrics(rows::DataFrame)
    required = ["candidate_design_id", "evaluation_future_id", "feasible", "objective_value",
                "absolute_regret", "relative_regret"]
    all(name in names(rows) for name in required) || throw(ArgumentError(
        "Cross-evaluation data is missing one of: $(join(required, ", "))"))
    metrics = DataFrame()
    candidates = sort!(unique(String.(rows.candidate_design_id)))
    metrics.candidate_design_id = candidates
    metrics.originating_future_id = [begin
        matches = rows[String.(rows.candidate_design_id) .== candidate, :originating_future_id]
        isempty(matches) ? "" : String(first(matches))
    end for candidate in candidates]
    metric_values = Dict{Symbol,Vector{Union{Missing,Float64}}}(
        :feasibility_rate => Union{Missing,Float64}[],
        :mean_objective => Union{Missing,Float64}[],
        :worst_objective => Union{Missing,Float64}[],
        :mean_absolute_regret => Union{Missing,Float64}[],
        :max_absolute_regret => Union{Missing,Float64}[],
        :p90_absolute_regret => Union{Missing,Float64}[],
        :p95_absolute_regret => Union{Missing,Float64}[],
        :mean_relative_regret => Union{Missing,Float64}[],
        :max_relative_regret => Union{Missing,Float64}[],
        :std_relative_regret => Union{Missing,Float64}[],
        :iqr_relative_regret => Union{Missing,Float64}[],
    )
    for candidate in candidates
        subset = rows[String.(rows.candidate_design_id) .== candidate, :]
        feasible = [Bool(value) for value in subset.feasible]
        objectives = [Float64(value) for value in subset.objective_value if value !== missing]
        absolute = [Float64(value) for value in subset.absolute_regret if value !== missing]
        relative = [Float64(value) for value in subset.relative_regret if value !== missing]
        push!(metric_values[:feasibility_rate], isempty(feasible) ? missing : mean(feasible))
        push!(metric_values[:mean_objective], isempty(objectives) ? missing : mean(objectives))
        push!(metric_values[:worst_objective], isempty(objectives) ? missing : maximum(objectives))
        push!(metric_values[:mean_absolute_regret], isempty(absolute) ? missing : mean(absolute))
        push!(metric_values[:max_absolute_regret], isempty(absolute) ? missing : maximum(absolute))
        push!(metric_values[:p90_absolute_regret], isempty(absolute) ? missing : quantile(absolute, 0.90))
        push!(metric_values[:p95_absolute_regret], isempty(absolute) ? missing : quantile(absolute, 0.95))
        push!(metric_values[:mean_relative_regret], isempty(relative) ? missing : mean(relative))
        push!(metric_values[:max_relative_regret], isempty(relative) ? missing : maximum(relative))
        push!(metric_values[:std_relative_regret], length(relative) < 2 ? (isempty(relative) ? missing : 0.0) : std(relative))
        push!(metric_values[:iqr_relative_regret], isempty(relative) ? missing : quantile(relative, 0.75) - quantile(relative, 0.25))
    end
    for (name, values) in metric_values
        metrics[!, name] = values
    end
    return metrics
end

"""
    create_robustness_workbook_from_csv(csv_path; cross_path=nothing,
                                        output_path=nothing, overwrite=true)

Build one Excel workbook from a downloaded Scenario Space CSV and the
persistent cross-evaluation database. The workbook contains:

* `Evaluations`: one row per candidate-design/evaluation-future pair.
* `Matrix`: objective values with candidate designs as rows and futures as columns.
* `Metrics`: robustness metrics per candidate design.

The CSV defines the scenario universe; cross-evaluation rows provide the actual
N x N results. No model evaluation is repeated by this reporting function.
"""
function create_robustness_workbook_from_csv(csv_path::AbstractString;
                                             cross_path::Union{Nothing,AbstractString} = nothing,
                                             output_path::Union{Nothing,AbstractString} = nothing,
                                             overwrite::Bool = true)
    scenario_ids, evaluations = _robustness_evaluations_from_csv(csv_path; cross_path = cross_path)
    matrix = robustness_matrix(evaluations; kind = :objective)
    metrics = _robustness_metrics(evaluations)
    path = output_path === nothing ?
        joinpath(_robustness_matrix_dir(), splitext(basename(csv_path))[1] * "_robustness.xlsx") : String(output_path)
    mkpath(dirname(path))
    isfile(path) && !overwrite && throw(ArgumentError("File already exists: $path. Use overwrite=true."))
    XLSX.writetable(path,
        "Evaluations" => evaluations,
        "Matrix" => matrix,
        "Metrics" => metrics,
        overwrite = true)
    return (path = abspath(path), scenario_ids = scenario_ids,
            evaluations = evaluations, matrix = matrix, metrics = metrics)
end

export create_robustness_workbook_from_csv
