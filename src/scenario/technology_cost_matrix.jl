# =============================================================================
# scenario/technology_cost_matrix.jl -- CSV-derived technology cost exposure
# =============================================================================

using CSV
using DataFrames

function _technology_cost_csv_data(csv_path::AbstractString)
    isfile(csv_path) || throw(ArgumentError("Scenario results CSV not found: $csv_path"))
    raw = readlines(csv_path)
    length(raw) >= 3 || throw(ArgumentError("Scenario results CSV must contain two header rows and data."))
    header_with_ids = CSV.File(IOBuffer(join(raw[1:2], "\n")); header = 1)
    header_names = String.(propertynames(header_with_ids))
    id_values = collect(first(header_with_ids))
    data = CSV.read(IOBuffer(join(raw[1:end], "\n")), DataFrame;
                    header = 1, skipto = 3, stringtype = String)
    return data, header_names, id_values
end

function _technology_cost_matrix_data(csv_path::AbstractString)
    data, headers, ids = _technology_cost_csv_data(csv_path)
    scenario_col = findfirst(==("scenario_id"), headers)
    scenario_col === nothing && throw(ArgumentError("Scenario results CSV must contain scenario_id."))
    cost_columns = Dict{String,Symbol}()
    capacity_columns = Dict{String,Symbol}()
    for (index, header) in enumerate(headers)
        id = ids[index]
        ismissing(id) && continue
        tech_id = strip(String(id))
        isempty(tech_id) && continue
        if startswith(header, "capacity:techStock[")
            capacity_columns[tech_id] = Symbol(header)
        elseif !(header in ("scenario_id", "variant_id", "worker_id", "system_cost", "co2_price", "term_status")) && !startswith(header, "capacity:")
            cost_columns[tech_id] = Symbol(header)
        end
    end
    common = sort!(collect(intersect(keys(cost_columns), keys(capacity_columns))))
    isempty(common) && throw(ArgumentError("No matching technology cost/capacity IDs found in $csv_path."))
    scenario_ids = String.(data[!, Symbol("scenario_id")])
    matrix = DataFrame(candidate_scenario_id = scenario_ids)
    for evaluation_index in axes(data, 1)
        evaluation_id = scenario_ids[evaluation_index]
        values = Vector{Union{Missing,Float64}}(undef, length(scenario_ids))
        for candidate_index in axes(data, 1)
            total = 0.0
            valid = true
            for tech_id in common
                capacity = data[candidate_index, capacity_columns[tech_id]]
                cost = data[evaluation_index, cost_columns[tech_id]]
                if ismissing(capacity) || ismissing(cost)
                    valid = false
                    break
                end
                total += Float64(capacity) * Float64(cost)
            end
            values[candidate_index] = valid ? total : missing
        end
        matrix[!, Symbol(_matrix_column_name(evaluation_id))] = values
    end
    return matrix, common
end

"""
    create_technology_cost_matrix_from_csv(csv_path; output_path=nothing,
                                           overwrite=true)

Create a one-row-per-candidate scenario matrix from the downloaded Scenario
Space CSV. Column `j` evaluates the installed `techStock` capacities from
candidate scenario `i` using the selected technology costs from scenario `j`.
The second CSV header row supplies the technology IDs used for matching.
"""
function create_technology_cost_matrix_from_csv(csv_path::AbstractString;
                                                output_path::Union{Nothing,AbstractString} = nothing,
                                                overwrite::Bool = true)
    matrix, technology_ids = _technology_cost_matrix_data(csv_path)
    path = output_path === nothing ?
        joinpath(_robustness_matrix_dir(), splitext(basename(csv_path))[1] * "_technology_cost_matrix.csv") : String(output_path)
    mkpath(dirname(path))
    isfile(path) && !overwrite && throw(ArgumentError("File already exists: $path. Use overwrite=true."))
    CSV.write(path, matrix)
    return (path = abspath(path), matrix = matrix, technology_ids = technology_ids)
end

export create_technology_cost_matrix_from_csv
