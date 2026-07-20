# =============================================================================
# input_tables.jl — relational DuckDB tables for the parsed input workbook
#
# Mirrors the schema conventions of the reference Python loader
# (IESA-Sim-v1.09-py/code/read/mod0_read_data_save_duck.py + mod0_load_duckdb.py):
# one named table per sheet-entity, matching column names/PRIMARY KEY/FOREIGN
# KEY where IESA-Opt.jl has a real counterpart to IESA-Sim's simulation model:
#   - activities(Name PK, activity_resolution, activity_type FK, energy_label FK, ...)
#   - technologies(id PK, ..., hourly_profile FK, flexibility_form, buffer_*, ...)
#   - technology_costs / technology_stocks (tech_id FK, period FK, ...)
#   - infrastructure / infrastructure_costs (infra_id FK, period FK, ...)
#   - technology_flexibility_activities (tech_id FK, activity_name FK) — sparse join
#   - hourly_profile_types / hourly_profiles (profile_type FK -> hourly_profile_types.name)
#   - interconnectors / price_profiles (interconnector_id FK -> interconnectors.id)
#   - retrofittings / energy_balance
# IESA-Opt.jl carries extra columns/dimensions IESA-Sim doesn't have (e.g. a
# `period` column on energy_balance/retrofittings, `technical_lifetime`
# alongside `lifetime`, nodes/emission targets) — those keep clear Julia-native
# names since there's no Python counterpart to align to.
#
# Constrained tables are created via CREATE TABLE (explicit schema + PK/FK) +
# INSERT INTO ... SELECT, exactly like the Python loader. If a constraint
# can't be satisfied (a data-quality issue, e.g. an orphan FK value) the write
# falls back to a plain unconstrained table with a warning, so a schema
# mismatch never blocks getting the data into DuckDB.
#
# Fields not tied to a specific named table (rich per-tech CHP attributes,
# solver/runtime config, derived helpers) fall back to a generic per-field
# table named after the ModelSets/ModelParams field itself, so nothing
# silently disappears.
# =============================================================================

