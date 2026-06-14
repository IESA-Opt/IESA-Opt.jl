#!/usr/bin/env julia

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using IESAOpt
using JuMP
using DataFrames
using Dates
using Printf

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

env_string(name::AbstractString, default::AbstractString) = get(ENV, name, default)
env_int(name::AbstractString, default::Int) = parse(Int, get(ENV, name, string(default)))
env_bool(name::AbstractString, default::Bool) = lowercase(get(ENV, name, default ? "1" : "0")) in ("1", "true", "yes", "on")

const SCENARIO = env_string("IESA_SCENARIO", "default_data")
const PERIOD = env_int("IESA_PERIOD", 2050)
const REP_DAYS = env_int("IESA_REPDAYS", 30)
const THREADS = env_int("IESA_THREADS", 5)
const FORCE_REFRESH = env_bool("IESA_FORCE_REFRESH", false)
const USE_CACHE = env_bool("IESA_USE_CACHE", false)
default_workbook(scenario::AbstractString) = begin
    scenario_path = joinpath(REPO_ROOT, "data", scenario * ".xlsx")
    isfile(scenario_path) ? scenario_path : joinpath(REPO_ROOT, "data", "default_data.xlsx")
end
const DATA_XLSX = env_string(
    "IESA_DATA_XLSX",
    default_workbook(SCENARIO),
)
const OUT_DIR = env_string(
    "IESA_OUT_DIR",
    joinpath(REPO_ROOT, "Output", "julia_timing_" * SCENARIO * "_rd" * string(REP_DAYS) * "_threads" * string(THREADS)),
)
const EXTERNAL_CLUSTER_MAP = env_string("IESA_EXTERNAL_CLUSTER_MAP", "")

isfile(DATA_XLSX) || error("Database not found at $DATA_XLSX")
mkpath(OUT_DIR)

function elapsed(f)
    t0 = time()
    value = f()
    return value, round(time() - t0, digits = 3)
end

