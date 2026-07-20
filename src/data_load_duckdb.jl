# =============================================================================
# data_load_duckdb.jl — DuckDB (relational tables) -> ModelData
#
# The reverse of input_tables.jl's write_input_tables_duckdb!. Where that
# function turns a ModelData's raw fields into ~30 named "core" tables plus a
# generic per-field fallback table for everything else, this file reads that
# same schema back into a fresh ModelData's raw fields, then calls the exact
# same derive_sets!/compute_derived_params! the Excel path (read_data) already
# uses to fill in everything derived — so a table produced by
# write_input_tables_duckdb! (directly, or via data_merge.jl's
# merge_or_copy_into) can be solved from without ever touching Excel.
#
# Design principle (confirmed by tracing read_data): read_data = populate raw
# fields -> derive_sets!(md) -> compute_derived_params!(md), both of which are
# pure functions of already-populated md.sets/md.params fields with no
# XLSX-specific state. This loader only has to get the *raw* fields right;
# everything derived (temporal helper sets, tech/activity subset flags,
# financial/investment matrices, CHP_eps, ...) is recomputed unmodified.
#
# What this loader deliberately does NOT do:
#   - Reconstruct the ~53 tech/infra/activities/nodes `is_*` membership
#     columns folded by _add_membership_columns! — always recomputed via
#     derive_sets! instead (reconstructing from the `activities` table's
#     boolean columns is lossy for grouped-activity members, see
#     input_tables.jl's _activities_df).
#   - Populate s.activities / s.hours / s.technologies / p.hourly_profiles —
#     these collide with core table names (input_tables.jl's `reserved_names`
#     check silently drops them, no table exists for them at all) and are
#     recomputed by derive_sets!/compute_derived_params! regardless.
#   - Reconstruct solver_options::Dict{String,Any} — the writer stringifies
#     heterogeneous values (genuinely lossy), and a fresh "run with default
#     settings" never needs a previously-serialized solver config anyway.
# =============================================================================

"""
    read_data_from_duckdb(duckdb_path) -> ModelData

Load a relational IESA-Opt input database (as written by
`write_input_tables_duckdb!` or `data_merge.jl`'s `merge_or_copy_into`) into a
solve-ready `ModelData`, without going through Excel at all.
"""
function read_data_from_duckdb(duckdb_path::AbstractString)::ModelData
    isfile(duckdb_path) || error("DuckDB file not found: $duckdb_path")
    con = _duckdb_connect(duckdb_path; readonly = true)
    try
        md = ModelData()
        s, p = md.sets, md.params
        tables = _duckdb_table_names(con)

        _load_periods!(s, con, tables)
        _load_seq_set!(s, con, tables, "activity_types", :activity_type, :activity_type)
        _load_seq_set!(s, con, tables, "dispatch_types", :dispatch_type, :dispatch_type)
        _load_seq_set!(s, con, tables, "process_types", :process_type, :process_type)
        _load_seq_set!(s, con, tables, "flexibility_types", :flexibility_type, :flexibility_type)
        _load_seq_set!(s, con, tables, "range_types", :range_type, :range_type)
        _load_seq_set!(s, con, tables, "hourly_profile_types", :profile_typeRead, :name)
        _load_sectors!(s, p, con, tables)
        _load_seq_set!(s, con, tables, "sectors_kev", :sectors_kev, :sector_kev)
        _load_nodes!(s, p, con, tables)
        _load_energy_labels!(s, p, con, tables)
        interconnector_name_of_id = _load_interconnectors!(con, tables)

        _load_activities!(s, p, con, tables)
        _load_activity_volumes!(p, con, tables)
        _load_hours!(s, p, con, tables)
        _load_hourly_profiles!(p, con, tables)
        _load_price_profiles!(p, con, tables, interconnector_name_of_id)

        _load_technologies!(s, p, con, tables)
        _load_infrastructure!(s, p, con, tables)
        _load_technology_costs!(p, con, tables)
        _load_infrastructure_costs!(p, con, tables)
        _load_technology_stocks!(p, con, tables)
        _load_infrastructure_stocks!(p, con, tables)
        _load_technology_flexibility_activities!(p, con, tables)

        _load_energy_balance!(p, con, tables)
        _load_retrofittings!(p, con, tables)
        _load_feedstock_use!(p, con, tables)
        _load_activity_efficiency_improvement!(p, con, tables)
        _load_activity_grouping!(p, con, tables)

        _load_node_emission_targets!(p, con, tables)
        _load_node_co2_budget!(p, con, tables)

        _load_parameters_core_scalars!(p, con, tables)
        _load_parameters_scalar_fallback!(p, con, tables)
        _load_generic_fallback_sets!(s, con, tables)
        _load_generic_fallback_params!(p, con, tables)

        derive_sets!(md)
        compute_derived_params!(md)
        return md
    finally
        DBInterface.close!(con)
        GC.gc()
    end