"""
    write_input_tables_duckdb!(md::ModelData, db_path::AbstractString)

Write the parsed input workbook to `db_path` as a set of named relational
tables (mirroring the source Excel sheets and the reference Python IESA-Sim
schema), plus a generic fallback table per remaining `ModelSets`/`ModelParams`
field. Existing tables of the same name are replaced. Returns the
`Vector{String}` of table names written.
"""
function write_input_tables_duckdb!(md::ModelData, db_path::AbstractString)
    mkpath(dirname(db_path))
    con = _duckdb_connect(db_path)
    written = String[]
    skipped = String[]
    mismatches = String[]
    s, p = md.sets, md.params
    try
        # This function always rebuilds every table from scratch. Drop everything
        # upfront (CASCADE) rather than table-by-table as we go: a table-by-table
        # DROP+CREATE fails once a *previous* build's child table (e.g.
        # activity_volumes) still holds a live FK into the parent being rebuilt
        # (e.g. activities) — DuckDB refuses to drop a table that's still
        # referenced. `metadata`/`model_data` (the opaque blob cache from
        # data_cache.jl) are preserved since they may have just been written to
        # this same file by the caller.
        _drop_all_input_tables!(con)

        # ------------------------------------------------------ referenced --
        # Written first: tables referenced by FOREIGN KEY from other tables.
        if !isempty(s.periods)
            df = DataFrames.DataFrame()
            df[!, :period] = collect(s.periods)
            df[!, :period_order] = collect(0:length(s.periods)-1)
            _write_input_table!(con, df, "periods", written, skipped, mismatches; pk = [:period])
        end

        _write_input_table!(con, _seq_df(:activity_type, s.activity_type), "activity_types", written, skipped, mismatches; pk = [:activity_type])
        _write_input_table!(con, _seq_df(:dispatch_type, s.dispatch_type), "dispatch_types", written, skipped, mismatches; pk = [:dispatch_type])
        _write_input_table!(con, _seq_df(:process_type, s.process_type), "process_types", written, skipped, mismatches; pk = [:process_type])
        _write_input_table!(con, _seq_df(:flexibility_type, s.flexibility_type), "flexibility_types", written, skipped, mismatches; pk = [:flexibility_type])
        _write_input_table!(con, _seq_df(:range_type, s.range_type), "range_types", written, skipped, mismatches; pk = [:range_type])
        _write_input_table!(con, _seq_df(:name, s.profile_typeRead), "hourly_profile_types", written, skipped, mismatches; pk = [:name])
        _write_input_table!(con, _sectors_df(s, p), "sectors", written, skipped, mismatches; pk = [:sectors])
        _write_input_table!(con, _seq_df(:sector_kev, s.sectors_kev), "sectors_kev", written, skipped, mismatches; pk = [:sector_kev])
        _write_input_table!(con, _nodes_df(s, p), "nodes", written, skipped, mismatches; pk = [:node])
        _write_input_table!(con, _energy_labels_df(s, p), "energy_labels", written, skipped, mismatches; pk = [:labels])

        interconnectors_df = _interconnectors_df(p)
        _write_input_table!(con, interconnectors_df, "interconnectors", written, skipped, mismatches; pk = [:id])

        # ------------------------------------------------------- activities --
        _write_input_table!(con, _activities_df(s, p), "activities", written, skipped, mismatches;
            pk = [:Name], fks = [(:activity_type, "activity_types", "activity_type"), (:energy_label, "energy_labels", "labels")])
        _write_input_table!(con, _period_long_df(:activity_name, s.activities_original, s.periods,
                [:value => p.activities_netVolumesOrig]), "activity_volumes", written, skipped, mismatches;
            pk = [:activity_name, :period], fks = [(:activity_name, "activities", "Name"), (:period, "periods", "period")])

        # ---------------------------------------------------------- hourly --
        _write_input_table!(con, _hours_df(s, p), "hours", written, skipped, mismatches; pk = [:hour])
        _write_input_table!(con, _tuple_dict_to_named_df(p.hourly_profilesReadOrig, [:hour, :profile_type]), "hourly_profiles", written, skipped, mismatches;
            pk = [:hour, :profile_type], fks = [(:profile_type, "hourly_profile_types", "name")])
        _write_input_table!(con, _price_profiles_df(p, interconnectors_df), "price_profiles", written, skipped, mismatches;
            pk = [:hour, :interconnector_id, :period], fks = [(:interconnector_id, "interconnectors", "id"), (:period, "periods", "period")])

        # ---------------------------------------------------- technologies --
        _write_input_table!(con, _tech_metadata_df(s.tech_balancers, s, p), "technologies", written, skipped, mismatches;
            pk = [:id], fks = [(:activity, "activities", "Name"), (:hourly_profile, "hourly_profile_types", "name")])
        _write_input_table!(con, _period_long_df(:tech_id, s.tech_balancers, s.periods,
                [:investment => p.inv_cost, :fom => p.fom_cost, :vom => p.vom_cost]), "technology_costs", written, skipped, mismatches;
            pk = [:tech_id, :period], fks = [(:tech_id, "technologies", "id"), (:period, "periods", "period")])
        _write_input_table!(con, _tech_stocks_df(s.tech_balancers, s.periods, p), "technology_stocks", written, skipped, mismatches;
            pk = [:tech_id, :period], fks = [(:tech_id, "technologies", "id"), (:period, "periods", "period")])
        _write_input_table!(con, _tech_flexibility_activities_df(s.tech_balancers, p), "technology_flexibility_activities", written, skipped, mismatches;
            pk = [:tech_id], fks = [(:tech_id, "technologies", "id"), (:activity_name, "activities", "Name")])

        # ---------------------------------------------------- infrastructure --
        _write_input_table!(con, _infra_metadata_df(s.tech_infra, s, p), "infrastructure", written, skipped, mismatches;
            pk = [:id], fks = [(:activity, "activities", "Name")])
        _write_input_table!(con, _period_long_df(:infra_id, s.tech_infra, s.periods,
                [:investment => p.inv_cost, :fom => p.fom_cost]), "infrastructure_costs", written, skipped, mismatches;
            pk = [:infra_id, :period], fks = [(:infra_id, "infrastructure", "id"), (:period, "periods", "period")])
        _write_input_table!(con, _period_long_df(:infra_id, s.tech_infra, s.periods,
                [:dec_planned => p.decom_planned, :min => p.techStock_min, :max => p.techStock_max]), "infrastructure_stocks", written, skipped, mismatches;
            pk = [:infra_id, :period], fks = [(:infra_id, "infrastructure", "id"), (:period, "periods", "period")])

        # --------------------------------------------------------- relations --
        valid_tech_ids = Set{String}(String.(s.tech_balancers))
        _write_input_table!(con, _tuple_dict_to_named_df(p.activity_balancesRef, [:tech_id, :activity_name, :period]), "energy_balance", written, skipped, mismatches;
            pk = [:tech_id, :activity_name, :period], fks = [(:tech_id, "technologies", "id"), (:activity_name, "activities", "Name"), (:period, "periods", "period")])
        _write_input_table!(con, _retrofittings_df(p, valid_tech_ids, mismatches), "retrofittings", written, skipped, mismatches;
            pk = [:from_tech, :to_tech, :period], fks = [(:from_tech, "technologies", "id"), (:to_tech, "technologies", "id")])
        _write_input_table!(con, _tuple_dict_to_named_df(p.feedstockUse_techOrig, [:tech_id, :activity_name]; value_name = :fraction), "feedstock_use", written, skipped, mismatches;
            pk = [:tech_id, :activity_name], fks = [(:tech_id, "technologies", "id"), (:activity_name, "activities", "Name")])
        _write_input_table!(con, _tuple_dict_to_named_df(p.activity_EffImprov, [:tech_id, :activity_name, :period]), "activity_efficiency_improvement", written, skipped, mismatches;
            pk = [:tech_id, :activity_name, :period], fks = [(:tech_id, "technologies", "id"), (:activity_name, "activities", "Name"), (:period, "periods", "period")])
        _write_input_table!(con, _tuple_dict_to_named_df(p.act_to_group, [:activity_original]; value_name = :activity_group), "activity_grouping", written, skipped, mismatches;
            pk = [:activity_original], fks = [(:activity_original, "activities", "Name")])

        # ------------------------------------------------------------- nodes --
        _write_input_table!(con, _node_emission_targets_df(s, p), "node_emission_targets", written, skipped, mismatches;
            pk = [:node, :period], fks = [(:node, "nodes", "node"), (:period, "periods", "period")])
        _write_input_table!(con, _node_co2_budget_df(s, p), "node_co2_budget", written, skipped, mismatches;
            pk = [:node], fks = [(:node, "nodes", "node")])

        _write_input_table!(con, _parameters_scalar_df(p), "parameters", written, skipped, mismatches; pk = [:Name])

        # ------------------------------------------------------- fallback --
        core_sets = Set{Symbol}(vcat(
            [:periods, :dispatch_type, :activity_type, :process_type, :flexibility_type, :range_type,
             :profile_typeRead, :sectors, :sectors_kev, :nodes, :energy_labels,
             :activities_original, :hours_orig, :tech_balancers, :tech_infra],
            _TECH_SUBSET_FIELDS, _INFRA_SUBSET_FIELDS, _ACTIVITIES_SUBSET_FIELDS, _NODES_SUBSET_FIELDS,
        ))
        core_params = Set{Symbol}([
            :scenario_description, :base_year, :XC_TransmissionLoss_global, :baseload_treshold,
            :shedding_inLoad, :social_discount_rate, :ActiveConstraintSet,
            :IEM_sector, :namePer_node, :IEM_node, :is_renewable,
            :emissionTargetAir, :emissionTargetAll, :emissionTargetBunker, :emissionTargetFS,
            :CO2_cumulative_budget, :cumulative_CO2storage,
            :act_units, :actChange_maxOrig, :dispatchType_act, :activityType_act, :nodePer_act,
            :emissionTarget_bin, :labelPer_act, :activities_netVolumesOrig,
            :monthPer_hourOrig, :hourly_profilesReadOrig, :interconnectedHourly_pricesOrig,
            :tech_sector_kev, :tech_category, :tech_sector, :tech_subsector, :tech_name, :tech_units,
            :inv_cost, :fom_cost, :vom_cost, :Salvage_value, :WACC, :construction_time,
            :economic_lifetime, :technical_lifetime, :cap2act, :processType_tech, :profileType_techRead,
            :ramping, :techChange_max, :techStock_exist, :decom_planned, :techStock_min, :techStock_max,
            :techUse_min, :techUse_max, :no_new_invest, :no_eco_decom, :activityPer_techOrig,
            :infra_range, :infra_activityOrig,
            :activity_balancesRef, :retrofit_relations, :retrofit_cost,
            :feedstockUse_techOrig, :activity_EffImprov, :act_to_group,
            :shed_capacity_percentage, :shed_volume, :flexibilityType_tech, :flex_capacity_pct,
            :flex_storage, :flex_range, :flex_losses_legacy, :flex_nnLoad,
            :bufferUP_capacity, :bufferDW_capacity, :buffer_storage, :flex_activityOrig,
        ])

        # Names already claimed by a core table above. Several ModelSets/ModelParams
        # field names collide with core table names (e.g. `s.activities` vs. the
        # `activities` table, `p.hourly_profiles` vs. the `hourly_profiles` table) —
        # the generic fallback must never overwrite a core table for one of these,
        # regardless of whether it's also in the core_sets/core_params blacklists.
        reserved_names = Set{String}(written)

        set_table_names = Set{String}()
        for fname in fieldnames(ModelSets)
            fname in core_sets && continue
            tname = String(fname)
            if tname in reserved_names
                push!(skipped, "sets.$(fname) (name reserved by a core table)")
                continue
            end
            df = _vector_to_input_df(getfield(s, fname))
            if df === nothing
                push!(skipped, "sets.$(fname)")
                continue
            end
            push!(set_table_names, tname)
            pk_s, fks_s = _fallback_set_constraints(tname)
            _write_input_table!(con, df, tname, written, skipped, mismatches; pk = pk_s, fks = fks_s)
        end

        scalar_names = String[]
        scalar_values = String[]
        scalar_types = String[]
        for fname in fieldnames(ModelParams)
            fname in core_params && continue
            tname = String(fname)
            if tname in reserved_names
                push!(skipped, "params.$(fname) (name reserved by a core table)")
                continue
            end
            fval = getfield(p, fname)
            if fval isa AbstractDict
                df = _dict_to_input_df(fval)
                if df === nothing
                    push!(skipped, "params.$(fname)")
                    continue
                end
                tname in set_table_names && (tname = "param_" * tname)
                _write_input_table!(con, df, tname, written, skipped, mismatches)
            else
                push!(scalar_names, String(fname))
                push!(scalar_values, string(fval))
                push!(scalar_types, string(typeof(fval)))
            end
        end
        scalars_df = DataFrames.DataFrame(name = scalar_names, value = scalar_values, julia_type = scalar_types)
        _write_input_table!(con, scalars_df, "parameters_scalar", written, skipped, mismatches; pk = [:name])
    finally
        DBInterface.close!(con)
        GC.gc()
    end
    @info "write_input_tables_duckdb!: wrote input tables" db_path n_tables = length(written) n_skipped_empty = length(skipped)
    _write_mismatches_report(db_path, mismatches)
    return written
