#!/usr/bin/env julia
# =============================================================================
# merge_with_iesa_sim.jl — combine an IESA-Opt.jl input DuckDB with an
# IESA-Sim (Python) input DuckDB into one merged database, with real
# PRIMARY KEY / FOREIGN KEY constraints (not just unioned rows).
#
# Two things this needs that a plain `CREATE TABLE ... AS SELECT ...` can't
# give you:
#   1. DuckDB's CTAS syntax cannot carry PRIMARY KEY/FOREIGN KEY at all — same
#      limitation input_tables.jl works around. So every merged table here is
#      built as an explicit `CREATE TABLE (columns, PK, FK)` followed by
#      `INSERT INTO ... SELECT`, not a bare CTAS.
#   2. The two models' id domains overlap semantically (both are built from
#      the same real activities/technologies, e.g. both have an activity
#      literally named "Electricity demand - Residential") — so every key
#      and every FK must include `model_source`, or rows from the two
#      sources collide/cross-reference incorrectly. A naive PK on `id` alone
#      would reject the second source's row as a duplicate.
#
# The two models are otherwise genuinely different (IESA-Opt.jl is an
# optimization model with CHP/flexibility/reservoir/emission-target detail;
# IESA-Sim is an agent-diffusion simulation with agent/social-perception
# detail), so this does not attempt byte-identical schemas. For each shared
# table it:
#   - unions the columns that mean the same thing in both models,
#   - reconciles the couple of genuine structural differences (IESA-Sim's
#     wide `volumes_<year>` columns vs IESA-Opt.jl's long activity_volumes
#     table; IESA-Sim's energy_balance/retrofittings having no period
#     dimension at all) rather than dropping data on either side,
#   - validates each candidate FK against the actual merged data first (the
#     same known IESA-Opt.jl data-quality gaps — e.g. an activity_type of
#     "Credits" not in the enum — apply here too) and drops just that one FK
#     if it doesn't hold, exactly like input_tables.jl's per-column validation,
#   - leaves model-specific columns/tables (agents, CHP, ...) out of the
#     merged view — they remain queryable in the original two files, ATTACHed
#     read-only alongside the merge output.
#
# Usage:
#   julia --project=. scripts/merge_with_iesa_sim.jl
#
# Env vars (all optional, defaults shown):
#   IESA_JULIA_DB  = data/.iesa_cache/default_data.iesa_input.duckdb
#   IESA_SIM_DB    = (path to the IESA-Sim simmodel.duckdb — required, no
#                     cross-repo default)
#   IESA_MERGE_OUT = data/.iesa_cache/merged_iesa.duckdb
# =============================================================================

using DuckDB
using DataFrames
import DBInterface

const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

julia_db = get(ENV, "IESA_JULIA_DB", joinpath(REPO_ROOT, "data", ".iesa_cache", "default_data.iesa_input.duckdb"))
sim_db = get(ENV, "IESA_SIM_DB", "")
out_db = get(ENV, "IESA_MERGE_OUT", joinpath(REPO_ROOT, "data", ".iesa_cache", "merged_iesa.duckdb"))

isfile(julia_db) || error("IESA-Opt.jl input DB not found: $julia_db (run read_data first)")
isempty(sim_db) && error("Set IESA_SIM_DB to the path of the IESA-Sim simmodel.duckdb to merge with")
isfile(sim_db) || error("IESA-Sim DB not found: $sim_db")

isfile(out_db) && rm(out_db)
mkpath(dirname(out_db))