end

function _duckdb_table_names(con)
    return Set{String}(String.(_duckdb_query_df(con, "SELECT table_name FROM information_schema.tables").table_name))
end

# ----------------------------------------------------------------------------
# Small shared casting helpers — DuckDB/DataFrames.jl already hands back
# Int64/Float64/Bool/String matching write_input_tables_duckdb!'s
# _sql_type_for_column, so these are mostly just Symbol(...)/convert(T, ...).
# ----------------------------------------------------------------------------

_cast_scalar(::Type{Symbol}, v) = Symbol(v)
_cast_scalar(::Type{T}, v) where {T<:AbstractString} = T(v)
_cast_scalar(::Type{T}, v::Missing) where {T} = missing
_cast_scalar(::Type{T}, v) where {T<:Integer} = v isa Integer ? T(v) : T(round(Int, v))
_cast_scalar(::Type{T}, v) where {T<:AbstractFloat} = T(v)
_cast_scalar(::Type{Bool}, v) = v isa Bool ? v : (v isa Integer ? v != 0 : parse(Bool, lowercase(string(v))))
_cast_scalar(::Type{Any}, v) = v

# ----------------------------------------------------------------------------
# Core sets: simple one-column (+ seq) tables
# ----------------------------------------------------------------------------

function _load_periods!(s::ModelSets, con, tables::Set{String})
    "periods" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT period FROM periods ORDER BY period_order")
    s.periods = collect(Int, df.period)
    return nothing
end

function _load_seq_set!(s::ModelSets, con, tables::Set{String}, tname::AbstractString, fname::Symbol, colname::Symbol)
    tname in tables || return nothing
    df = _duckdb_query_df(con, "SELECT $(_duckdb_quote_identifier(String(colname))) AS v FROM $(_duckdb_quote_identifier(tname)) ORDER BY seq")
    setfield!(s, fname, Symbol.(df.v))
    return nothing
end

function _load_sectors!(s::ModelSets, p::ModelParams, con, tables::Set{String})
    "sectors" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT sectors, iem_sector FROM sectors ORDER BY seq")
    s.sectors = Symbol.(df.sectors)
    for row in eachrow(df)
        ismissing(row.iem_sector) && continue
        p.IEM_sector[Symbol(row.sectors)] = Symbol(row.iem_sector)
    end
    return nothing
end

function _load_nodes!(s::ModelSets, p::ModelParams, con, tables::Set{String})
    "nodes" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT node, name, iem_node FROM nodes ORDER BY seq")
    s.nodes = Symbol.(df.node)
    for row in eachrow(df)
        ismissing(row.name) || (p.namePer_node[Symbol(row.node)] = Symbol(row.name))
        ismissing(row.iem_node) || (p.IEM_node[Symbol(row.node)] = Symbol(row.iem_node))
    end
    return nothing
end