end

"""
    _write_mismatches_report(db_path, mismatches)

Write every data-quality mismatch hit while building `db_path` (dropped
FK/PK constraints, skipped retrofitting rows, ...) to a `.txt` file next to
it, for manual review. Overwritten on every run — always written, even when
empty, so an old report never lingers as if it were current.
"""
function _write_mismatches_report(db_path::AbstractString, mismatches::Vector{String})
    report_path = _mismatches_report_path(db_path)
    open(report_path, "w") do io
        println(io, "IESA-Opt input-table mismatch report")
        println(io, "generated: ", Dates.now())
        println(io, "source db: ", db_path)
        println(io, "n_mismatches: ", length(mismatches))
        println(io)
        if isempty(mismatches)
            println(io, "No mismatches found.")
        else
            for (i, m) in enumerate(mismatches)
                println(io, "[$i] ", m)
            end
        end
    end
    @info "write_input_tables_duckdb!: wrote mismatch report" report_path n_mismatches = length(mismatches)
    return report_path
end

function _mismatches_report_path(db_path::AbstractString)
    base, _ = splitext(db_path)
    return base * "_mismatches.txt"
end

# ============================================================================
# Low-level: constrained table write (CREATE TABLE w/ PK/FK + INSERT), with a
# fallback to a plain unconstrained table if the constraint can't be satisfied.
# ============================================================================