# ---------------------------------------------------------------------------
# _create_merged_table!(con, name, select_sql; pk, fks)
#
# `select_sql` must already produce exactly the target column list (in
# order), including `model_source`. `pk` is a Vector{String} of column names
# or `nothing`. `fks` is a Vector of (cols::Vector{String}, ref_table::String,
# ref_cols::Vector{String}) candidates — each is checked with an anti-join
# against `select_sql` before being declared, and dropped (with a printed
# reason) if any non-NULL child value has no match in the parent.
# ---------------------------------------------------------------------------
function _create_merged_table!(con, name::String, select_sql::String;
                                pk::Union{Nothing,Vector{String}} = nothing,
                                fks::Vector = Tuple{Vector{String},String,Vector{String}}[])
    schema_df = DBInterface.execute(con, "SELECT * FROM ($(select_sql)) LIMIT 0") |> DataFrame
    colnames = names(schema_df)

    valid_fks = Tuple{Vector{String},String,Vector{String}}[]
    for (cols, ref_table, ref_cols) in fks
        join_cond = join(("c.\"$(a)\" = p.\"$(b)\"" for (a, b) in zip(cols, ref_cols)), " AND ")
        notnull_cond = join(("c.\"$(a)\" IS NOT NULL" for a in cols), " AND ")
        check_sql = """
            SELECT COUNT(*) AS n FROM ($(select_sql)) c
            LEFT JOIN $(ref_table) p ON $(join_cond)
            WHERE $(notnull_cond) AND p."$(ref_cols[1])" IS NULL
        """
        n = (DBInterface.execute(con, check_sql) |> first)[1]
        if n == 0
            push!(valid_fks, (cols, ref_table, ref_cols))
        else
            println("  [$(name)] dropping FK $(cols) -> $(ref_table)$(ref_cols): $(n) orphan value(s)")
        end
    end

    col_list_sql = join(("\"$(c)\"" for c in colnames), ", ")
    constraints = String[]
    pk !== nothing && push!(constraints, "PRIMARY KEY (" * join(("\"$(c)\"" for c in pk), ", ") * ")")
    for (cols, ref_table, ref_cols) in valid_fks
        push!(constraints, "FOREIGN KEY (" * join(("\"$(c)\"" for c in cols), ", ") * ") REFERENCES " *
                            "$(ref_table)(" * join(("\"$(c)\"" for c in ref_cols), ", ") * ")")
    end

    # Column types come from the (already-typed) SELECT itself — describe the
    # zero-row projection to get them without re-deriving each type by hand.
    types_df = DBInterface.execute(con, "DESCRIBE SELECT * FROM ($(select_sql)) LIMIT 0") |> DataFrame
    types = Dict{String,String}(row.column_name => row.column_type for row in eachrow(types_df))
    cols_sql = join(("\"$(c)\" $(types[c])" for c in colnames), ",\n    ")

    body = join(vcat([cols_sql], constraints), ",\n    ")
    DBInterface.execute(con, "CREATE TABLE \"$(name)\" (\n    $(body)\n)")
    DBInterface.execute(con, "INSERT INTO \"$(name)\" SELECT $(col_list_sql) FROM ($(select_sql))")
    return nothing
end