function _load_energy_labels!(s::ModelSets, p::ModelParams, con, tables::Set{String})
    "energy_labels" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT labels, is_renewable FROM energy_labels ORDER BY seq")
    s.energy_labels = Symbol.(df.labels)
    for row in eachrow(df)
        ismissing(row.is_renewable) || (p.is_renewable[Symbol(row.labels)] = Bool(row.is_renewable))
    end
    return nothing
end

# Returns id -> name (Symbol) so _load_price_profiles! can turn interconnector_id
# back into the activity-name key interconnectedHourly_pricesOrig uses.
function _load_interconnectors!(con, tables::Set{String})
    "interconnectors" in tables || return Dict{Int,Symbol}()
    df = _duckdb_query_df(con, "SELECT id, name FROM interconnectors")
    return Dict{Int,Symbol}(Int(row.id) => Symbol(row.name) for row in eachrow(df))
end

# ----------------------------------------------------------------------------
# Activities
# ----------------------------------------------------------------------------

function _load_activities!(s::ModelSets, p::ModelParams, con, tables::Set{String})
    "activities" in tables || return nothing
    df = _duckdb_query_df(con, """
        SELECT "Name", "UoA", activity_resolution, activity_type, "Node", "Target", energy_label, act_change_max
        FROM activities ORDER BY seq
    """)
    s.activities_original = Symbol.(df.Name)
    for row in eachrow(df)
        a = Symbol(row.Name)
        ismissing(row.UoA) || (p.act_units[a] = Symbol(row.UoA))
        ismissing(row.activity_resolution) || (p.dispatchType_act[a] = Symbol(row.activity_resolution))
        ismissing(row.activity_type) || (p.activityType_act[a] = Symbol(row.activity_type))
        ismissing(row.Node) || (p.nodePer_act[a] = Symbol(row.Node))
        ismissing(row.Target) || (p.emissionTarget_bin[a] = Symbol(string(Int(row.Target))))
        ismissing(row.energy_label) || (p.labelPer_act[a] = Symbol(row.energy_label))
        ismissing(row.act_change_max) || (p.actChange_maxOrig[a] = Float64(row.act_change_max))
    end
    return nothing
end

function _load_activity_volumes!(p::ModelParams, con, tables::Set{String})
    "activity_volumes" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT activity_name, period, value FROM activity_volumes")
    for row in eachrow(df)
        ismissing(row.value) && continue
        p.activities_netVolumesOrig[(Symbol(row.activity_name), Int(row.period))] = Float64(row.value)
    end
    return nothing
end

function _load_hours!(s::ModelSets, p::ModelParams, con, tables::Set{String})
    "hours" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT hour, month FROM hours ORDER BY seq")
    s.hours_orig = collect(Int, df.hour)
    for row in eachrow(df)
        ismissing(row.month) || (p.monthPer_hourOrig[Int(row.hour)] = Int(row.month))
    end
    return nothing
end

function _load_hourly_profiles!(p::ModelParams, con, tables::Set{String})
    "hourly_profiles" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT hour, profile_type, value FROM hourly_profiles")
    for row in eachrow(df)
        ismissing(row.value) && continue
        p.hourly_profilesReadOrig[(Int(row.hour), Symbol(row.profile_type))] = Float64(row.value)
    end
    return nothing
end

function _load_price_profiles!(p::ModelParams, con, tables::Set{String}, interconnector_name_of_id::Dict{Int,Symbol})
    "price_profiles" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT hour, interconnector_id, period, price FROM price_profiles")
    for row in eachrow(df)
        name = get(interconnector_name_of_id, Int(row.interconnector_id), nothing)
        name === nothing && continue
        p.interconnectedHourly_pricesOrig[(Int(row.hour), name, Int(row.period))] = Float64(row.price)
    end
    return nothing
end

# ----------------------------------------------------------------------------
# Technologies / infrastructure — both feed the SAME p.tech_* dicts (shared
# namespace across tech_balancers and tech_infra ids), matching
# input_tables.jl's _tech_metadata_df/_infra_metadata_df, which both draw from
# the very same dicts. Fields present on only one side are noted below.
# ----------------------------------------------------------------------------