function _drop_all_input_tables!(con)
    existing = try
        _duckdb_query_df(con, "SHOW TABLES")
    catch err
        @warn "write_input_tables_duckdb!: failed to list existing tables before rebuild" err = err
        return nothing
    end
    preserve = Set(("metadata", "model_data"))
    remaining = Set{String}(String(t) for t in existing.name if !(String(t) in preserve))

    # DuckDB's DROP TABLE ... CASCADE does not cascade through FK-referencing
    # tables (it still refuses to drop a table another table's FK points at),
    # so children must be dropped before parents. Rather than compute the
    # dependency graph, repeatedly sweep and drop whatever currently succeeds
    # (leaf tables first) until nothing more can be dropped.
    while !isempty(remaining)
        dropped_this_pass = String[]
        for tname in remaining
            try
                _duckdb_execute!(con, "DROP TABLE IF EXISTS $(_duckdb_quote_identifier(tname))")
                push!(dropped_this_pass, tname)
            catch
                # still FK-referenced by a table not yet dropped; retry next pass
            end
        end
        if isempty(dropped_this_pass)
            @warn "write_input_tables_duckdb!: could not drop some existing tables before rebuild (still FK-referenced)" tables = collect(remaining)
            break
        end
        setdiff!(remaining, dropped_this_pass)
    end
    return nothing
end

function _write_input_table!(con, df, table_name::AbstractString, written::Vector{String}, skipped::Vector{String},
                              mismatches::Vector{String};
                              pk::Union{Nothing,Vector{Symbol}} = nothing,
                              fks::Vector{<:Tuple} = Tuple{Symbol,String,String}[])
    if df === nothing
        push!(skipped, table_name)
        return nothing
    end
    df = _parquet_compatible_table(df)

    # Validate each FK independently against the (already-written) referenced
    # table, dropping only the ones with an orphan value — a single bad
    # reference (e.g. one activity tagged with an activity_type not in the
    # enum) must not also cost the table's *other*, perfectly valid FKs.
    valid_fks = Tuple{Symbol,String,String}[]
    for (col, ref_table, ref_col) in fks
        orphans = try
            _fk_orphan_values(con, df, col, ref_table, ref_col)
        catch err
            @warn "write_input_tables_duckdb!: failed to validate foreign key, dropping it" table_name col ref_table ref_col err = err
            push!(mismatches, "table=$(table_name): could not validate FK $(col) -> $(ref_table).$(ref_col), dropped — $(_error_text(err))")
            continue
        end
        if isempty(orphans)
            push!(valid_fks, (col, ref_table, ref_col))
        else
            shown = join((repr(v) for v in first(orphans, 5)), ", ")
            more = length(orphans) > 5 ? " (+$(length(orphans) - 5) more)" : ""
            push!(mismatches, "table=$(table_name): FK $(col) -> $(ref_table).$(ref_col) dropped — $(length(orphans)) value(s) not found: $(shown)$(more)")
        end
    end

    # Tier 1: PRIMARY KEY + validated FOREIGN KEYs.
    if pk !== nothing || !isempty(valid_fks)
        try
            _create_constrained_table!(con, df, table_name; pk = pk, fks = valid_fks)
            push!(written, table_name)
            return nothing
        catch err
            @warn "write_input_tables_duckdb!: constrained create failed for table, retrying without foreign keys" table_name err = err
            push!(mismatches, "table=$(table_name): PRIMARY KEY create with validated FK(s) still failed, retrying without foreign keys — $(_error_text(err))")
        end
    end

    # Tier 2: PRIMARY KEY only. A bad PK (e.g. genuine duplicate rows) must not
    # cost this table its FKs' *targets* either — every other table's FK
    # pointing *at* this one depends on that PK existing.
    if pk !== nothing && !isempty(valid_fks)
        try
            _create_constrained_table!(con, df, table_name; pk = pk, fks = Tuple{Symbol,String,String}[])
            push!(written, table_name)
            return nothing
        catch err
            @warn "write_input_tables_duckdb!: PRIMARY KEY-only fallback also failed, writing a plain table" table_name err = err
            push!(mismatches, "table=$(table_name): PRIMARY KEY $(pk) also failed, written as a plain table with no constraints — $(_error_text(err))")
        end
    end

    # Tier 3: plain, unconstrained table — never lose the data itself.
    try
        _duckdb_replace_table!(con, df, table_name)
        push!(written, table_name)
    catch err
        @warn "write_input_tables_duckdb!: failed to write table" table_name err = err
        push!(mismatches, "table=$(table_name): failed to write entirely (data not saved) — $(_error_text(err))")
    end
    return nothing
end

_error_text(err) = sprint(showerror, err)

# Values in `df[!, col]` that don't appear in `ref_table.ref_col` (ignoring
# missing/NULL, which FK constraints always permit). Empty result means the
# FK is safe to declare.
function _fk_orphan_values(con, df::DataFrames.DataFrame, col::Symbol, ref_table::AbstractString, ref_col::AbstractString)
    ref_df = _duckdb_query_df(con, "SELECT DISTINCT $(_duckdb_quote_identifier(ref_col)) AS v FROM $(_duckdb_quote_identifier(ref_table))")
    ref_keys = Set(skipmissing(ref_df.v))
    orphans = Any[]
    seen = Set{Any}()
    for v in df[!, col]
        (ismissing(v) || v in ref_keys || v in seen) && continue
        push!(seen, v)
        push!(orphans, v)
    end
    return orphans
end

function _create_constrained_table!(con, df::DataFrames.DataFrame, table_name::AbstractString;
                                     pk::Union{Nothing,Vector{Symbol}}, fks::Vector{<:Tuple})
    safe_name = _duckdb_quote_identifier(table_name)
    _duckdb_execute!(con, "DROP TABLE IF EXISTS $(safe_name)")
    view_name = "__iesa_input_ctv_" * table_name
    _duckdb_register_table!(con, df, view_name)
    try
        _duckdb_execute!(con, _create_table_sql(table_name, df; pk = pk, fks = fks))
        _duckdb_execute!(con, "INSERT INTO $(safe_name) SELECT * FROM $(_duckdb_quote_identifier(view_name))")
    finally
        _duckdb_unregister_table!(con, view_name)
    end
    return nothing
end

