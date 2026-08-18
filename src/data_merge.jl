# =============================================================================
# data_merge.jl — consolidate an IESA-Opt.jl-shaped and an IESA-Sim-shaped
# input DuckDB into ONE database, not a side-by-side comparison.
#
# Distinct from scripts/merge_with_iesa_sim.jl (which keeps both sources'
# rows, tagged by a `model_source` column, for comparison): here, for any
# table/row present in both sources, the *priority* source's data wins and
# the other source only fills in what the priority source is missing. The
# output tables get their natural key (e.g. `activities(Name)`, no
# `model_source`), so this can be used as a single further-mergeable/queryable
# database rather than a diagnostic artifact.
#
# Reuses `_create_table_from_select!` (duckdb_select_table.jl) for the actual
# CREATE TABLE + PK/FK + anti-join FK validation — this file only supplies
# the *row-combining* SQL (priority-fill instead of tag-union) and the
# registry of which ~14 tables are shared between the two models' shapes.
# =============================================================================

"""
Registry of tables considered "the same concept" across an IESA-Opt-shaped
and an IESA-Sim-shaped input DuckDB (see write_input_tables_duckdb! /
IESA-Sim's mod0_read_data_save_duck.py). `key` is the column set used to
decide whether a secondary-source row is "already covered" by the primary
source (not necessarily the full row — see `energy_balance`/`retrofittings`,
where IESA-Sim's reader has no period dimension at all, so `period` is left
out of the join key even though IESA-Opt.jl's own rows do carry it). `pk`
is the merged output table's own PRIMARY KEY (`nothing` for the two
no-clean-key fact tables, matching their treatment as keyless fact tables
in merge_with_iesa_sim.jl). `fks` reference other tables in this same
registry by their *output* (unprefixed) names.
"""
const _IESA_OPT_SIM_SHARED_TABLES = [
    (name = "periods", key = ["period"], pk = ["period"], fks = Tuple{Vector{String},String,Vector{String}}[],
     opt_select = "SELECT period, period_order FROM opt.periods",
     sim_select = "SELECT period, period_order FROM sim.periods"),

    (name = "hourly_profile_types", key = ["name"], pk = ["name"], fks = Tuple{Vector{String},String,Vector{String}}[],
     opt_select = "SELECT name, seq FROM opt.hourly_profile_types",
     sim_select = "SELECT name, seq FROM sim.hourly_profile_types"),

    (name = "interconnectors", key = ["id"], pk = ["id"], fks = Tuple{Vector{String},String,Vector{String}}[],
     opt_select = "SELECT id, name FROM opt.interconnectors",
     sim_select = "SELECT id, name FROM sim.interconnectors"),

    # act_change_max has no IESA-Sim counterpart (IESA-Opt.jl-only concept,
    # like technologies'/infrastructure's WACC/lifetime/process_type fields
    # below) — cast NULL on the sim side so read_data_from_duckdb's full
    # column list (input_tables.jl's _activities_df) still resolves against
    # a merged table, not just a plain write_input_tables_duckdb! output.
    (name = "activities", key = ["Name"], pk = ["Name"],
     fks = [(["activity_type"], "activity_types", ["activity_type"]), (["energy_label"], "energy_labels", ["labels"]),
            (["Node"], "nodes", ["node"]), (["activity_resolution"], "dispatch_types", ["dispatch_type"])],
     opt_select = "SELECT \"Name\", \"UoA\", activity_resolution, activity_type, \"Node\", \"Target\", energy_label, seq, act_change_max FROM opt.activities",
     sim_select = "SELECT \"Name\", \"UoA\", activity_resolution, activity_type, \"Node\", \"Target\", energy_label, seq, CAST(NULL AS DOUBLE) AS act_change_max FROM sim.activities"),

    # sector_kev/wacc/construction_time/technical_lifetime/salvage_value/
    # ramping/process_type/change_max have no IESA-Sim counterpart (see
    # input_tables.jl's _tech_metadata_df comment) — cast NULL on the sim
    # side, same reasoning as activities.act_change_max above.
    (name = "technologies", key = ["id"], pk = ["id"],
     fks = [(["activity"], "activities", ["Name"]), (["hourly_profile"], "hourly_profile_types", ["name"]),
            (["process_type"], "process_types", ["process_type"]),
            (["flexibility_form"], "flexibility_types", ["flexibility_type"]),
            (["flexibility_range"], "range_types", ["range_type"]),
            (["sector"], "sectors", ["sectors"]), (["sector_kev"], "sectors_kev", ["sector_kev"])],
     opt_select = """
        SELECT id, seq, category, sector, subsector, sector_kev, name, unit, activity, cap2act, wacc,
               construction_time, CAST(lifetime AS DOUBLE) AS lifetime, technical_lifetime, salvage_value,
               ramping, process_type, hourly_profile,
               shedding_capacity, shedding_limits,
               flexibility_form, flexibility_capacity, flexibility_volume, flexibility_range,
               flexibility_losses, flexibility_nonnegotiable,
               buffer_up, buffer_down, buffer_capacity, stock_initial, change_max
        FROM opt.technologies""",
     sim_select = """
        SELECT id, seq, category, sector, subsector, CAST(NULL AS VARCHAR) AS sector_kev, name, unit, activity, cap2act,
               CAST(NULL AS DOUBLE) AS wacc, CAST(NULL AS DOUBLE) AS construction_time,
               CAST(lifetime AS DOUBLE) AS lifetime, CAST(NULL AS DOUBLE) AS technical_lifetime,
               CAST(NULL AS DOUBLE) AS salvage_value, CAST(NULL AS DOUBLE) AS ramping,
               CAST(NULL AS VARCHAR) AS process_type, hourly_profile,
               shedding_capacity, shedding_limits,
               flexibility_form, flexibility_capacity, flexibility_volume, flexibility_range,
               flexibility_losses, flexibility_nonnegotiable,
               buffer_up, buffer_down, buffer_capacity, stock_initial, CAST(NULL AS DOUBLE) AS change_max
        FROM sim.technologies"""),

    # sector/subsector/sector_kev/wacc/technical_lifetime/salvage_value/
    # change_max/infra_range have no IESA-Sim counterpart — same NULL-cast
    # treatment as technologies above.
    (name = "infrastructure", key = ["id"], pk = ["id"],
     fks = [(["activity"], "activities", ["Name"]), (["infra_range"], "range_types", ["range_type"]),
            (["sector"], "sectors", ["sectors"]), (["sector_kev"], "sectors_kev", ["sector_kev"])],
     opt_select = """
        SELECT id, seq, category, sector, subsector, sector_kev, name, unit, activity, cap2act, wacc,
               CAST(lifetime AS DOUBLE) AS lifetime, technical_lifetime, salvage_value, stock_initial,
               change_max, infra_range
        FROM opt.infrastructure""",
     sim_select = """
        SELECT id, seq, category, CAST(NULL AS VARCHAR) AS sector, CAST(NULL AS VARCHAR) AS subsector,
               CAST(NULL AS VARCHAR) AS sector_kev, name, unit, activity, cap2act, CAST(NULL AS DOUBLE) AS wacc,
               CAST(lifetime AS DOUBLE) AS lifetime, CAST(NULL AS DOUBLE) AS technical_lifetime,
               CAST(NULL AS DOUBLE) AS salvage_value, stock_initial,
               CAST(NULL AS DOUBLE) AS change_max, CAST(NULL AS VARCHAR) AS infra_range
        FROM sim.infrastructure"""),

    (name = "technology_costs", key = ["tech_id", "period"], pk = ["tech_id", "period"],
     fks = [(["tech_id"], "technologies", ["id"]), (["period"], "periods", ["period"])],
     opt_select = "SELECT tech_id, period, investment, fom, vom FROM opt.technology_costs",
     sim_select = "SELECT tech_id, period, investment, fom, vom FROM sim.technology_costs"),

    # use_min/use_max/no_new_invest/no_eco_decom have no IESA-Sim counterpart.
    (name = "technology_stocks", key = ["tech_id", "period"], pk = ["tech_id", "period"],
     fks = [(["tech_id"], "technologies", ["id"]), (["period"], "periods", ["period"])],
     opt_select = """
        SELECT tech_id, period, dec_planned, min, max, use_min, use_max, no_new_invest, no_eco_decom
        FROM opt.technology_stocks""",
     sim_select = """
        SELECT tech_id, period, dec_planned, min, max,
               CAST(NULL AS DOUBLE) AS use_min, CAST(NULL AS DOUBLE) AS use_max,
               CAST(NULL AS BOOLEAN) AS no_new_invest, CAST(NULL AS BOOLEAN) AS no_eco_decom
        FROM sim.technology_stocks"""),

    (name = "infrastructure_costs", key = ["infra_id", "period"], pk = ["infra_id", "period"],
     fks = [(["infra_id"], "infrastructure", ["id"]), (["period"], "periods", ["period"])],
     opt_select = "SELECT infra_id, period, investment, fom FROM opt.infrastructure_costs",
     sim_select = "SELECT infra_id, period, investment, fom FROM sim.infrastructure_costs"),

    (name = "hourly_profiles", key = ["hour", "profile_type"], pk = ["hour", "profile_type"],
     fks = [(["profile_type"], "hourly_profile_types", ["name"])],
     opt_select = "SELECT hour, profile_type, value FROM opt.hourly_profiles",
     sim_select = "SELECT hour, profile_type, value FROM sim.hourly_profiles"),

    (name = "price_profiles", key = ["hour", "interconnector_id", "period"], pk = ["hour", "interconnector_id", "period"],
     fks = [(["interconnector_id"], "interconnectors", ["id"]), (["period"], "periods", ["period"])],
     opt_select = "SELECT hour, interconnector_id, period, price FROM opt.price_profiles",
     sim_select = "SELECT hour, interconnector_id, period, price FROM sim.price_profiles"),

    (name = "activity_volumes", key = ["activity_name", "period"], pk = ["activity_name", "period"],
     fks = [(["activity_name"], "activities", ["Name"]), (["period"], "periods", ["period"])],
     opt_select = "SELECT activity_name, period, value FROM opt.activity_volumes",
     sim_select = nothing),  # dynamic — IESA-Sim's wide volumes_<year> columns are unpivoted at call time

    # No clean shared key: IESA-Sim's reader never captured a period
    # dimension for these, so the join key deliberately excludes `period`
    # (an IESA-Opt "gap" is judged by tech_id+activity_name/from_tech+to_tech
    # alone, ignoring which periods it spans) — and PK stays `nothing` since
    # IESA-Opt.jl's own rows repeat the same partial key once per period.
    (name = "energy_balance", key = ["tech_id", "activity_name"], pk = nothing,
     fks = [(["tech_id"], "technologies", ["id"]), (["activity_name"], "activities", ["Name"]), (["period"], "periods", ["period"])],
     opt_select = "SELECT tech_id, activity_name, period, value FROM opt.energy_balance",
     sim_select = "SELECT tech_id, activity_name, CAST(NULL AS INTEGER) AS period, value FROM sim.energy_balance"),

    (name = "retrofittings", key = ["from_tech", "to_tech"], pk = nothing,
     fks = [(["from_tech"], "technologies", ["id"]), (["to_tech"], "technologies", ["id"]), (["period"], "periods", ["period"])],
     opt_select = "SELECT from_tech, to_tech, period, cost FROM opt.retrofittings",
     sim_select = "SELECT from_tech, to_tech, CAST(NULL AS INTEGER) AS period, cost FROM sim.retrofittings"),
]