function _load_technologies!(s::ModelSets, p::ModelParams, con, tables::Set{String})
    "technologies" in tables || return nothing
    df = _duckdb_query_df(con, """
        SELECT id, category, sector, subsector, sector_kev, name, unit, activity, cap2act, wacc,
               construction_time, lifetime, technical_lifetime, salvage_value, ramping,
               process_type, hourly_profile, shedding_capacity, shedding_limits,
               flexibility_form, flexibility_capacity, flexibility_volume, flexibility_range,
               flexibility_losses, flexibility_nonnegotiable, buffer_up, buffer_down,
               buffer_capacity, stock_initial, change_max
        FROM technologies ORDER BY seq
    """)
    s.tech_balancers = Symbol.(df.id)
    for row in eachrow(df)
        t = Symbol(row.id)
        ismissing(row.category) || (p.tech_category[t] = Symbol(row.category))
        ismissing(row.sector) || (p.tech_sector[t] = Symbol(row.sector))
        ismissing(row.subsector) || (p.tech_subsector[t] = Symbol(row.subsector))
        ismissing(row.sector_kev) || (p.tech_sector_kev[t] = Symbol(row.sector_kev))
        ismissing(row.name) || (p.tech_name[t] = String(row.name))
        ismissing(row.unit) || (p.tech_units[t] = Symbol(row.unit))
        ismissing(row.activity) || (p.activityPer_techOrig[t] = Symbol(row.activity))
        ismissing(row.cap2act) || (p.cap2act[t] = Float64(row.cap2act))
        ismissing(row.wacc) || (p.WACC[t] = Float64(row.wacc))
        ismissing(row.construction_time) || (p.construction_time[t] = Float64(row.construction_time))
        ismissing(row.lifetime) || (p.economic_lifetime[t] = Float64(row.lifetime))
        ismissing(row.technical_lifetime) || (p.technical_lifetime[t] = Float64(row.technical_lifetime))
        ismissing(row.salvage_value) || (p.Salvage_value[t] = Float64(row.salvage_value))
        ismissing(row.ramping) || (p.ramping[t] = Float64(row.ramping))
        ismissing(row.process_type) || (p.processType_tech[t] = Symbol(row.process_type))
        ismissing(row.hourly_profile) || (p.profileType_techRead[t] = Symbol(row.hourly_profile))
        ismissing(row.shedding_capacity) || (p.shed_capacity_percentage[t] = Float64(row.shedding_capacity))
        ismissing(row.shedding_limits) || (p.shed_volume[t] = Float64(row.shedding_limits))
        ismissing(row.flexibility_form) || (p.flexibilityType_tech[t] = Symbol(row.flexibility_form))
        ismissing(row.flexibility_capacity) || (p.flex_capacity_pct[t] = Float64(row.flexibility_capacity))
        ismissing(row.flexibility_volume) || (p.flex_storage[t] = Float64(row.flexibility_volume))
        ismissing(row.flexibility_range) || (p.flex_range[t] = Symbol(row.flexibility_range))
        ismissing(row.flexibility_losses) || (p.flex_losses_legacy[t] = Float64(row.flexibility_losses))
        ismissing(row.flexibility_nonnegotiable) || (p.flex_nnLoad[t] = Float64(row.flexibility_nonnegotiable))
        ismissing(row.buffer_up) || (p.bufferUP_capacity[t] = Float64(row.buffer_up))
        ismissing(row.buffer_down) || (p.bufferDW_capacity[t] = Float64(row.buffer_down))
        ismissing(row.buffer_capacity) || (p.buffer_storage[t] = Float64(row.buffer_capacity))
        ismissing(row.stock_initial) || (p.techStock_exist[t] = Float64(row.stock_initial))
        ismissing(row.change_max) || (p.techChange_max[t] = Float64(row.change_max))
    end
    return nothing
end