function _sql_type_for_column(col::AbstractVector)
    T = Base.nonmissingtype(eltype(col))
    T <: Bool          && return "BOOLEAN"
    T <: Integer       && return "INTEGER"
    T <: AbstractFloat && return "DOUBLE"
    return "VARCHAR"
end

function _create_table_sql(table_name::AbstractString, df::DataFrames.DataFrame;
                            pk::Union{Nothing,Vector{Symbol}}, fks::Vector{<:Tuple})
    cols_sql = [
        "$(_duckdb_quote_identifier(String(c))) $(_sql_type_for_column(df[!, c]))"
        for c in Symbol.(DataFrames.names(df))
    ]
    constraints = String[]
    if pk !== nothing && !isempty(pk)
        push!(constraints, "PRIMARY KEY (" * join((_duckdb_quote_identifier(String(c)) for c in pk), ", ") * ")")
    end
    for (col, ref_table, ref_col) in fks
        push!(constraints, "FOREIGN KEY ($(_duckdb_quote_identifier(String(col)))) REFERENCES " *
                            "$(_duckdb_quote_identifier(ref_table))($(_duckdb_quote_identifier(ref_col)))")
    end
    body = join(vcat(cols_sql, constraints), ",\n    ")
    return "CREATE TABLE $(_duckdb_quote_identifier(table_name)) (\n    $(body)\n)"
end

# ============================================================================
# Coercion helpers
# ============================================================================

function _coerce_input_column(vals::AbstractVector)
    T = eltype(vals)
    T <: Symbol         && return String.(vals)
    T <: AbstractString && return collect(String, vals)
    T <: Bool           && return collect(Bool, vals)
    T <: Integer        && return collect(Int, vals)
    T <: AbstractFloat  && return collect(Float64, vals)
    return string.(vals)
end

function _vector_to_input_df(v::AbstractVector)
    isempty(v) && return nothing
    return DataFrames.DataFrame(value = _coerce_input_column(v))
end

function _seq_df(colname::Symbol, values::AbstractVector)
    isempty(values) && return nothing
    df = DataFrames.DataFrame()
    df[!, colname] = _coerce_input_column(values)
    df[!, :seq] = collect(0:length(values)-1)
    return df
end

# ============================================================================
# Derived-subset membership columns
#
# Most ModelSets fields beyond the core entity lists are *derived subsets* of
# one — e.g. tech_flexible/tech_fStorage/tech_hourlyCHPflex are all "is this
# tech_balancer id a member of this category" flags, not raw data of their
# own. Rather than emit ~50 separate one-column tables for these, fold each
# into a boolean column on the entity's own wide table (technologies /
# infrastructure / activities / nodes), matching IESA-Sim's flat-table shape
# instead of scattering membership flags across dozens of tiny tables.
# ============================================================================

const _TECH_SUBSET_FIELDS = Symbol[
    :tech_hourlyDispatch, :tech_dailyDispatch, :tech_flexible, :tech_fStorage, :tech_fEV,
    :tech_fEVcharging, :tech_fEVgrid, :tech_fDRshifting, :tech_fBEshifting, :tech_fWithBattery,
    :tech_flexH, :tech_flexD, :tech_flexR, :tech_flexW, :tech_flexM, :tech_flexS, :tech_flexB,
    :tech_flexY, :tech_flexLT, :tech_shedding, :tech_shedH, :tech_shedW, :tech_reservoir,
    :tech_hourlyCHPflex, :tech_hourlyCHPflexH, :tech_hourlyCHPflexD, :tech_hourlyCHPflexW,
    :tech_gasBuffer, :tech_emission, :tech_materialConversion,
]
const _INFRA_SUBSET_FIELDS = Symbol[:tech_infraH, :tech_infraD]
const _ACTIVITIES_SUBSET_FIELDS = Symbol[
    :activities_solve, :activities_hour, :activities_day, :activities_indirect, :activities_energy,
    :activities_fixEnergy, :activities_balance, :activities_driver, :activities_year, :activities_target,
    :activities_target_FeedStocks, :activities_target_Bunkers, :activities_materialConversion,
    :activities_emission, :activities_emissionFix, :activities_energyNonFixed, :activities_emissionReport,
    :activities_credits, :act_infraH, :act_infraD,
]
const _NODES_SUBSET_FIELDS = Symbol[:nodes_IEM]

function _membership_colname(fieldname::Symbol)::Symbol
    str = String(fieldname)
    for prefix in ("tech_", "activities_", "act_", "nodes_")
        if startswith(str, prefix)
            return Symbol("is_" * str[length(prefix)+1:end])
        end
    end
    return Symbol("is_" * str)
end

function _add_membership_columns!(df::DataFrames.DataFrame, ids::Vector{Symbol}, s::ModelSets, fields::Vector{Symbol})
    for f in fields
        members = Set(getfield(s, f))
        df[!, _membership_colname(f)] = [t in members for t in ids]
    end
    return df
end

# Most fallback ModelSets fields are *derived subsets* of a core entity list
# (activities_hour, tech_flexible, act_infraH, ...) — not raw workbook data of
# their own. Rather than leave dozens of these as disconnected flat tables,
# infer their parent entity from the field-name prefix and add a PK (they're
# sets, so values are unique by construction) plus an FK back to that entity.
# The usual tiered fallback still applies if a value doesn't actually resolve
# (e.g. a mixed-domain set touching both technologies and infrastructure).
function _fallback_set_constraints(tname::AbstractString)
    if tname in ("tech_infraH", "tech_infraD")
        return ([:value], [(:value, "infrastructure", "id")])
    elseif startswith(tname, "tech_")
        return ([:value], [(:value, "technologies", "id")])
    elseif startswith(tname, "activities") || tname in ("act_infraH", "act_infraD")
        return ([:value], [(:value, "activities", "Name")])
    elseif tname == "nodes_IEM"
        return ([:value], [(:value, "nodes", "node")])
    else
        return ([:value], Tuple{Symbol,String,String}[])
    end