# IESA-Sim's wide volumes_<year> activity columns, unpivoted to
# (activity_name, period, value) — same logic as merge_with_iesa_sim.jl,
# computed at call time since the year set isn't known statically.
function _sim_activity_volumes_select(con)
    cols = DBInterface.execute(con,
        "SELECT column_name FROM information_schema.columns WHERE table_catalog='sim' AND table_name='activities' AND column_name LIKE 'volumes\\_%' ESCAPE '\\' ORDER BY column_name"
    ) |> x -> [row[1] for row in x]
    isempty(cols) && return "SELECT CAST(NULL AS VARCHAR) AS activity_name, CAST(NULL AS INTEGER) AS period, CAST(NULL AS DOUBLE) AS value WHERE FALSE"
    return join(
        ["SELECT \"Name\" AS activity_name, $(parse(Int, replace(c, "volumes_" => ""))) AS period, $(c) AS value FROM sim.activities WHERE $(c) IS NOT NULL"
         for c in cols],
        " UNION ALL ",
    )
end

"""
    _priority_fill_select(primary_select, secondary_select, key_cols) -> String

Build the row-combining SQL for one merged table: every row from
`primary_select`, plus rows from `secondary_select` whose `key_cols` value
isn't already present among the primary rows. This — not a tagged
side-by-side union — is what makes the result "one consolidated table".
"""
function _priority_fill_select(primary_select::AbstractString, secondary_select::AbstractString, key_cols::Vector{String})
    join_cond = join(("s.\"$(k)\" = p.\"$(k)\"" for k in key_cols), " AND ")
    return """
        SELECT * FROM ($(primary_select)) p
        UNION ALL
        SELECT s.* FROM ($(secondary_select)) s
        LEFT JOIN ($(primary_select)) p ON $(join_cond)
        WHERE p."$(key_cols[1])" IS NULL
    """