function _load_infrastructure!(s::ModelSets, p::ModelParams, con, tables::Set{String})
    "infrastructure" in tables || return nothing
    df = _duckdb_query_df(con, """
        SELECT id, category, sector, subsector, sector_kev, name, unit, activity, cap2act, wacc,
               lifetime, technical_lifetime, salvage_value, stock_initial, change_max, infra_range
        FROM infrastructure ORDER BY seq
    """)
    s.tech_infra = Symbol.(df.id)
    for row in eachrow(df)
        t = Symbol(row.id)
        ismissing(row.category) || (p.tech_category[t] = Symbol(row.category))
        ismissing(row.sector) || (p.tech_sector[t] = Symbol(row.sector))
        ismissing(row.subsector) || (p.tech_subsector[t] = Symbol(row.subsector))
        ismissing(row.sector_kev) || (p.tech_sector_kev[t] = Symbol(row.sector_kev))
        ismissing(row.name) || (p.tech_name[t] = String(row.name))
        ismissing(row.unit) || (p.tech_units[t] = Symbol(row.unit))
        ismissing(row.activity) || (p.infra_activityOrig[t] = Symbol(row.activity))
        ismissing(row.cap2act) || (p.cap2act[t] = Float64(row.cap2act))
        ismissing(row.wacc) || (p.WACC[t] = Float64(row.wacc))
        ismissing(row.lifetime) || (p.economic_lifetime[t] = Float64(row.lifetime))
        ismissing(row.technical_lifetime) || (p.technical_lifetime[t] = Float64(row.technical_lifetime))
        ismissing(row.salvage_value) || (p.Salvage_value[t] = Float64(row.salvage_value))
        ismissing(row.stock_initial) || (p.techStock_exist[t] = Float64(row.stock_initial))
        ismissing(row.change_max) || (p.techChange_max[t] = Float64(row.change_max))
        ismissing(row.infra_range) || (p.infra_range[t] = Symbol(row.infra_range))
    end
    return nothing
end

function _load_technology_costs!(p::ModelParams, con, tables::Set{String})
    "technology_costs" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT tech_id, period, investment, fom, vom FROM technology_costs")
    for row in eachrow(df)
        t, per = Symbol(row.tech_id), Int(row.period)
        ismissing(row.investment) || (p.inv_cost[(t, per)] = Float64(row.investment))
        ismissing(row.fom) || (p.fom_cost[(t, per)] = Float64(row.fom))
        ismissing(row.vom) || (p.vom_cost[(t, per)] = Float64(row.vom))
    end
    return nothing
end

function _load_infrastructure_costs!(p::ModelParams, con, tables::Set{String})
    "infrastructure_costs" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT infra_id, period, investment, fom FROM infrastructure_costs")
    for row in eachrow(df)
        t, per = Symbol(row.infra_id), Int(row.period)
        ismissing(row.investment) || (p.inv_cost[(t, per)] = Float64(row.investment))
        ismissing(row.fom) || (p.fom_cost[(t, per)] = Float64(row.fom))
    end
    return nothing
end

function _load_technology_stocks!(p::ModelParams, con, tables::Set{String})
    "technology_stocks" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT tech_id, period, dec_planned, min, max, use_min, use_max, no_new_invest, no_eco_decom FROM technology_stocks")
    for row in eachrow(df)
        t, per = Symbol(row.tech_id), Int(row.period)
        ismissing(row.dec_planned) || (p.decom_planned[(t, per)] = Float64(row.dec_planned))
        ismissing(row.min) || (p.techStock_min[(t, per)] = Float64(row.min))
        ismissing(row.max) || (p.techStock_max[(t, per)] = Float64(row.max))
        ismissing(row.use_min) || (p.techUse_min[(t, per)] = Float64(row.use_min))
        ismissing(row.use_max) || (p.techUse_max[(t, per)] = Float64(row.use_max))
        p.no_new_invest[(t, per)] = ismissing(row.no_new_invest) ? false : Bool(row.no_new_invest)
        p.no_eco_decom[(t, per)] = ismissing(row.no_eco_decom) ? false : Bool(row.no_eco_decom)
    end
    return nothing