end

# ============================================================================
# Generic (fallback) Dict/Vector -> DataFrame conversion
# ============================================================================

function _dict_to_input_df(d::AbstractDict)
    isempty(d) && return nothing
    return valtype(d) <: AbstractVector ? _dict_of_vectors_to_input_df(d) : _dict_scalar_to_input_df(d)
end

function _dict_scalar_to_input_df(d::AbstractDict)
    ks = collect(keys(d))
    vs = collect(values(d))
    df = DataFrames.DataFrame()
    if first(ks) isa Tuple
        for i in 1:length(first(ks))
            df[!, Symbol("key$i")] = _coerce_input_column([k[i] for k in ks])
        end
    else
        df[!, :key] = _coerce_input_column(ks)
    end
    df[!, :value] = _coerce_input_column(vs)
    return df
end

# For Dict{K,Vector} fields (e.g. closure_days_DR, rolling_window_hours_q):
# explode each vector into one row per element, keeping its 1-based position.
function _dict_of_vectors_to_input_df(d::AbstractDict)
    ks = collect(keys(d))
    is_tuple = first(ks) isa Tuple
    n_keys = is_tuple ? length(first(ks)) : 1
    keycols = [Any[] for _ in 1:n_keys]
    idxcol = Int[]
    valcol = Any[]
    for k in ks
        kparts = is_tuple ? k : (k,)
        for (i, elem) in enumerate(d[k])
            for ci in 1:n_keys
                push!(keycols[ci], kparts[ci])
            end
            push!(idxcol, i)
            push!(valcol, elem)
        end
    end
    df = DataFrames.DataFrame()
    for i in 1:n_keys
        df[!, Symbol(n_keys == 1 ? "key" : "key$i")] = _coerce_input_column(keycols[i])
    end
    df[!, :idx] = idxcol
    df[!, :value] = _coerce_input_column(valcol)
    return df
end

# ============================================================================
# Named tuple-keyed Dict -> DataFrame (domain column names instead of key1/key2)
# ============================================================================

function _tuple_dict_to_named_df(d::AbstractDict, colnames::Vector{Symbol}; value_name::Symbol = :value)
    isempty(d) && return nothing
    ks = collect(keys(d))
    vs = collect(values(d))
    parts_of(k) = k isa Tuple ? k : (k,)
    n_keys = length(parts_of(first(ks)))
    @assert n_keys == length(colnames) "expected $(length(colnames)) key columns, got $n_keys"
    df = DataFrames.DataFrame()
    for i in 1:n_keys
        df[!, colnames[i]] = _coerce_input_column([parts_of(k)[i] for k in ks])
    end
    df[!, value_name] = vs
    return df
end

# Long-format (id, period, value...) table built from one or more Dict{Tuple{Symbol,Int},Float64}
# sharing the same (id, period) key space. Missing entries default to 0.0.
function _period_long_df(id_col::Symbol, ids::AbstractVector{Symbol}, periods::AbstractVector{Int},
                          value_dicts::Vector{<:Pair})
    (isempty(ids) || isempty(periods)) && return nothing
    n = length(ids) * length(periods)
    id_out = Vector{String}(undef, n)
    per_out = Vector{Int}(undef, n)
    valcols = Dict{Symbol,Vector{Float64}}(name => Vector{Float64}(undef, n) for (name, _) in value_dicts)
    i = 0
    for id in ids, per in periods
        i += 1
        id_out[i] = String(id)
        per_out[i] = per
        for (name, d) in value_dicts
            valcols[name][i] = get(d, (id, per), 0.0)
        end
    end
    df = DataFrames.DataFrame()
    df[!, id_col] = id_out
    df[!, :period] = per_out
    for (name, _) in value_dicts
        df[!, name] = valcols[name]
    end
    return df
end

# ============================================================================
# Per-sheet table builders
# ============================================================================

function _sectors_df(s::ModelSets, p::ModelParams)
    isempty(s.sectors) && return nothing
    df = DataFrames.DataFrame()
    df[!, :sectors] = String.(s.sectors)
    df[!, :seq] = collect(0:length(s.sectors)-1)
    df[!, :iem_sector] = [haskey(p.IEM_sector, sec) ? String(p.IEM_sector[sec]) : missing for sec in s.sectors]
    return df
end

function _nodes_df(s::ModelSets, p::ModelParams)
    isempty(s.nodes) && return nothing
    df = DataFrames.DataFrame()
    df[!, :node] = String.(s.nodes)
    df[!, :seq] = collect(0:length(s.nodes)-1)
    df[!, :name] = [haskey(p.namePer_node, n) ? String(p.namePer_node[n]) : missing for n in s.nodes]
    df[!, :iem_node] = [haskey(p.IEM_node, n) ? String(p.IEM_node[n]) : missing for n in s.nodes]
    _add_membership_columns!(df, s.nodes, s, _NODES_SUBSET_FIELDS)
    return df
end

function _energy_labels_df(s::ModelSets, p::ModelParams)
    isempty(s.energy_labels) && return nothing
    df = DataFrames.DataFrame()
    df[!, :labels] = String.(s.energy_labels)
    df[!, :seq] = collect(0:length(s.energy_labels)-1)
    df[!, :is_renewable] = [get(p.is_renewable, lbl, missing) for lbl in s.energy_labels]
    return df
end

function _interconnectors_df(p::ModelParams)
    isempty(p.interconnectedHourly_pricesOrig) && return nothing
    ic_names = sort(unique(String(k[2]) for k in keys(p.interconnectedHourly_pricesOrig)))
    isempty(ic_names) && return nothing
    return DataFrames.DataFrame(id = collect(0:length(ic_names)-1), name = ic_names)
end

