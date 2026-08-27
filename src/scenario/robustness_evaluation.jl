# =============================================================================
# scenario/robustness_evaluation.jl -- resumable cross-scenario evaluation
# =============================================================================

const ROBUSTNESS_CROSS_DB = "cross_evaluations.duckdb"

function _cross_evaluation_path(path::Union{Nothing,AbstractString})
    path !== nothing && return String(path)
    dir = joinpath(_repo_root(), "Output_Batch", "scenario_robustness")
    mkpath(dir)
    return joinpath(dir, ROBUSTNESS_CROSS_DB)
end

function _ensure_cross_schema!(db)
    DBInterface.execute(db, """
        CREATE TABLE IF NOT EXISTS cross_evaluations (
            candidate_design_id VARCHAR NOT NULL,
            originating_future_id VARCHAR NOT NULL,
            evaluation_future_id VARCHAR NOT NULL,
            feasible BOOLEAN NOT NULL,
            solver_status VARCHAR NOT NULL,
            primal_status VARCHAR NOT NULL,
            objective_value DOUBLE,
            optimal_objective_evaluation_future DOUBLE,
            absolute_regret DOUBLE,
            relative_regret DOUBLE,
            co2_price DOUBLE,
            error VARCHAR,
            evaluated_at VARCHAR NOT NULL,
            PRIMARY KEY (candidate_design_id, evaluation_future_id)
        )
    """)
end

function _cross_row_exists(db, candidate_id, future_id)
    rows = DBInterface.execute(db,
        "SELECT candidate_design_id FROM cross_evaluations WHERE candidate_design_id = ? AND evaluation_future_id = ?",
        [candidate_id, future_id]) |> DataFrame
    !isempty(rows)
end

function _write_cross_row!(db; candidate_id, future_id, objective, optimal,
                           feasible, solver_status, primal_status, co2_price = missing,
                           error = missing)
    absolute = objective === missing || optimal === missing ? missing : objective - optimal
    relative = absolute === missing || optimal == 0 ? missing : absolute / optimal
    DBInterface.execute(db, """
        INSERT OR REPLACE INTO cross_evaluations VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, [candidate_id, candidate_id, future_id, feasible, solver_status, primal_status,
          objective, optimal, absolute, relative, co2_price, error, string(now())])
end

function _prepare_robustness_model(input_workbook::AbstractString, mode::Symbol)
    md = read_data_cached(input_workbook)
    derive_sets!(md)
    compute_derived_params!(md)
    mode == :ts && build_temporal_clusters!(md)
    return md
end

function _fix_design!(model::JuMP.Model, design::Vector{DesignValue})
    isempty(design) && error("Candidate design has no stored long-lived variables")
    for value in design
        variable = JuMP.variable_by_name(model, value.variable_name)
        variable === nothing && error("Stored design variable not found in evaluation model: $(value.variable_name)")
        JuMP.fix(variable, value.value; force = true)
    end
end

"""
    run_cross_scenario_robustness(; scenario_path=nothing, cross_path=nothing,
                                  input_workbook=nothing, solver=:highs,
                                  mode=:ts, overwrite=false)

Evaluate every stored scenario-optimal design in every stored future. Results
are written one pair at a time to a separate long-format DuckDB database, so
completed pairs are skipped on restart and infeasible pairs are recorded.
"""
function run_cross_scenario_robustness(; scenario_path::Union{Nothing,AbstractString} = nothing,
                                       cross_path::Union{Nothing,AbstractString} = nothing,
                                       input_workbook::Union{Nothing,AbstractString} = nothing,
                                       solver::Symbol = :highs,
                                       mode::Symbol = :ts,
                                       overwrite::Bool = false)
    scenarios = load_saved_scenario_runs(path = scenario_path)
    isempty(scenarios) && return DataFrame()
    workbook = input_workbook === nothing ? scenarios[1].input_workbook : String(input_workbook)
    isempty(workbook) && error("No input workbook stored; pass input_workbook explicitly")
    any(!isempty(s.input_workbook) && s.input_workbook != workbook for s in scenarios) &&
        error("Stored scenarios use different workbooks; evaluate them in separate runs")
    base_md = _prepare_robustness_model(workbook, mode)
    db_path = _cross_evaluation_path(cross_path)
    mkpath(dirname(db_path))
    db = DuckDB.DB(db_path)
    try
        _ensure_cross_schema!(db)
        for candidate in scenarios, future in scenarios
            if !overwrite && _cross_row_exists(db, candidate.scenario_id, future.scenario_id)
                continue
            end
            objective = missing
            co2_price = missing
            feasible = false
            term = "ERROR"
            primal = ""
            error_text = missing
            try
                md = deepcopy(base_md)
                model = _build_campaign_model(md; solver = solver, threads = 1, mode = mode)
                apply_variant!(model, md, future.inputs; rederive = true)
                _fix_design!(model, candidate.designs)
                optimize!(model)
                term = string(termination_status(model))
                primal = string(primal_status(model))
                feasible = primal in ("FEASIBLE_POINT", "NEARLY_FEASIBLE_POINT") &&
                           term != "INFEASIBLE" && term != "ERROR"
                if feasible
                    objective = try Float64(objective_value(model)) catch; missing end
                    co2_price = try
                        value = _variant_co2_price(model, md)
                        isfinite(value) ? value : missing
                    catch
                        missing
                    end
                end
                if candidate.scenario_id == future.scenario_id && objective !== missing &&
                   candidate.objective !== missing
                    discrepancy = abs(objective - candidate.objective)
                    tolerance = 1e-6 * max(1.0, abs(candidate.objective))
                    discrepancy > tolerance && @warn "Robustness diagonal differs from original" scenario_id = candidate.scenario_id discrepancy tolerance
                end
            catch err
                error_text = sprint(showerror, err)
            end
            optimal = future.objective
            DBInterface.execute(db, "BEGIN TRANSACTION")
            try
                _write_cross_row!(db; candidate_id = candidate.scenario_id,
                    future_id = future.scenario_id, objective = objective,
                    optimal = optimal, feasible = feasible, solver_status = term,
                    primal_status = primal, co2_price = co2_price, error = error_text)
                DBInterface.execute(db, "COMMIT")
            catch
                try DBInterface.execute(db, "ROLLBACK") catch end
                rethrow()
            end
        end
        DBInterface.execute(db, "CHECKPOINT")
        return DBInterface.execute(db, "SELECT * FROM cross_evaluations ORDER BY candidate_design_id, evaluation_future_id") |> DataFrame
    finally
        DBInterface.close!(db)
        finalize(db)
        GC.gc(true)
    end
end

export run_cross_scenario_robustness
