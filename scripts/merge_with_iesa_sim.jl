#!/usr/bin/env julia
# =============================================================================
# merge_with_iesa_sim.jl — combine an IESA-Opt.jl input DuckDB with an
# IESA-Sim (Python) input DuckDB into one merged database.
#
# The two models are genuinely different (IESA-Opt.jl is an optimization
# model with CHP/flexibility/reservoir/emission-target detail; IESA-Sim is an
# agent-diffusion simulation with agent/social-perception detail), so this
# does not attempt to force byte-identical schemas. Instead, for each shared
# table it:
#   - unions the columns that mean the same thing in both models, tagged
#     with a `model_source` column ('IESA-Opt' / 'IESA-Sim') so merged rows
#     stay distinguishable,
#   - reconciles the couple of genuine structural differences (IESA-Sim's
#     wide `volumes_<year>` columns vs IESA-Opt.jl's long activity_volumes
#     table; IESA-Sim's energy_balance/retrofittings having no period
#     dimension at all) rather than dropping data on either side,
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

con = DBInterface.connect(DuckDB.DB, out_db)
try
    DBInterface.execute(con, "ATTACH '$(julia_db)' AS jl (READ_ONLY)")
    DBInterface.execute(con, "ATTACH '$(sim_db)' AS sim (READ_ONLY)")

    written = String[]

    # ---- tables with an already-identical schema: straight UNION ALL -------
    for t in ("technology_costs", "periods", "infrastructure_costs",
              "hourly_profile_types", "hourly_profiles", "interconnectors", "price_profiles")
        DBInterface.execute(con, """
            CREATE TABLE $(t) AS
            SELECT *, 'IESA-Opt' AS model_source FROM jl.$(t)
            UNION ALL
            SELECT *, 'IESA-Sim' AS model_source FROM sim.$(t)
        """)
        push!(written, t)
    end

    # technology_stocks: IESA-Opt.jl has extra use_min/use_max/no_new_invest/
    # no_eco_decom columns IESA-Sim's reader never captures — union only the
    # shared (tech_id, period, dec_planned, min, max).
    DBInterface.execute(con, """
        CREATE TABLE technology_stocks AS
        SELECT tech_id, period, dec_planned, min, max, 'IESA-Opt' AS model_source FROM jl.technology_stocks
        UNION ALL
        SELECT tech_id, period, dec_planned, min, max, 'IESA-Sim' AS model_source FROM sim.technology_stocks
    """)
    push!(written, "technology_stocks")

    # technologies / infrastructure: union only the columns present (and
    # semantically equivalent) on both sides; IESA-Sim's lifetime is
    # INTEGER, IESA-Opt.jl's economic-lifetime-derived `lifetime` is DOUBLE —
    # cast to DOUBLE so the union doesn't need an implicit narrowing cast.
    DBInterface.execute(con, """
        CREATE TABLE technologies AS
        SELECT id, seq, category, sector, subsector, name, unit, activity, cap2act,
               CAST(lifetime AS DOUBLE) AS lifetime, hourly_profile,
               shedding_capacity, shedding_limits,
               flexibility_form, flexibility_capacity, flexibility_volume, flexibility_range,
               flexibility_losses, flexibility_nonnegotiable,
               buffer_up, buffer_down, buffer_capacity, stock_initial,
               'IESA-Opt' AS model_source
        FROM jl.technologies
        UNION ALL
        SELECT id, seq, category, sector, subsector, name, unit, activity, cap2act,
               CAST(lifetime AS DOUBLE) AS lifetime, hourly_profile,
               shedding_capacity, shedding_limits,
               flexibility_form, flexibility_capacity, flexibility_volume, flexibility_range,
               flexibility_losses, flexibility_nonnegotiable,
               buffer_up, buffer_down, buffer_capacity, stock_initial,
               'IESA-Sim' AS model_source
        FROM sim.technologies
    """)
    push!(written, "technologies")

    DBInterface.execute(con, """
        CREATE TABLE infrastructure AS
        SELECT id, seq, category, name, unit, activity, cap2act,
               CAST(lifetime AS DOUBLE) AS lifetime, stock_initial, 'IESA-Opt' AS model_source
        FROM jl.infrastructure
        UNION ALL
        SELECT id, seq, category, name, unit, activity, cap2act,
               CAST(lifetime AS DOUBLE) AS lifetime, stock_initial, 'IESA-Sim' AS model_source
        FROM sim.infrastructure
    """)
    push!(written, "infrastructure")

    # activities: after the rename in input_tables.jl, Name/UoA/Node/Target/
    # activity_resolution/activity_type/energy_label/seq match verbatim.
    DBInterface.execute(con, """
        CREATE TABLE activities AS
        SELECT "Name", "UoA", activity_resolution, activity_type, "Node", "Target", energy_label, seq,
               'IESA-Opt' AS model_source
        FROM jl.activities
        UNION ALL
        SELECT "Name", "UoA", activity_resolution, activity_type, "Node", "Target", energy_label, seq,
               'IESA-Sim' AS model_source
        FROM sim.activities
    """)
    push!(written, "activities")

    # activity_volumes: IESA-Sim stores volumes as wide volumes_<year> columns
    # (hardcoded to its own scenario's period set); IESA-Opt.jl stores them
    # long (activity_name, period, value), which merges cleanly across
    # scenarios with *different* period sets — so IESA-Sim's wide columns are
    # unpivoted to match, not the other way around.
    sim_volume_cols = DBInterface.execute(con,
        "SELECT column_name FROM information_schema.columns WHERE table_catalog='sim' AND table_name='activities' AND column_name LIKE 'volumes\\_%' ESCAPE '\\'"
    ) |> x -> [row[1] for row in x]
    if isempty(sim_volume_cols)
        @warn "merge_with_iesa_sim: no volumes_<year> columns found on sim.activities, skipping activity_volumes union"
        DBInterface.execute(con, """
            CREATE TABLE activity_volumes AS
            SELECT activity_name, period, value, 'IESA-Opt' AS model_source FROM jl.activity_volumes
        """)
    else
        unpivot_parts = [
            "SELECT \"Name\" AS activity_name, $(parse(Int, replace(c, "volumes_" => ""))) AS period, $(c) AS value FROM sim.activities WHERE $(c) IS NOT NULL"
            for c in sim_volume_cols
        ]
        sim_volumes_sql = join(unpivot_parts, " UNION ALL ")
        DBInterface.execute(con, """
            CREATE TABLE activity_volumes AS
            SELECT activity_name, period, value, 'IESA-Opt' AS model_source FROM jl.activity_volumes
            UNION ALL
            SELECT activity_name, period, value, 'IESA-Sim' AS model_source FROM ($(sim_volumes_sql))
        """)
    end
    push!(written, "activity_volumes")

    # energy_balance / retrofittings: IESA-Sim's reader never captured a
    # period dimension (single snapshot); rather than fabricate one, its rows
    # get period = NULL ("applies to all periods / not period-resolved"),
    # unioned alongside IESA-Opt.jl's real per-period rows.
    DBInterface.execute(con, """
        CREATE TABLE energy_balance AS
        SELECT tech_id, activity_name, period, value, 'IESA-Opt' AS model_source FROM jl.energy_balance
        UNION ALL
        SELECT tech_id, activity_name, CAST(NULL AS INTEGER) AS period, value, 'IESA-Sim' AS model_source FROM sim.energy_balance
    """)
    push!(written, "energy_balance")

    DBInterface.execute(con, """
        CREATE TABLE retrofittings AS
        SELECT from_tech, to_tech, period, cost, 'IESA-Opt' AS model_source FROM jl.retrofittings
        UNION ALL
        SELECT from_tech, to_tech, CAST(NULL AS INTEGER) AS period, cost, 'IESA-Sim' AS model_source FROM sim.retrofittings
    """)
    push!(written, "retrofittings")

    DBInterface.execute(con, "DETACH jl")
    DBInterface.execute(con, "DETACH sim")

    println("Merged tables written to $(out_db):")
    for t in written
        n = DBInterface.execute(con, "SELECT COUNT(*) AS n FROM $(t)") |> x -> first(x)[1]
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