end

function _load_infrastructure_stocks!(p::ModelParams, con, tables::Set{String})
    "infrastructure_stocks" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT infra_id, period, dec_planned, min, max FROM infrastructure_stocks")
    for row in eachrow(df)
        t, per = Symbol(row.infra_id), Int(row.period)
        ismissing(row.dec_planned) || (p.decom_planned[(t, per)] = Float64(row.dec_planned))
        ismissing(row.min) || (p.techStock_min[(t, per)] = Float64(row.min))
        ismissing(row.max) || (p.techStock_max[(t, per)] = Float64(row.max))
    end
    return nothing
end

function _load_technology_flexibility_activities!(p::ModelParams, con, tables::Set{String})
    "technology_flexibility_activities" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT tech_id, activity_name FROM technology_flexibility_activities")
    for row in eachrow(df)
        p.flex_activityOrig[Symbol(row.tech_id)] = Symbol(row.activity_name)
    end
    return nothing
end

# ----------------------------------------------------------------------------
# Relations
# ----------------------------------------------------------------------------

function _load_energy_balance!(p::ModelParams, con, tables::Set{String})
    "energy_balance" in tables || return nothing
    # No PK by design (data_merge.jl's shared-table registry deliberately
    # excludes `period` from the join key so a merged source's period-less
    # IESA-Sim rows don't collide with IESA-Opt's legitimately-repeated
    # (tech_id, activity_name) rows across periods) — filter NULL periods
    # (only possible from a merge against a period-less source) and let a
    # later row win on any true duplicate key.
    df = _duckdb_query_df(con, "SELECT tech_id, activity_name, period, value FROM energy_balance WHERE period IS NOT NULL")
    for row in eachrow(df)
        ismissing(row.value) && continue
        p.activity_balancesRef[(Symbol(row.tech_id), Symbol(row.activity_name), Int(row.period))] = Float64(row.value)
    end
    return nothing
end

function _load_retrofittings!(p::ModelParams, con, tables::Set{String})
    "retrofittings" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT from_tech, to_tech, period, cost FROM retrofittings WHERE period IS NOT NULL")
    for row in eachrow(df)
        ft, tt = Symbol(row.from_tech), Symbol(row.to_tech)
        p.retrofit_relations[(ft, tt)] = true
        ismissing(row.cost) || (p.retrofit_cost[(ft, tt, Int(row.period))] = Float64(row.cost))
    end
    return nothing
end

function _load_feedstock_use!(p::ModelParams, con, tables::Set{String})
    "feedstock_use" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT tech_id, activity_name, fraction FROM feedstock_use")
    for row in eachrow(df)
        ismissing(row.fraction) && continue
        p.feedstockUse_techOrig[(Symbol(row.tech_id), Symbol(row.activity_name))] = Float64(row.fraction)
    end
    return nothing
end

function _load_activity_efficiency_improvement!(p::ModelParams, con, tables::Set{String})
    "activity_efficiency_improvement" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT tech_id, activity_name, period, value FROM activity_efficiency_improvement")
    for row in eachrow(df)
        ismissing(row.value) && continue
        p.activity_EffImprov[(Symbol(row.tech_id), Symbol(row.activity_name), Int(row.period))] = Float64(row.value)
    end
    return nothing
end

function _load_activity_grouping!(p::ModelParams, con, tables::Set{String})
    "activity_grouping" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT activity_original, activity_group FROM activity_grouping")
    for row in eachrow(df)
        ismissing(row.activity_group) && continue
        p.act_to_group[Symbol(row.activity_original)] = Symbol(row.activity_group)
    end
    return nothing
end