function _price_profiles_df(p::ModelParams, interconnectors_df)
    interconnectors_df === nothing && return nothing
    isempty(p.interconnectedHourly_pricesOrig) && return nothing
    id_of = Dict(zip(interconnectors_df.name, interconnectors_df.id))
    ks = collect(keys(p.interconnectedHourly_pricesOrig))
    hour_out = Vector{Int}(undef, length(ks))
    ic_out = Vector{Int}(undef, length(ks))
    per_out = Vector{Int}(undef, length(ks))
    price_out = Vector{Float64}(undef, length(ks))
    for (i, (h, act, per)) in enumerate(ks)
        hour_out[i] = h
        ic_out[i] = id_of[String(act)]
        per_out[i] = per
        price_out[i] = p.interconnectedHourly_pricesOrig[(h, act, per)]
    end
    return DataFrames.DataFrame(hour = hour_out, interconnector_id = ic_out, period = per_out, price = price_out)
end

function _node_emission_targets_df(s::ModelSets, p::ModelParams)
    (isempty(s.nodes) || isempty(s.periods)) && return nothing
    return _period_long_df(:node, s.nodes, s.periods, [
        :target_air => p.emissionTargetAir,
        :target_all => p.emissionTargetAll,
        :target_bunker => p.emissionTargetBunker,
        :target_feedstock => p.emissionTargetFS,
    ])
end

function _node_co2_budget_df(s::ModelSets, p::ModelParams)
    isempty(s.nodes) && return nothing
    df = DataFrames.DataFrame()
    df[!, :node] = String.(s.nodes)
    df[!, :cumulative_budget] = [get(p.CO2_cumulative_budget, n, missing) for n in s.nodes]
    df[!, :cumulative_co2_storage] = [get(p.cumulative_CO2storage, n, missing) for n in s.nodes]
    return df
end

# activities.Name (capitalized) + activity_resolution match IESA-Sim's
# activities table naming (activity_resolution there is the same dispatch-
# resolution concept Julia calls dispatchType_act; IESA-Sim's own
# `technologies.dispatch_type` is a different, tech-level field with no
# IESA-Opt.jl counterpart).
function _activities_df(s::ModelSets, p::ModelParams)
    isempty(s.activities_original) && return nothing
    ids = s.activities_original
    sym_col(d) = [haskey(d, a) ? String(d[a]) : missing for a in ids]
    df = DataFrames.DataFrame()
    df[!, :Name] = String.(ids)
    df[!, :seq] = collect(0:length(ids)-1)
    df[!, :unit] = sym_col(p.act_units)
    df[!, :activity_resolution] = sym_col(p.dispatchType_act)
    df[!, :activity_type] = sym_col(p.activityType_act)
    df[!, :node] = sym_col(p.nodePer_act)
    df[!, :emission_target_bin] = sym_col(p.emissionTarget_bin)
    df[!, :energy_label] = sym_col(p.labelPer_act)
    df[!, :act_change_max] = [get(p.actChange_maxOrig, a, missing) for a in ids]
    _add_membership_columns!(df, ids, s, _ACTIVITIES_SUBSET_FIELDS)
    return df
end

function _hours_df(s::ModelSets, p::ModelParams)
    isempty(s.hours_orig) && return nothing
    df = DataFrames.DataFrame()
    df[!, :hour] = collect(s.hours_orig)
    df[!, :seq] = collect(0:length(s.hours_orig)-1)
    df[!, :month] = [get(p.monthPer_hourOrig, h, missing) for h in s.hours_orig]
    return df
end

# Wide technologies table, folding in shedding/flexibility/buffer attributes
# as columns — matching IESA-Sim's flat technologies table shape. Column
# names follow IESA-Sim where a real counterpart exists (hourly_profile,
# flexibility_form/capacity/volume/range/losses/nonnegotiable, buffer_up/
# down/capacity, stock_initial, lifetime); `technical_lifetime`, `wacc`,
# `construction_time`, `ramping`, `process_type`, `change_max` have no
# IESA-Sim counterpart and keep their IESA-Opt.jl names. IESA-Sim's
# social_perception/perceived_complexity/subsidy_subject/feedin_subject/
# stock_deploy/shedding_guarantee are agent-diffusion concepts with no
# IESA-Opt.jl data and are omitted.
function _tech_metadata_df(ids::Vector{Symbol}, s::ModelSets, p::ModelParams)
    isempty(ids) && return nothing
    sym_col(d) = [haskey(d, t) ? String(d[t]) : missing for t in ids]
    val_col(d) = [get(d, t, missing) for t in ids]
    df = DataFrames.DataFrame()
    df[!, :id] = String.(ids)
    df[!, :seq] = collect(0:length(ids)-1)
    df[!, :category] = sym_col(p.tech_category)
    df[!, :sector] = sym_col(p.tech_sector)
    df[!, :subsector] = sym_col(p.tech_subsector)
    df[!, :name] = [haskey(p.tech_name, t) ? p.tech_name[t] : missing for t in ids]
    df[!, :unit] = sym_col(p.tech_units)
    df[!, :activity] = sym_col(p.activityPer_techOrig)
    df[!, :cap2act] = val_col(p.cap2act)
    df[!, :wacc] = val_col(p.WACC)
    df[!, :construction_time] = val_col(p.construction_time)
    df[!, :lifetime] = val_col(p.economic_lifetime)
    df[!, :technical_lifetime] = val_col(p.technical_lifetime)
    df[!, :salvage_value] = val_col(p.Salvage_value)
    df[!, :ramping] = val_col(p.ramping)
    df[!, :process_type] = sym_col(p.processType_tech)
    df[!, :hourly_profile] = sym_col(p.profileType_techRead)
    df[!, :shedding_capacity] = val_col(p.shed_capacity_percentage)
    df[!, :shedding_limits] = val_col(p.shed_volume)
    df[!, :flexibility_form] = sym_col(p.flexibilityType_tech)
    df[!, :flexibility_capacity] = val_col(p.flex_capacity_pct)
    df[!, :flexibility_volume] = val_col(p.flex_storage)
    df[!, :flexibility_range] = sym_col(p.flex_range)
    df[!, :flexibility_losses] = val_col(p.flex_losses_legacy)
    df[!, :flexibility_nonnegotiable] = val_col(p.flex_nnLoad)
    df[!, :buffer_up] = val_col(p.bufferUP_capacity)
    df[!, :buffer_down] = val_col(p.bufferDW_capacity)
    df[!, :buffer_capacity] = val_col(p.buffer_storage)
    df[!, :stock_initial] = val_col(p.techStock_exist)
    df[!, :change_max] = val_col(p.techChange_max)
    _add_membership_columns!(df, ids, s, _TECH_SUBSET_FIELDS)
    return df