end

function _copy_table_asis!(con, out_name::AbstractString, src_alias::AbstractString, src_table::AbstractString)
    safe_out = _duckdb_quote_identifier(out_name)
    safe_src = "$(src_alias).$(_duckdb_quote_identifier(src_table))"
    _duckdb_execute!(con, "DROP TABLE IF EXISTS $(safe_out)")
    _duckdb_execute!(con, "CREATE TABLE $(safe_out) AS SELECT * FROM $(safe_src)")
    return nothing
end

"""
    merge_or_copy_into(out_db; opt_source=nothing, sim_source=nothing, priority=nothing) -> Dict{String,Any}

Build a single consolidated DuckDB at `out_db` from an IESA-Opt-shaped
input DB (`opt_source`) and/or an IESA-Sim-shaped one (`sim_source`).

- Exactly one of `opt_source`/`sim_source` given: `out_db` is a plain copy
  of that source (its own tables/constraints untouched) — `priority` must
  be `nothing`.
- Both given: `priority` (`:iesa_opt` or `:iesa_sim`) is required. For each
  `_IESA_OPT_SIM_SHARED_TABLES` entry, the priority source's rows win and
  the other source only fills in rows missing from it (`_priority_fill_select`);
  every other table present in either source is copied through unchanged.

Returns a summary `Dict("tables" => Dict(name => Dict("rows"=>Int,
"origin"=>"merged"|"copied:iesaOpt"|"copied:iesaSim")))`.
"""
function merge_or_copy_into(out_db::AbstractString;
                             opt_source::Union{Nothing,AbstractString} = nothing,
                             sim_source::Union{Nothing,AbstractString} = nothing,
                             priority::Union{Nothing,Symbol} = nothing)
    opt_source === nothing && sim_source === nothing && error("merge_or_copy_into: at least one of opt_source/sim_source is required")
    mkpath(dirname(out_db))
    isfile(out_db) && rm(out_db)

    summary = Dict{String,Any}()

    if opt_source !== nothing && sim_source === nothing
        priority === nothing || error("merge_or_copy_into: priority must be `nothing` when only one source is given")
        cp(opt_source, out_db)
        _summarize_single_source!(summary, out_db, "iesaOpt")
        return Dict{String,Any}("tables" => summary)
    elseif sim_source !== nothing && opt_source === nothing
        priority === nothing || error("merge_or_copy_into: priority must be `nothing` when only one source is given")
        cp(sim_source, out_db)
        _summarize_single_source!(summary, out_db, "iesaSim")
        return Dict{String,Any}("tables" => summary)
    end

    priority in (:iesa_opt, :iesa_sim) || error("merge_or_copy_into: priority must be :iesa_opt or :iesa_sim when both sources are given")

    con = _duckdb_connect(out_db)
    try
        _duckdb_execute!(con, "ATTACH '$(opt_source)' AS opt (READ_ONLY)")
        _duckdb_execute!(con, "ATTACH '$(sim_source)' AS sim (READ_ONLY)")

        shared_names = Set{String}(e.name for e in _IESA_OPT_SIM_SHARED_TABLES)
        # metadata/model_data are data_cache.jl's opaque serialized-ModelData
        # blob cache, not relational input data — excluded from the
        # consolidated output (they're per-workbook implementation detail,
        # not something meaningful to merge or copy through).
        excluded_names = Set{String}(["metadata", "model_data"])

        for entry in _IESA_OPT_SIM_SHARED_TABLES
            sim_select = entry.sim_select === nothing ? _sim_activity_volumes_select(con) : entry.sim_select
            primary_select, secondary_select = priority == :iesa_opt ? (entry.opt_select, sim_select) : (sim_select, entry.opt_select)
            select_sql = _priority_fill_select(primary_select, secondary_select, entry.key)
            _create_table_from_select!(con, entry.name, select_sql; pk = entry.pk, fks = entry.fks)
            n = (DBInterface.execute(con, "SELECT COUNT(*) AS n FROM $(_duckdb_quote_identifier(entry.name))") |> first)[1]
            summary[entry.name] = Dict{String,Any}("rows" => n, "origin" => "merged")
        end

        # Everything else: copy through unchanged from whichever source has
        # it (both won't have a same-named table outside the shared registry
        # by construction of the two writers, but if they ever did, priority
        # wins the name).
        opt_tables = Set(String.(_duckdb_query_df(con, "SELECT table_name FROM information_schema.tables WHERE table_catalog='opt'").table_name))
        sim_tables = Set(String.(_duckdb_query_df(con, "SELECT table_name FROM information_schema.tables WHERE table_catalog='sim'").table_name))
        primary_tables, primary_alias, primary_label = priority == :iesa_opt ? (opt_tables, "opt", "iesaOpt") : (sim_tables, "sim", "iesaSim")
        secondary_tables, secondary_alias, secondary_label = priority == :iesa_opt ? (sim_tables, "sim", "iesaSim") : (opt_tables, "opt", "iesaOpt")

        for t in primary_tables
            (t in shared_names || t in excluded_names) && continue
            _copy_table_asis!(con, t, primary_alias, t)
            n = (DBInterface.execute(con, "SELECT COUNT(*) AS n FROM $(_duckdb_quote_identifier(t))") |> first)[1]
            summary[t] = Dict{String,Any}("rows" => n, "origin" => "copied:$(primary_label)")
        end
        for t in secondary_tables
            (t in shared_names || t in excluded_names || haskey(summary, t)) && continue
            _copy_table_asis!(con, t, secondary_alias, t)
            n = (DBInterface.execute(con, "SELECT COUNT(*) AS n FROM $(_duckdb_quote_identifier(t))") |> first)[1]
            summary[t] = Dict{String,Any}("rows" => n, "origin" => "copied:$(secondary_label)")
        end

        _duckdb_execute!(con, "DETACH opt")
        _duckdb_execute!(con, "DETACH sim")
    finally
        # See input_tables.jl's write_input_tables_duckdb! for why this is
        # needed: without it, out_db's freshly merged tables can sit
        # uncheckpointed in a .wal sidecar that GET /unify/download never
        # ships, so a downstream READ_ONLY attach of out_db alone sees an
        # empty database.
        try
            _duckdb_execute!(con, "CHECKPOINT")
        catch
        end
        DBInterface.close!(con)
        GC.gc()
    end
    return Dict{String,Any}("tables" => summary)
end

function _summarize_single_source!(summary::Dict{String,Any}, db_path::AbstractString, label::AbstractString)
    con = _duckdb_connect(db_path; readonly = true)
    try
        tables = String.(_duckdb_query_df(con, "SELECT table_name FROM information_schema.tables").table_name)
        for t in tables
            n = (DBInterface.execute(con, "SELECT COUNT(*) AS n FROM $(_duckdb_quote_identifier(t))") |> first)[1]
            summary[t] = Dict{String,Any}("rows" => n, "origin" => "copied:$(label)")
        end
    finally
        DBInterface.close!(con)
        GC.gc()
    end
    return nothing
end