function _load_node_emission_targets!(p::ModelParams, con, tables::Set{String})
    "node_emission_targets" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT node, period, target_air, target_all, target_bunker, target_feedstock FROM node_emission_targets")
    for row in eachrow(df)
        n, per = Symbol(row.node), Int(row.period)
        ismissing(row.target_air) || (p.emissionTargetAir[(n, per)] = Float64(row.target_air))
        ismissing(row.target_all) || (p.emissionTargetAll[(n, per)] = Float64(row.target_all))
        ismissing(row.target_bunker) || (p.emissionTargetBunker[(n, per)] = Float64(row.target_bunker))
        ismissing(row.target_feedstock) || (p.emissionTargetFS[(n, per)] = Float64(row.target_feedstock))
    end
    return nothing
end

function _load_node_co2_budget!(p::ModelParams, con, tables::Set{String})
    "node_co2_budget" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT node, cumulative_budget, cumulative_co2_storage FROM node_co2_budget")
    for row in eachrow(df)
        n = Symbol(row.node)
        ismissing(row.cumulative_budget) || (p.CO2_cumulative_budget[n] = Float64(row.cumulative_budget))
        ismissing(row.cumulative_co2_storage) || (p.cumulative_CO2storage[n] = Float64(row.cumulative_co2_storage))
    end
    return nothing
end

# "parameters" — the 7 named scalars written verbatim by _parameters_scalar_df.
function _load_parameters_core_scalars!(p::ModelParams, con, tables::Set{String})
    "parameters" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT \"Name\", \"Value\" FROM parameters")
    values = Dict{String,String}(String(row.Name) => String(row.Value) for row in eachrow(df))
    haskey(values, "scenario_description") && (p.scenario_description = values["scenario_description"])
    haskey(values, "base_year") && (p.base_year = parse(Int, values["base_year"]))
    haskey(values, "XC_TransmissionLoss_global") && (p.XC_TransmissionLoss_global = parse(Float64, values["XC_TransmissionLoss_global"]))
    haskey(values, "baseload_treshold") && (p.baseload_treshold = parse(Float64, values["baseload_treshold"]))
    haskey(values, "shedding_inLoad") && (p.shedding_inLoad = parse(Float64, values["shedding_inLoad"]))
    haskey(values, "social_discount_rate") && (p.social_discount_rate = parse(Float64, values["social_discount_rate"]))
    haskey(values, "ActiveConstraintSet") && (p.ActiveConstraintSet = values["ActiveConstraintSet"])
    return nothing
end

# ----------------------------------------------------------------------------
# Generic fallback loaders — the reflective counterpart to input_tables.jl's
# generic fallback writer (lines ~176-219). Table name == field name (or
# "param_"+field name when a ModelParams Dict field's name collided with a
# ModelSets field's own fallback table — see input_tables.jl:210).
# ----------------------------------------------------------------------------

# Fields that collide with a core table's literal name (write side silently
# drops them — no table exists at all) and are always recomputed by
# derive_sets!/compute_derived_params!, never reconstructed here.
const _DUCKDB_LOADER_SKIP_SETS = Set{Symbol}([:activities, :hours, :technologies])
const _DUCKDB_LOADER_SKIP_PARAMS = Set{Symbol}([:hourly_profiles, :solver_options])