end

# Sparse tech -> flexibility-activity coupling, mirroring IESA-Sim's
# technology_flexibility_activities join table.
function _tech_flexibility_activities_df(ids::Vector{Symbol}, p::ModelParams)
    tech_out = String[]
    act_out = String[]
    for t in ids
        haskey(p.flex_activityOrig, t) || continue
        push!(tech_out, String(t))
        push!(act_out, String(p.flex_activityOrig[t]))
    end
    isempty(tech_out) && return nothing
    return DataFrames.DataFrame(tech_id = tech_out, activity_name = act_out)
end

function _tech_stocks_df(ids::Vector{Symbol}, periods::Vector{Int}, p::ModelParams)
    df = _period_long_df(:tech_id, ids, periods, [
        :dec_planned => p.decom_planned,
        :min => p.techStock_min,
        :max => p.techStock_max,
        :use_min => p.techUse_min,
        :use_max => p.techUse_max,
    ])
    df === nothing && return nothing
    df[!, :no_new_invest] = [get(p.no_new_invest, (t, per), false) for t in ids for per in periods]
    df[!, :no_eco_decom] = [get(p.no_eco_decom, (t, per), false) for t in ids for per in periods]
    return df
end

function _infra_metadata_df(ids::Vector{Symbol}, s::ModelSets, p::ModelParams)
    isempty(ids) && return nothing
    sym_col(d) = [haskey(d, t) ? String(d[t]) : missing for t in ids]
    val_col(d) = [get(d, t, missing) for t in ids]
    df = DataFrames.DataFrame()
    df[!, :id] = String.(ids)
    df[!, :seq] = collect(0:length(ids)-1)
    df[!, :category] = sym_col(p.tech_category)
    df[!, :sector] = sym_col(p.tech_sector)
    df[!, :subsector] = sym_col(p.tech_subsector)
    df[!, :name] = [haskey(p.tech_name, t) ? p.tech_name[t] : missing for t in ids]
    df[!, :unit] = sym_col(p.tech_units)
    df[!, :activity] = sym_col(p.infra_activityOrig)
    df[!, :cap2act] = val_col(p.cap2act)
    df[!, :wacc] = val_col(p.WACC)
    df[!, :lifetime] = val_col(p.economic_lifetime)
    df[!, :technical_lifetime] = val_col(p.technical_lifetime)
    df[!, :salvage_value] = val_col(p.Salvage_value)
    df[!, :stock_initial] = val_col(p.techStock_exist)
    df[!, :change_max] = val_col(p.techChange_max)
    df[!, :infra_range] = sym_col(p.infra_range)
    _add_membership_columns!(df, ids, s, _INFRA_SUBSET_FIELDS)
    return df
end

# Only rows enabled in retrofit_relations, and only where both ends resolve to
# a known technology id — mirrors IESA-Sim's own validity filter, which drops
# (and warns about) retrofitting rows referencing unknown tech ids.
function _retrofittings_df(p::ModelParams, valid_tech_ids::Set{String}, mismatches::Vector{String})
    isempty(p.retrofit_cost) && return nothing
    from_out = String[]; to_out = String[]; per_out = Int[]; cost_out = Float64[]
    skipped_pairs = Set{Tuple{String,String}}()
    for ((ft, tt, per), cost) in p.retrofit_cost
        get(p.retrofit_relations, (ft, tt), false) || continue
        if !(String(ft) in valid_tech_ids) || !(String(tt) in valid_tech_ids)
            push!(skipped_pairs, (String(ft), String(tt)))
            continue
        end
        push!(from_out, String(ft)); push!(to_out, String(tt)); push!(per_out, per); push!(cost_out, cost)
    end
    if !isempty(skipped_pairs)
        @warn "write_input_tables_duckdb!: skipped retrofitting rows referencing unknown tech ids" n = length(skipped_pairs)
        push!(mismatches, "table=retrofittings: $(length(skipped_pairs)) row(s) skipped — from_tech/to_tech not found in technologies.id: " *
                           join(("($(ft) -> $(tt))" for (ft, tt) in sort(collect(skipped_pairs))), ", "))
    end
    isempty(from_out) && return nothing
    return DataFrames.DataFrame(from_tech = from_out, to_tech = to_out, period = per_out, cost = cost_out)
end

# Matches IESA-Sim's original_params_short(Name, Value) naming.
function _parameters_scalar_df(p::ModelParams)
    names = ["scenario_description", "base_year", "XC_TransmissionLoss_global",
             "baseload_treshold", "shedding_inLoad", "social_discount_rate", "ActiveConstraintSet"]
    values = [string(p.scenario_description), string(p.base_year), string(p.XC_TransmissionLoss_global),
              string(p.baseload_treshold), string(p.shedding_inLoad), string(p.social_discount_rate),
              string(p.ActiveConstraintSet)]
    return DataFrames.DataFrame(Name = names, Value = values)
end