function main()
    total_start = time()
    println("="^72)
    println("Julia TS timing run")
    println("  scenario        = ", SCENARIO)
    println("  data            = ", DATA_XLSX)
    println("  period          = ", PERIOD)
    println("  n_repDays       = ", REP_DAYS)
    println("  extreme periods = 1, count=5")
    println("  solver          = Gurobi BarrierCrossover (Method=2, Crossover=-1)")
    println("  threads         = ", THREADS)
    println("  cache           = ", USE_CACHE ? "read_data_cached" : "read_data")
    if !isempty(EXTERNAL_CLUSTER_MAP)
        println("  cluster map     = ", EXTERNAL_CLUSTER_MAP)
    end
    println("  output          = ", OUT_DIR)
    println("="^72)

    md, data_read_s = elapsed() do
        if USE_CACHE
            IESAOpt.read_data_cached(DATA_XLSX; force_refresh = FORCE_REFRESH)
        else
            IESAOpt.read_data(DATA_XLSX)
        end
    end
    @info "data read done" seconds = data_read_s

    md.sets.periods_solve = filter(p -> p == PERIOD, md.sets.periods_solve)
    isempty(md.sets.periods_solve) && push!(md.sets.periods_solve, PERIOD)

    md.params.n_repDays = REP_DAYS
    md.params.hoursPer_day_cluster = 24
    md.params.clustering_approach = :kmeans_avg
    md.params.ts_extremePeriods = true
    md.params.ts_extremeDays_count = 5
    md.params.ts_capacityProfile_autoMode = true
    md.params.ts_capacityProfile_autoFloor = 0.23
    md.params.ts_capacityProfile_autoCap = 1.00
    md.params.ts_capacityProfile_autoFloor_effective = 0.23
    md.params.ts_capacityProfile_envelopeMode = 0
    md.params.dayMix_softness = 0.0
    md.params.dayMix_weightType = :auto
    md.params.external_clusterMap_path = EXTERNAL_CLUSTER_MAP

    _, derive_s = elapsed() do
        IESAOpt.derive_sets!(md)
        IESAOpt.compute_derived_params!(md)
    end
    @info "derived params done" seconds = derive_s

    _, cluster_s = elapsed() do
        IESAOpt.build_temporal_clusters!(md)
    end
    @info "clustering done" seconds = cluster_s n_repDays = length(md.sets.repDays) hours_cluster = length(md.sets.hours_cluster)

    attrs = IESAOpt.default_gurobi_attributes(; threads = THREADS, rep_days = REP_DAYS)
    attrs["Method"] = 2
    attrs["Crossover"] = -1
    delete!(attrs, "BarHomogeneous")
    delete!(attrs, "BarConvTol")
    delete!(attrs, "FeasibilityTol")
    delete!(attrs, "OptimalityTol")

    optimizer = IESAOpt.gurobi_optimizer(; attrs = attrs)
    model = Model(optimizer)
    IESAOpt.apply_lp_generation_speedups!(model)
    vars, generation_s = elapsed() do
        IESAOpt.build_ts_lp!(model, md)
    end
    n_rows = num_constraints(model; count_variable_in_set_constraints = false)
    n_cols = num_variables(model)
    @info "model generated" seconds = generation_s rows = n_rows cols = n_cols

    _, solve_s = elapsed() do
        optimize!(model)
    end
    term = string(termination_status(model))
    primal = string(primal_status(model))
    obj = try
        objective_value(model)
    catch
        NaN
    end
    @info "solve done" seconds = solve_s status = term objective = obj

    rr = IESAOpt.RunResult(
        OUT_DIR, now(), :ts,
        term, primal, term,
        obj, solve_s, round(time() - total_start, digits = 3),
        n_rows, n_cols, 0, 0, 0,
        attrs, SCENARIO,
        md.params.n_repDays, md.params.hoursPer_day,
        md.params.clustering_approach,
    )

    written = Dict{Symbol,String}()
    db_path = joinpath(OUT_DIR, IESAOpt.IESA_RESULTS_DUCKDB_FILE)
    IESAOpt._remove_duckdb_database!(db_path)
    write_started = time()
    write_s = 0.0
    total_s = 0.0

    IESAOpt._with_duckdb_write_connection(db_path) do
        merge!(written, IESAOpt.write_duckdb_results(rr, vars, md, OUT_DIR; mode = :ts, reset = false))
        write_s = round(time() - write_started, digits = 3)
        total_s = round(time() - total_start, digits = 3)
        timing = DataFrame(
            engine = ["Julia"],
            scenario = [SCENARIO],
            period = [PERIOD],
            n_repDays = [md.params.n_repDays],
            threads = [THREADS],
            dataRead_sec = [data_read_s],
            derive_sec = [derive_s],
            cluster_sec = [cluster_s],
            generation_sec = [generation_s],
            solve_sec = [solve_s],
            resultsWrite_sec = [write_s],
            total_sec = [total_s],
            n_rows = [n_rows],
            n_cols = [n_cols],
            objective = [obj],
            termination_status = [term],
        )
        timing_path = IESAOpt._duckdb_table_uri(db_path, "timing_summary")
        IESAOpt._write_table(timing, timing_path)

        solver_settings = DataFrame(
            attribute = string.(sort(collect(keys(attrs)))),
            value = [string(attrs[key]) for key in sort(collect(keys(attrs)))],
        )
        IESAOpt._write_table(solver_settings, IESAOpt._duckdb_table_uri(db_path, "solver_settings"))
    end
    @info "results written" seconds = write_s files = sort(collect(keys(written)))

    println()
    println("="^72)
    @printf("Objective: %.6f\n", obj)
    @printf("Timing seconds: read=%.3f derive=%.3f cluster=%.3f gen=%.3f solve=%.3f write=%.3f total=%.3f\n",
            data_read_s, derive_s, cluster_s, generation_s, solve_s, write_s, total_s)
    println("Results DuckDB: ", db_path)
    println("Timing table: timing_summary")
    println("Output dir: ", OUT_DIR)
    println("="^72)
end

main()