const _DUCKDB_CORE_SETS = Set{Symbol}(vcat(
    [:periods, :dispatch_type, :activity_type, :process_type, :flexibility_type, :range_type,
     :profile_typeRead, :sectors, :sectors_kev, :nodes, :energy_labels,
     :activities_original, :hours_orig, :tech_balancers, :tech_infra],
    _TECH_SUBSET_FIELDS, _INFRA_SUBSET_FIELDS, _ACTIVITIES_SUBSET_FIELDS, _NODES_SUBSET_FIELDS,
))
const _DUCKDB_CORE_PARAMS = Set{Symbol}([
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

function _load_generic_fallback_sets!(s::ModelSets, con, tables::Set{String})
    for fname in fieldnames(ModelSets)
        (fname in _DUCKDB_CORE_SETS || fname in _DUCKDB_LOADER_SKIP_SETS) && continue
        tname = String(fname)
        tname in tables || continue
        df = _duckdb_query_df(con, "SELECT value FROM $(_duckdb_quote_identifier(tname))")
        FT = fieldtype(ModelSets, fname)
        ET = eltype(FT)
        setfield!(s, fname, ET[_cast_scalar(ET, v) for v in df.value])
    end
    return nothing
end

function _load_generic_fallback_params!(p::ModelParams, con, tables::Set{String})
    set_field_names = Set{String}(String(f) for f in fieldnames(ModelSets))
    for fname in fieldnames(ModelParams)
        (fname in _DUCKDB_CORE_PARAMS || fname in _DUCKDB_LOADER_SKIP_PARAMS) && continue
        FT = fieldtype(ModelParams, fname)
        FT <: AbstractDict || continue  # non-Dict scalars are handled by _load_parameters_scalar_fallback!
        tname = String(fname)
        tname in set_field_names && (tname = "param_" * tname)
        tname in tables || continue
        _load_fallback_dict_field!(p, fname, FT, con, tname)
    end
    return nothing
end

function _load_fallback_dict_field!(p::ModelParams, fname::Symbol, ::Type{Dict{K,V}}, con, tname::String) where {K,V}
    df = _duckdb_query_df(con, "SELECT * FROM $(_duckdb_quote_identifier(tname))")
    isempty(df) && return nothing
    cols = Set(String.(names(df)))
    n_keys = K <: Tuple ? length(K.parameters) : 1
    key_of(row) = K <: Tuple ? Tuple(_cast_scalar(K.parameters[i], row[Symbol(n_keys == 1 ? "key" : "key$i")]) for i in 1:n_keys) :
                                _cast_scalar(K, row[Symbol("key")])

    if V <: AbstractVector
        EV = eltype(V)
        grouped = Dict{K,Vector{Tuple{Int,EV}}}()
        for row in eachrow(df)
            k = key_of(row)
            push!(get!(grouped, k, Tuple{Int,EV}[]), (Int(row.idx), _cast_scalar(EV, row.value)))
        end
        d = getfield(p, fname)::Dict{K,V}
        for (k, items) in grouped
            sort!(items; by = first)
            d[k] = V(last.(items))
        end
    else
        d = getfield(p, fname)::Dict{K,V}
        for row in eachrow(df)
            ismissing(row.value) && continue
            d[key_of(row)] = _cast_scalar(V, row.value)
        end
    end
    return nothing
end

# Non-Dict ModelParams fields not in core_params all land in one shared
# "parameters_scalar" table (name, value, julia_type) — dispatch the cast by
# the julia_type string rather than fieldtype alone, since a handful of these
# (e.g. clustering_approach::Symbol) need Symbol(...) rather than passthrough.
function _load_parameters_scalar_fallback!(p::ModelParams, con, tables::Set{String})
    "parameters_scalar" in tables || return nothing
    df = _duckdb_query_df(con, "SELECT name, value, julia_type FROM parameters_scalar")
    for row in eachrow(df)
        fname = Symbol(row.name)
        hasfield(ModelParams, fname) || continue
        (fname in _DUCKDB_CORE_PARAMS || fname in _DUCKDB_LOADER_SKIP_PARAMS) && continue
        FT = fieldtype(ModelParams, fname)
        FT <: AbstractDict && continue  # only true scalars are written here
        try
            setfield!(p, fname, _cast_parameters_scalar(FT, String(row.julia_type), String(row.value)))
        catch err
            @warn "read_data_from_duckdb: failed to cast parameters_scalar field, leaving at default" fname julia_type = row.julia_type err = err
        end
    end
    return nothing
end

function _cast_parameters_scalar(::Type{T}, julia_type::String, raw::String) where {T}
    T === Symbol && return Symbol(raw)
    T === Bool && return parse(Bool, lowercase(raw))
    T <: Integer && return parse(T, raw)
    T <: AbstractFloat && return parse(T, raw)
    T <: AbstractString && return raw
    return raw
end