con = DBInterface.connect(DuckDB.DB, out_db)
try
    DBInterface.execute(con, "ATTACH '$(julia_db)' AS jl (READ_ONLY)")
    DBInterface.execute(con, "ATTACH '$(sim_db)' AS sim (READ_ONLY)")

    written = String[]

    # ---- root reference tables (no FKs of their own) -----------------------
    _create_merged_table!(con, "periods", """
        SELECT 'IESA-Opt' AS model_source, * FROM jl.periods
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, * FROM sim.periods
    """; pk = ["model_source", "period"])
    push!(written, "periods")

    _create_merged_table!(con, "hourly_profile_types", """
        SELECT 'IESA-Opt' AS model_source, * FROM jl.hourly_profile_types
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, * FROM sim.hourly_profile_types
    """; pk = ["model_source", "name"])
    push!(written, "hourly_profile_types")

    _create_merged_table!(con, "interconnectors", """
        SELECT 'IESA-Opt' AS model_source, * FROM jl.interconnectors
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, * FROM sim.interconnectors
    """; pk = ["model_source", "id"])
    push!(written, "interconnectors")

    # activities: after the rename in input_tables.jl, Name/UoA/Node/Target/
    # activity_resolution/activity_type/energy_label/seq match verbatim.
    _create_merged_table!(con, "activities", """
        SELECT 'IESA-Opt' AS model_source, "Name", "UoA", activity_resolution, activity_type, "Node", "Target", energy_label, seq
        FROM jl.activities
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, "Name", "UoA", activity_resolution, activity_type, "Node", "Target", energy_label, seq
        FROM sim.activities
    """; pk = ["model_source", "Name"])
    push!(written, "activities")

    # ---- technologies / infrastructure (FK -> activities) ------------------
    # IESA-Sim's lifetime is INTEGER, IESA-Opt.jl's economic-lifetime-derived
    # `lifetime` is DOUBLE — cast to DOUBLE so the union doesn't need an
    # implicit narrowing cast.
    _create_merged_table!(con, "technologies", """
        SELECT 'IESA-Opt' AS model_source, id, seq, category, sector, subsector, name, unit, activity, cap2act,
               CAST(lifetime AS DOUBLE) AS lifetime, hourly_profile,
               shedding_capacity, shedding_limits,
               flexibility_form, flexibility_capacity, flexibility_volume, flexibility_range,
               flexibility_losses, flexibility_nonnegotiable,
               buffer_up, buffer_down, buffer_capacity, stock_initial
        FROM jl.technologies
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, id, seq, category, sector, subsector, name, unit, activity, cap2act,
               CAST(lifetime AS DOUBLE) AS lifetime, hourly_profile,
               shedding_capacity, shedding_limits,
               flexibility_form, flexibility_capacity, flexibility_volume, flexibility_range,
               flexibility_losses, flexibility_nonnegotiable,
               buffer_up, buffer_down, buffer_capacity, stock_initial
        FROM sim.technologies
    """; pk = ["model_source", "id"], fks = [
        (["model_source", "activity"], "activities", ["model_source", "Name"]),
        (["model_source", "hourly_profile"], "hourly_profile_types", ["model_source", "name"]),
    ])
    push!(written, "technologies")

    _create_merged_table!(con, "infrastructure", """
        SELECT 'IESA-Opt' AS model_source, id, seq, category, name, unit, activity, cap2act,
               CAST(lifetime AS DOUBLE) AS lifetime, stock_initial
        FROM jl.infrastructure
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, id, seq, category, name, unit, activity, cap2act,
               CAST(lifetime AS DOUBLE) AS lifetime, stock_initial
        FROM sim.infrastructure
    """; pk = ["model_source", "id"], fks = [
        (["model_source", "activity"], "activities", ["model_source", "Name"]),
    ])
    push!(written, "infrastructure")

    # ---- per-period fact tables (FK -> technologies/infrastructure/periods) --
    # technology_stocks: IESA-Opt.jl has extra use_min/use_max/no_new_invest/
    # no_eco_decom columns IESA-Sim's reader never captures — union only the
    # shared (tech_id, period, dec_planned, min, max).
    _create_merged_table!(con, "technology_stocks", """
        SELECT 'IESA-Opt' AS model_source, tech_id, period, dec_planned, min, max FROM jl.technology_stocks
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, tech_id, period, dec_planned, min, max FROM sim.technology_stocks
    """; pk = ["model_source", "tech_id", "period"], fks = [
        (["model_source", "tech_id"], "technologies", ["model_source", "id"]),
        (["model_source", "period"], "periods", ["model_source", "period"]),
    ])
    push!(written, "technology_stocks")

    _create_merged_table!(con, "technology_costs", """
        SELECT 'IESA-Opt' AS model_source, * FROM jl.technology_costs
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, * FROM sim.technology_costs
    """; pk = ["model_source", "tech_id", "period"], fks = [
        (["model_source", "tech_id"], "technologies", ["model_source", "id"]),
        (["model_source", "period"], "periods", ["model_source", "period"]),
    ])
    push!(written, "technology_costs")

    _create_merged_table!(con, "infrastructure_costs", """
        SELECT 'IESA-Opt' AS model_source, * FROM jl.infrastructure_costs
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, * FROM sim.infrastructure_costs
    """; pk = ["model_source", "infra_id", "period"], fks = [
        (["model_source", "infra_id"], "infrastructure", ["model_source", "id"]),
        (["model_source", "period"], "periods", ["model_source", "period"]),
    ])
    push!(written, "infrastructure_costs")

    _create_merged_table!(con, "hourly_profiles", """
        SELECT 'IESA-Opt' AS model_source, * FROM jl.hourly_profiles
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, * FROM sim.hourly_profiles
    """; pk = ["model_source", "hour", "profile_type"], fks = [
        (["model_source", "profile_type"], "hourly_profile_types", ["model_source", "name"]),
    ])
    push!(written, "hourly_profiles")

    _create_merged_table!(con, "price_profiles", """
        SELECT 'IESA-Opt' AS model_source, * FROM jl.price_profiles
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, * FROM sim.price_profiles
    """; pk = ["model_source", "hour", "interconnector_id", "period"], fks = [
        (["model_source", "interconnector_id"], "interconnectors", ["model_source", "id"]),
        (["model_source", "period"], "periods", ["model_source", "period"]),
    ])
    push!(written, "price_profiles")

    # activity_volumes: IESA-Sim stores volumes as wide volumes_<year> columns
    # (hardcoded to its own scenario's period set); IESA-Opt.jl stores them
    # long (activity_name, period, value), which merges cleanly across
    # scenarios with *different* period sets — so IESA-Sim's wide columns are
    # unpivoted to match, not the other way around.
    sim_volume_cols = DBInterface.execute(con,
        "SELECT column_name FROM information_schema.columns WHERE table_catalog='sim' AND table_name='activities' AND column_name LIKE 'volumes\\_%' ESCAPE '\\' ORDER BY column_name"
    ) |> x -> [row[1] for row in x]
    sim_volumes_select = if isempty(sim_volume_cols)
        @warn "merge_with_iesa_sim: no volumes_<year> columns found on sim.activities, activity_volumes will only have IESA-Opt rows"
        "SELECT CAST(NULL AS VARCHAR) AS activity_name, CAST(NULL AS INTEGER) AS period, CAST(NULL AS DOUBLE) AS value WHERE FALSE"
    else
        join(
            ["SELECT \"Name\" AS activity_name, $(parse(Int, replace(c, "volumes_" => ""))) AS period, $(c) AS value FROM sim.activities WHERE $(c) IS NOT NULL"
             for c in sim_volume_cols],
            " UNION ALL ",
        )
    end
    _create_merged_table!(con, "activity_volumes", """
        SELECT 'IESA-Opt' AS model_source, activity_name, period, value FROM jl.activity_volumes
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, activity_name, period, value FROM ($(sim_volumes_select))
    """; pk = ["model_source", "activity_name", "period"], fks = [
        (["model_source", "activity_name"], "activities", ["model_source", "Name"]),
        (["model_source", "period"], "periods", ["model_source", "period"]),
    ])
    push!(written, "activity_volumes")

    # energy_balance / retrofittings: IESA-Sim's reader never captured a
    # period dimension (single snapshot); rather than fabricate one, its rows
    # get period = NULL. That also means neither table can carry a PK
    # spanning period (PRIMARY KEY columns can't hold NULL, and IESA-Opt.jl's
    # own rows repeat the same (tech_id, activity_name)/(from_tech, to_tech)
    # once per period) — these stay keyless fact tables, same as e.g.
    # IESA-Sim's own `population`/`criteria_weights`, but keep their FKs.
    _create_merged_table!(con, "energy_balance", """
        SELECT 'IESA-Opt' AS model_source, tech_id, activity_name, period, value FROM jl.energy_balance
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, tech_id, activity_name, CAST(NULL AS INTEGER) AS period, value FROM sim.energy_balance
    """; fks = [
        (["model_source", "tech_id"], "technologies", ["model_source", "id"]),
        (["model_source", "activity_name"], "activities", ["model_source", "Name"]),
        (["model_source", "period"], "periods", ["model_source", "period"]),
    ])
    push!(written, "energy_balance")

    _create_merged_table!(con, "retrofittings", """
        SELECT 'IESA-Opt' AS model_source, from_tech, to_tech, period, cost FROM jl.retrofittings
        UNION ALL
        SELECT 'IESA-Sim' AS model_source, from_tech, to_tech, CAST(NULL AS INTEGER) AS period, cost FROM sim.retrofittings
    """; fks = [
        (["model_source", "from_tech"], "technologies", ["model_source", "id"]),
        (["model_source", "to_tech"], "technologies", ["model_source", "id"]),
        (["model_source", "period"], "periods", ["model_source", "period"]),
    ])
    push!(written, "retrofittings")

    DBInterface.execute(con, "DETACH jl")
    DBInterface.execute(con, "DETACH sim")

    println()
    println("Merged tables written to $(out_db):")
    for t in written
        n = (DBInterface.execute(con, "SELECT COUNT(*) AS n FROM \"$(t)\"") |> first)[1]
        println("  $(t): $(n) rows")
    end
    println()
    println("Model-specific tables/columns not merged remain queryable by re-attaching")
    println("the original files directly, e.g.:")
    println("  ATTACH '$(julia_db)' AS jl (READ_ONLY); SELECT * FROM jl.technology_flexibility_activities;")
    println("  ATTACH '$(sim_db)' AS sim (READ_ONLY); SELECT * FROM sim.agent_profiles;")
finally
    DBInterface.close!(con)
end
