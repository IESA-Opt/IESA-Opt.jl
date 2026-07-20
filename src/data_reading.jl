# =============================================================================
# data_reading.jl — Read IESA-Opt Excel workbook into ModelSets + ModelParams
#
# Reads the workbook layout used by IESA-Opt into Symbol-keyed Julia data
# structures. The XLSX layout matches the IESA-Opt 1.0 reader
# (`Procedure DataReading` in `MainProject/IESA-Opt.ams`).
#
# Sheet → ModelParams/ModelSets mapping:
#   "IESA-Opt database" → scenario_description
#   "Parameters"        → scalars
#   "Types"             → dispatch/activity/process/flexibility/range/sector
#                         enumerations + node maps
#   "NodeParameters"    → emission targets
#   "Activities"        → activities_original + per-activity metadata + net
#                         volumes
#   "HourlyProfiles"    → hours_orig + profile_typeRead + raw 8760 profiles
#   "Technologies"      → tech_balancers + ~40 per-tech parameters
#   "EnergyBalance"     → activity_balancesRef
#   "Infrastructure"    → tech_infra + infra-specific params (merged into
#                         tech_* dicts)
#   "PriceProfiles"     → interconnectedHourly_pricesOrig
#   "ActGrouping"       → activities_group + act_to_group
#   "EffLearning"       → activity_EffImprov
#   "Feedstocks"        → feedstockUse_techOrig
#   "Retrofitting"      → retrofit_relations, retrofit_cost
# =============================================================================

# -----------------------------------------------------------------------------
# Top-level entry
# -----------------------------------------------------------------------------

"""
    read_data(xlsx_path::AbstractString;
              periods::Vector{Int} = [2022, 2025, 2030, 2035, 2040, 2045, 2050],
              periods_solve::Union{Nothing,Vector{Int}} = nothing) -> ModelData

Open the IESA-Opt Excel workbook at `xlsx_path` and populate a `ModelData`
(bundle of `ModelSets` + `ModelParams`). After reading, derived sets
(`derive_sets!`) and derived parameters (`compute_derived_params!`) are
computed.

If `periods_solve` is `nothing`, defaults to a copy of `periods`.
"""
function read_data(xlsx_path::AbstractString;
                   periods::Vector{Int} = [2022, 2025, 2030, 2035, 2040, 2045, 2050],
                   periods_solve::Union{Nothing,Vector{Int}} = nothing)

    isfile(xlsx_path) || error("XLSX not found: $xlsx_path")

    md = ModelData()
    s, p = md.sets, md.params
    s.periods = copy(periods)
    s.periods_solve = periods_solve === nothing ? copy(periods) : copy(periods_solve)

    @info "read_data: opening workbook" path=xlsx_path
    flush(stderr)
    XLSX.openxlsx(xlsx_path, mode="r") do xf
        _logsheet("IESA-Opt database");   _read_iesa_opt_database!(s, p, xf)
        _logsheet("Parameters");          _read_parameters_sheet!(s, p, xf)
        _logsheet("Types");               _read_types_sheet!(s, p, xf)
        _logsheet("NodeParameters");      _read_node_parameters_sheet!(s, p, xf)
        _logsheet("Activities");          _read_activities_sheet!(s, p, xf)
        _logsheet("HourlyProfiles");      _read_hourly_profiles_sheet!(s, p, xf)
        _logsheet("Technologies");        _read_technologies_sheet!(s, p, xf)
        _logsheet("EnergyBalance");       _read_energy_balance_sheet!(s, p, xf)
        _logsheet("Infrastructure");      _read_infrastructure_sheet!(s, p, xf)
        _logsheet("PriceProfiles");       _read_price_profiles_sheet!(s, p, xf)
        _logsheet("ActGrouping");         _read_act_grouping_sheet!(s, p, xf)
        _logsheet("EffLearning");         _read_eff_learning_sheet!(s, p, xf)
        _logsheet("Feedstocks");          _read_feedstocks_sheet!(s, p, xf)
        _logsheet("Retrofitting");        _read_retrofitting_sheet!(s, p, xf)
    end

    @info "read_data: deriving sets and parameters"
    derive_sets!(md)
    compute_derived_params!(md)

    @info "read_data: complete" technologies=length(s.technologies) activities=length(s.activities_original) periods=length(s.periods)

    try
        tables_db_path = _duckdb_input_cache_path(xlsx_path, joinpath(dirname(abspath(xlsx_path)), ".iesa_cache"))
        write_input_tables_duckdb!(md, tables_db_path)
    catch err
        @warn "read_data: failed to write input tables to DuckDB" err = err
    end

    return md
end

# -----------------------------------------------------------------------------
# Sheet readers
# -----------------------------------------------------------------------------

function _read_iesa_opt_database!(s::ModelSets, p::ModelParams, xf)
    sh = xf["IESA-Opt database"]
    # Document-title cell, not part of any tabular header — no named-column
    # lookup applies here.
    p.scenario_description = _str(sh["E21"])
    return nothing
end

function _read_parameters_sheet!(s::ModelSets, p::ModelParams, xf)
    sh = xf["Parameters"]
    C = ColumnNames.Parameters
    # One named scalar per row (column A = Name, column B = Value) — the
    # transposed counterpart of the column-header lookup used elsewhere.
    row(name) = _row_by_name(sh, 1, name; r_start = 4, r_end = 60)
    p.XC_TransmissionLoss_global = _float(sh[row(C.xc_transmission_loss), 2])
    p.baseload_treshold          = _float(sh[row(C.baseload_threshold), 2])
    p.shedding_inLoad            = _float(sh[row(C.shedding_in_load), 2])
    p.social_discount_rate       = _float(sh[row(C.social_discount_rate), 2])
    p.base_year                  = _int(sh[row(C.base_year), 2])
    p.ActiveConstraintSet        = _str(sh[row(C.active_constraint_set), 2])
    return nothing
end

function _read_types_sheet!(s::ModelSets, p::ModelParams, xf)
    sh = xf["Types"]
    last_row = _last_row(sh, "A")
    hdr = _header_row_texts(sh, 2, _col_index(_last_col(sh)))
    C = ColumnNames.Types

    s.dispatch_type    = _read_column_symbols(sh, _hcol(hdr, C.dispatch_type), 4, last_row)
    s.activity_type    = _read_column_symbols(sh, _hcol(hdr, C.activity_type), 4, last_row)
    s.process_type     = _read_column_symbols(sh, _hcol(hdr, C.process_type), 4, last_row)
    s.flexibility_type = _read_column_symbols(sh, _hcol(hdr, C.flexibility_type), 4, last_row)
    s.range_type       = _read_column_symbols(sh, _hcol(hdr, C.range_type), 4, last_row)
    s.sectors          = _read_column_symbols(sh, _hcol(hdr, C.sectors), 4, last_row)
    s.nodes            = _read_column_symbols(sh, _hcol(hdr, C.nodes), 4, last_row)
    s.node_names       = _read_column_symbols(sh, _hcol(hdr, C.node_name), 4, last_row)
    s.energy_labels    = _read_column_symbols(sh, _hcol(hdr, C.energy_labels), 4, last_row)
    s.sectors_kev      = _read_column_symbols(sh, _hcol(hdr, C.sectors_kev), 4, last_row)

    col_sectors = _hcol(hdr, C.sectors)
    col_nodes   = _hcol(hdr, C.nodes)
    col_labels  = _hcol(hdr, C.energy_labels)
    _read_list_to_sym!(p.IEM_sector,   sh, col_sectors, _hcol(hdr, C.iem_sector), 4, last_row)
    _read_list_to_sym!(p.namePer_node, sh, col_nodes,   _hcol(hdr, C.node_name), 4, last_row)
    _read_list_to_sym!(p.IEM_node,     sh, col_nodes,   _hcol(hdr, C.iem_node), 4, last_row)
    _read_list_to_float!(p.is_renewable, sh, col_labels, _hcol(hdr, C.is_renewable), 4, last_row)
    return nothing
end

function _read_node_parameters_sheet!(s::ModelSets, p::ModelParams, xf)
    sh = xf["NodeParameters"]
    last_row = _last_row(sh, "A")
    last_col_idx = _col_index(_last_col(sh))
    hdr_group = _header_row_texts(sh, 2, last_col_idx)  # emission-target block anchors
    hdr_row4  = _header_row_texts(sh, 4, last_col_idx)  # "Node" field label
    C = ColumnNames.NodeParameters

    # Each emission-target block is 7 columns (2022-2050) with no distinct
    # row-3 field name of its own — only the row-2 group label identifies it.
    block(name) = begin
        start_idx = _col_by_header(hdr_group, name)
        (_col_letter(start_idx), _col_letter(start_idx + 6))
    end

    col_node = _hcol(hdr_row4, C.node)
    nodes_col = _read_column_symbols(sh, col_node, 5, last_row)

    col_air, col_air_end = block(C.emission_target_air)
    period_hdr_B = _read_row_ints(sh, 3, col_air, col_air_end)
    _read_table_sym_int_to_float!(p.emissionTargetAir, sh, nodes_col, period_hdr_B, col_air, 5, last_row;
                                  keep_zeros=true)

    _read_column_to_float_dict_sym!(p.CO2_cumulative_budget,  sh, col_node, _hcol(hdr_group, C.cumulative_emission_budget), 5, last_row)
    _read_column_to_float_dict_sym!(p.cumulative_CO2storage,  sh, col_node, _hcol(hdr_group, C.cumulative_co2_storage), 5, last_row)

    col_all, col_all_end = block(C.emission_target_all)
    period_hdr_R = _read_row_ints(sh, 3, col_all, col_all_end)
    _read_table_sym_int_to_float!(p.emissionTargetAll, sh, nodes_col, period_hdr_R, col_all, 5, last_row;
                                  keep_zeros=true)

    col_bunker, col_bunker_end = block(C.emission_target_bunker)
    period_hdr_Y = _read_row_ints(sh, 3, col_bunker, col_bunker_end)
    _read_table_sym_int_to_float!(p.emissionTargetBunker, sh, nodes_col, period_hdr_Y, col_bunker, 5, last_row;
                                  keep_zeros=true)

    col_fs, col_fs_end = block(C.emission_target_feedstock)
    period_hdr_AF = _read_row_ints(sh, 3, col_fs, col_fs_end)
    _read_table_sym_int_to_float!(p.emissionTargetFS, sh, nodes_col, period_hdr_AF, col_fs, 5, last_row;
                                  keep_zeros=true)
    return nothing
end

function _read_activities_sheet!(s::ModelSets, p::ModelParams, xf)
    sh = xf["Activities"]
    last_row = _last_row(sh, "A")
    # The sheet's real per-column header spans two rows here (7=group, 8=field);
    # rows 1-6 hold a separate "external drivers" mini-table with far fewer
    # columns, so the header width must be measured at row 8, not via `_last_col`.
    last_col_idx = _col_index(_last_col_at_row(sh, 8))
    hdr_group = _header_row_texts(sh, 7, last_col_idx)
    hdr_field = _header_row_texts(sh, 8, last_col_idx)
    C = ColumnNames.Activities

    col_name = _hcol(hdr_field, C.name)
    s.activities_original = _read_column_symbols(sh, col_name, 9, last_row)

    _read_list_to_sym!(p.act_units,           sh, col_name, _hcol(hdr_field, C.unit), 9, last_row)
    _read_list_to_float!(p.actChange_maxOrig, sh, col_name, _hcol(hdr_group, C.change_max), 9, last_row)
    _read_list_to_sym!(p.dispatchType_act,    sh, col_name, _hcol(hdr_group, C.dispatch_resolution), 9, last_row)
    _read_list_to_sym!(p.activityType_act,    sh, col_name, _hcol(hdr_group, C.activity_type), 9, last_row)
    _read_list_to_sym!(p.nodePer_act,         sh, col_name, _hcol(hdr_group, C.node), 9, last_row)
    _read_list_to_sym!(p.emissionTarget_bin,  sh, col_name, _hcol(hdr_group, C.emission_target_bin), 9, last_row)
    _read_list_to_sym!(p.labelPer_act,        sh, col_name, _hcol(hdr_group, C.energy_label), 9, last_row)

    col_vol_start = _col_by_header(hdr_group, C.volumes_group)
    col_vol_letter = _col_letter(col_vol_start)
    period_hdr_C = _read_row_ints(sh, 8, col_vol_letter, _col_letter(col_vol_start + 6))
    _read_table_sym_int_to_float!(p.activities_netVolumesOrig, sh,
        s.activities_original, period_hdr_C, col_vol_letter, 9, last_row)
    return nothing
end

function _read_hourly_profiles_sheet!(s::ModelSets, p::ModelParams, xf)
    sh = xf["HourlyProfiles"]
    last_row = _last_row(sh, "A")
    last_col = _last_col(sh)
    hdr = _header_row_texts(sh, 3, _col_index(last_col))
    C = ColumnNames.HourlyProfiles

    col_hour  = _hcol(hdr, C.hour)
    col_month = _hcol(hdr, C.month)
    col_profiles_start = _col_letter(_col_by_header(hdr, C.month) + 1)

    s.hours_orig = _read_column_ints(sh, col_hour, 5, last_row)
    s.profile_typeRead = _read_row_symbols(sh, 3, col_profiles_start, last_col)

    _read_column_to_int_dict_int!(p.monthPer_hourOrig, sh, col_hour, col_month, 5, last_row)
    _read_table_int_sym_to_float!(p.hourly_profilesReadOrig, sh,
        s.hours_orig, s.profile_typeRead, col_profiles_start, 5, last_row)
    return nothing
end

function _read_technologies_sheet!(s::ModelSets, p::ModelParams, xf)
    sh = xf["Technologies"]
    last_row = _last_row(sh, "A")
    last_col_idx = _col_index(_last_col(sh))
    hdr_group = _header_row_texts(sh, 2, last_col_idx)
    hdr_field = _header_row_texts(sh, 3, last_col_idx)
    hdr = _flatten_header(hdr_group, hdr_field)  # "group / field", disambiguates repeated field names
    C = ColumnNames.Technologies

    col_id = _hcol(hdr, C.tech_id)
    s.tech_balancers = _read_column_symbols(sh, col_id, 7, last_row)

    _read_list_to_sym!(p.tech_sector_kev,      sh, col_id, _hcol(hdr, C.sector_kev), 7, last_row)
    _read_list_to_sym!(p.tech_category,        sh, col_id, _hcol(hdr, C.category), 7, last_row)
    _read_list_to_sym!(p.tech_sector,          sh, col_id, _hcol(hdr, C.sector), 7, last_row)
    _read_list_to_sym!(p.tech_subsector,       sh, col_id, _hcol(hdr, C.subsector), 7, last_row)
    _read_list_to_sym!(p.activityPer_techOrig, sh, col_id, _hcol(hdr, C.main_activity), 7, last_row)
    _read_list_to_str!(p.tech_name,            sh, col_id, _hcol(hdr, C.name), 7, last_row)
    _read_list_to_sym!(p.tech_units,           sh, col_id, _hcol(hdr, C.unit), 7, last_row)

    col_inv = _col_by_header(hdr, C.investment)
    period_hdr_I = _read_row_ints(sh, 4, _col_letter(col_inv), _col_letter(col_inv + 6))
    _read_table_sym_int_to_float!(p.inv_cost, sh, s.tech_balancers, period_hdr_I, _col_letter(col_inv), 7, last_row)

    _read_list_to_float!(p.Salvage_value, sh, col_id, _hcol(hdr, C.salvage_value), 7, last_row)

    col_fom = _col_by_header(hdr, C.fixed_om)
    period_hdr_Q = _read_row_ints(sh, 4, _col_letter(col_fom), _col_letter(col_fom + 6))
    _read_table_sym_int_to_float!(p.fom_cost, sh, s.tech_balancers, period_hdr_Q, _col_letter(col_fom), 7, last_row)

    col_vom = _col_by_header(hdr, C.variable_om)
    period_hdr_X = _read_row_ints(sh, 4, _col_letter(col_vom), _col_letter(col_vom + 6))
    _read_table_sym_int_to_float!(p.vom_cost, sh, s.tech_balancers, period_hdr_X, _col_letter(col_vom), 7, last_row)

    _read_list_to_float!(p.WACC,                sh, col_id, _hcol(hdr, C.wacc), 7, last_row)
    _read_list_to_float!(p.construction_time,   sh, col_id, _hcol(hdr, C.construction_time), 7, last_row)   # stored as Float; will round at use-site
    _read_list_to_float!(p.economic_lifetime,   sh, col_id, _hcol(hdr, C.economic_lifetime), 7, last_row)
    _read_list_to_float!(p.technical_lifetime,  sh, col_id, _hcol(hdr, C.technical_lifetime), 7, last_row)
    _read_list_to_float!(p.cap2act,             sh, col_id, _hcol(hdr, C.cap2act), 7, last_row)
    _read_list_to_sym!(p.processType_tech,      sh, col_id, _hcol(hdr, C.process_type), 7, last_row)
    _read_list_to_sym!(p.profileType_techRead,  sh, col_id, _hcol(hdr, C.profile_type), 7, last_row)
    _read_list_to_float!(p.ramping,             sh, col_id, _hcol(hdr, C.ramping), 7, last_row)

    _read_list_to_sym!(p.CHP_prodOrig,          sh, col_id, _hcol(hdr, C.chp_prod), 7, last_row)
    _read_list_to_sym!(p.CHP_fuelOrig,          sh, col_id, _hcol(hdr, C.chp_fuel), 7, last_row)
    _read_list_to_float!(p.CHP_eta,             sh, col_id, _hcol(hdr, C.chp_eta), 7, last_row)
    _read_list_to_sym!(p.CHP_range,             sh, col_id, _hcol(hdr, C.chp_range), 7, last_row)
    _read_list_to_float!(p.CHP_dev_use,         sh, col_id, _hcol(hdr, C.chp_dev_use), 7, last_row)
    _read_list_to_float!(p.CHP_dev_PtoH,        sh, col_id, _hcol(hdr, C.chp_dev_ptoh), 7, last_row)

    _read_list_to_float!(p.shed_capacity_percentage, sh, col_id, _hcol(hdr, C.shed_capacity), 7, last_row)
    _read_list_to_float!(p.shed_volume,         sh, col_id, _hcol(hdr, C.shed_volume), 7, last_row)
    _read_list_to_sym!(p.shed_range,            sh, col_id, _hcol(hdr, C.shed_range), 7, last_row)

    _read_list_to_float!(p.phs_capacity,        sh, col_id, _hcol(hdr, C.pumphead_ratio), 7, last_row)
    _read_list_to_float!(p.reservoir_capacity,  sh, col_id, _hcol(hdr, C.reservoir_capacity), 7, last_row)
    _read_list_to_float!(p.phs_Losses,          sh, col_id, _hcol(hdr, C.phs_losses), 7, last_row)

    _read_list_to_sym!(p.flexibilityType_tech,  sh, col_id, _hcol(hdr, C.flexibility_form), 7, last_row)
    _read_list_to_sym!(p.flex_activityOrig,     sh, col_id, _hcol(hdr, C.flex_activity), 7, last_row)
    _read_list_to_float!(p.flex_capacity_pct,   sh, col_id, _hcol(hdr, C.flex_capacity), 7, last_row)
    _read_list_to_float!(p.flex_storage,        sh, col_id, _hcol(hdr, C.flex_storage), 7, last_row)
    _read_list_to_sym!(p.flex_range,            sh, col_id, _hcol(hdr, C.flex_range), 7, last_row)
    _read_list_to_float!(p.flex_losses_legacy,  sh, col_id, _hcol(hdr, C.flex_losses), 7, last_row)   # legacy combined; split later
    _read_list_to_float!(p.flex_nnLoad,         sh, col_id, _hcol(hdr, C.flex_nnload), 7, last_row)
    _read_list_to_float!(p.avg_journey,         sh, col_id, _hcol(hdr, C.avg_journey), 7, last_row)
    _read_list_to_float!(p.avg_speed,           sh, col_id, _hcol(hdr, C.avg_speed), 7, last_row)

    _read_list_to_sym!(p.buffer_activityOrig,   sh, col_id, _hcol(hdr, C.buffer_activity), 7, last_row)
    _read_list_to_float!(p.bufferUP_capacity,   sh, col_id, _hcol(hdr, C.buffer_up), 7, last_row)
    _read_list_to_float!(p.bufferDW_capacity,   sh, col_id, _hcol(hdr, C.buffer_down), 7, last_row)
    _read_list_to_float!(p.buffer_storage,      sh, col_id, _hcol(hdr, C.buffer_storage), 7, last_row)

    _read_list_to_float!(p.techChange_max,      sh, col_id, _hcol(hdr, C.change_max), 7, last_row)
    _read_list_to_float!(p.techStock_exist,     sh, col_id, _hcol(hdr, C.stock_exist), 7, last_row)

    col_decom = _col_by_header(hdr_group, C.decom_planned_group)
    period_hdr_BO = _read_row_ints(sh, 5, _col_letter(col_decom), _col_letter(col_decom + 5))
    _read_table_sym_int_to_float!(p.decom_planned, sh, s.tech_balancers, period_hdr_BO, _col_letter(col_decom), 7, last_row)

    col_stmin = _col_by_header(hdr_group, C.stock_min_group)
    period_hdr_BU = _read_row_ints(sh, 5, _col_letter(col_stmin), _col_letter(col_stmin + 6))
    _read_table_sym_int_to_float!(p.techStock_min, sh, s.tech_balancers, period_hdr_BU, _col_letter(col_stmin), 7, last_row)

    col_stmax = _col_by_header(hdr_group, C.stock_max_group)
    period_hdr_CB = _read_row_ints(sh, 5, _col_letter(col_stmax), _col_letter(col_stmax + 6))
    _read_table_sym_int_to_float!(p.techStock_max, sh, s.tech_balancers, period_hdr_CB, _col_letter(col_stmax), 7, last_row; keep_zeros=true)

    col_usemin = _col_by_header(hdr_group, C.use_min_group)
    period_hdr_CI = _read_row_ints(sh, 5, _col_letter(col_usemin), _col_letter(col_usemin + 6))
    _read_table_sym_int_to_float!(p.techUse_min, sh, s.tech_balancers, period_hdr_CI, _col_letter(col_usemin), 7, last_row)

    col_usemax = _col_by_header(hdr_group, C.use_max_group)
    period_hdr_CP = _read_row_ints(sh, 5, _col_letter(col_usemax), _col_letter(col_usemax + 6))
    _read_table_sym_int_to_float!(p.techUse_max, sh, s.tech_balancers, period_hdr_CP, _col_letter(col_usemax), 7, last_row; keep_zeros=true)

    col_noinv = _col_by_header(hdr_group, C.no_new_invest_group)
    period_hdr_CW = _read_row_ints(sh, 5, _col_letter(col_noinv), _col_letter(col_noinv + 6))
    _read_table_sym_int_to_bool!(p.no_new_invest, sh, s.tech_balancers, period_hdr_CW, _col_letter(col_noinv), 7, last_row)

    col_nodecom = _col_by_header(hdr_group, C.no_eco_decom_group)
    period_hdr_DD = _read_row_ints(sh, 5, _col_letter(col_nodecom), _col_letter(col_nodecom + 6))
    _read_table_sym_int_to_bool!(p.no_eco_decom, sh, s.tech_balancers, period_hdr_DD, _col_letter(col_nodecom), 7, last_row)
    return nothing
end

function _read_energy_balance_sheet!(s::ModelSets, p::ModelParams, xf)
    sh = xf["EnergyBalance"]
    last_row = _last_row(sh, "A")
    last_col = _last_col(sh)
    last_col_idx = _col_index(last_col)
    hdr = _header_row_texts(sh, 3, last_col_idx)
    hdr_group = _header_row_texts(sh, 2, last_col_idx)
    C = ColumnNames.EnergyBalance

    tech_rows = _read_column_symbols(sh, _hcol(hdr, C.tech_id), 7, last_row)
    # The per-activity balance columns start right after the single blank
    # "Data source" spacer column (row 3 has no field name of its own there).
    col_act_start = _col_letter(_col_by_header(hdr_group, C.data_source_col) + 1)
    act_hdrs = _read_row_strings(sh, 3, col_act_start, last_col)
    _read_table_3key_balances!(p.activity_balancesRef, sh, tech_rows, act_hdrs, col_act_start, 7, last_row)
    return nothing
end

function _read_infrastructure_sheet!(s::ModelSets, p::ModelParams, xf)
    sh = xf["Infrastructure"]
    last_row = _last_row(sh, "A")
    last_col_idx = _col_index(_last_col(sh))
    hdr_group = _header_row_texts(sh, 2, last_col_idx)
    hdr_field = _header_row_texts(sh, 3, last_col_idx)
    hdr = _flatten_header(hdr_group, hdr_field)
    C = ColumnNames.Infrastructure

    col_id = _hcol(hdr, C.tech_id)
    s.tech_infra = _read_column_symbols(sh, col_id, 6, last_row)

    # Merge infra rows into tech_* dicts (merge=true → don't overwrite existing)
    _read_list_to_sym!(p.tech_sector_kev,  sh, col_id, _hcol(hdr, C.sector_kev), 6, last_row; merge=true)
    _read_list_to_sym!(p.tech_category,    sh, col_id, _hcol(hdr, C.category), 6, last_row; merge=true)
    _read_list_to_sym!(p.tech_sector,      sh, col_id, _hcol(hdr, C.sector), 6, last_row; merge=true)
    _read_list_to_sym!(p.tech_subsector,   sh, col_id, _hcol(hdr, C.subsector), 6, last_row; merge=true)
    _read_list_to_str!(p.tech_name,        sh, col_id, _hcol(hdr, C.name), 6, last_row; merge=true)
    _read_list_to_sym!(p.tech_units,       sh, col_id, _hcol(hdr, C.unit), 6, last_row; merge=true)

    col_inv = _col_by_header(hdr, C.investment)
    period_hdr_H = _read_row_ints(sh, 4, _col_letter(col_inv), _col_letter(col_inv + 6))
    _read_table_sym_int_to_float!(p.inv_cost, sh, s.tech_infra, period_hdr_H, _col_letter(col_inv), 6, last_row; merge=true)

    _read_list_to_float!(p.Salvage_value,    sh, col_id, _hcol(hdr, C.salvage_value), 6, last_row; merge=true)

    col_fom = _col_by_header(hdr, C.fixed_om)
    period_hdr_P = _read_row_ints(sh, 4, _col_letter(col_fom), _col_letter(col_fom + 6))
    _read_table_sym_int_to_float!(p.fom_cost, sh, s.tech_infra, period_hdr_P, _col_letter(col_fom), 6, last_row; merge=true)

    _read_list_to_float!(p.WACC,               sh, col_id, _hcol(hdr, C.wacc), 6, last_row; merge=true)
    _read_list_to_float!(p.economic_lifetime,  sh, col_id, _hcol(hdr, C.economic_lifetime), 6, last_row; merge=true)
    _read_list_to_float!(p.technical_lifetime, sh, col_id, _hcol(hdr, C.technical_lifetime), 6, last_row; merge=true)
    _read_list_to_float!(p.cap2act,            sh, col_id, _hcol(hdr, C.cap2act), 6, last_row; merge=true)
    _read_list_to_sym!(p.infra_range,          sh, col_id, _hcol(hdr, C.infra_range), 6, last_row)
    _read_list_to_sym!(p.infra_activityOrig,   sh, col_id, _hcol(hdr, C.infra_activity), 6, last_row)
    _read_list_to_float!(p.techChange_max,     sh, col_id, _hcol(hdr, C.change_max), 6, last_row; merge=true)
    _read_list_to_float!(p.techStock_exist,    sh, col_id, _hcol(hdr_group, C.stock_exist), 6, last_row; merge=true)

    col_decom = _col_by_header(hdr_group, C.decom_planned_group)
    period_hdr_AF = _read_row_ints(sh, 3, _col_letter(col_decom), _col_letter(col_decom + 5))
    _read_table_sym_int_to_float!(p.decom_planned, sh, s.tech_infra, period_hdr_AF, _col_letter(col_decom), 6, last_row; merge=true)

    col_stmin = _col_by_header(hdr_group, C.stock_min_group)
    period_hdr_AL = _read_row_ints(sh, 3, _col_letter(col_stmin), _col_letter(col_stmin + 6))
    _read_table_sym_int_to_float!(p.techStock_min, sh, s.tech_infra, period_hdr_AL, _col_letter(col_stmin), 6, last_row; merge=true)

    col_stmax = _col_by_header(hdr_group, C.stock_max_group)
    period_hdr_AS = _read_row_ints(sh, 3, _col_letter(col_stmax), _col_letter(col_stmax + 6))
    _read_table_sym_int_to_float!(p.techStock_max, sh, s.tech_infra, period_hdr_AS, _col_letter(col_stmax), 6, last_row; merge=true, keep_zeros=true)
    return nothing
end

function _read_price_profiles_sheet!(s::ModelSets, p::ModelParams, xf)
    sh = xf["PriceProfiles"]
    last_row = _last_row(sh, "A")
    last_col = _last_col(sh)
    hdr = _header_row_texts(sh, 3, _col_index(last_col))
    col_start = _col_letter(_col_by_header(hdr, ColumnNames.PriceProfiles.month) + 1)
    _read_price_profiles_table!(p.interconnectedHourly_pricesOrig, sh, s.hours_orig, col_start, 5, last_row, last_col)
    return nothing
end

function _read_act_grouping_sheet!(s::ModelSets, p::ModelParams, xf)
    sh = xf["ActGrouping"]
    last_row = _last_row(sh, "A")
    hdr = _header_row_texts(sh, 2, _col_index(_last_col(sh)))
    C = ColumnNames.ActGrouping

    col_name = _hcol(hdr, C.name)
    s.activities_group = _read_column_symbols(sh, col_name, 4, last_row)

    _read_list_to_sym!(p.dispatchType_act,    sh, col_name, _hcol(hdr, C.dispatch_type), 4, last_row; merge=true)
    _read_list_to_sym!(p.activityType_act,    sh, col_name, _hcol(hdr, C.activity_type), 4, last_row; merge=true)
    _read_list_to_sym!(p.nodePer_act,         sh, col_name, _hcol(hdr, C.node), 4, last_row; merge=true)
    _read_list_to_sym!(p.emissionTarget_bin,  sh, col_name, _hcol(hdr, C.emission_target_bin), 4, last_row; merge=true)
    _read_list_to_sym!(p.labelPer_act,        sh, col_name, _hcol(hdr, C.energy_label), 4, last_row; merge=true)

    _read_act_grouping_table!(p.act_to_group, sh, _hcol(hdr, C.activity_original), _hcol(hdr, C.activity_group), 4, last_row)
    return nothing
end

function _read_eff_learning_sheet!(s::ModelSets, p::ModelParams, xf)
    sh = xf["EffLearning"]
    last_row = _last_row(sh, "C")
    last_col_idx = _col_index(_last_col(sh))
    hdr_group = _header_row_texts(sh, 2, last_col_idx)
    hdr_field = _header_row_texts(sh, 3, last_col_idx)
    C = ColumnNames.EffLearning

    tech_act_pairs = _read_two_col_keys_sym(sh, _hcol(hdr_field, C.tech_id), _hcol(hdr_group, C.activity), 4, last_row)

    col_period = _col_by_header(hdr_group, C.period_group)
    col_period_letter = _col_letter(col_period)
    period_hdr_E = _read_row_ints(sh, 3, col_period_letter, _col_letter(col_period + 6))
    _read_table_sym_pair_int_to_float!(p.activity_EffImprov, sh, tech_act_pairs, period_hdr_E, col_period_letter, 4, last_row)
    return nothing
end

function _read_feedstocks_sheet!(s::ModelSets, p::ModelParams, xf)
    sh = xf["Feedstocks"]
    last_row = _last_row(sh, "C")
    last_col_idx = _col_index(_last_col(sh))
    hdr_group = _header_row_texts(sh, 2, last_col_idx)
    hdr_field = _header_row_texts(sh, 3, last_col_idx)
    C = ColumnNames.Feedstocks

    _read_list_2sym_to_float!(p.feedstockUse_techOrig, sh,
        _hcol(hdr_field, C.tech_id), _hcol(hdr_group, C.activity), _hcol(hdr_group, C.use), 4, last_row)
    return nothing
end

function _read_retrofitting_sheet!(s::ModelSets, p::ModelParams, xf)
    sh = xf["Retrofitting"]
    last_row = _last_row(sh, "A")
    hdr = _header_row_texts(sh, 3, _col_index(_last_col(sh)))
    C = ColumnNames.Retrofitting

    col_from = _hcol(hdr, C.from_tech)
    col_to   = _hcol(hdr, C.to_tech)
    _read_list_2sym_to_bool!(p.retrofit_relations, sh, col_from, col_to, _hcol(hdr, C.enabled), 4, last_row)
    # Retrofit costs are stored by (from_tech, to_tech, period).
    # We broadcast across all configured periods.
    _read_retrofit_cost!(p.retrofit_cost, sh, col_from, col_to, _hcol(hdr, C.investment), 4, last_row, s.periods)
    return nothing
end

# =============================================================================
# Low-level XLSX helpers
# =============================================================================

# ---------------------------------------------------------------- coercion --
_str(x)::String = (x === nothing || ismissing(x)) ? "" : string(x)

function _float(x)::Float64
    if x === nothing || ismissing(x)
        return 0.0
    elseif x isa Number
        return Float64(x)
    else
        s = strip(string(x))
        isempty(s) && return 0.0
        s = replace(s, "," => ".")
        v = tryparse(Float64, s)
        return v === nothing ? 0.0 : v
    end
end

_int(x)::Int = (x === nothing || ismissing(x)) ? 0 : Int(round(Float64(x)))

function _sym(x)::Symbol
    s = strip(_str(x))
    return Symbol(s)
end

# Per-sheet progress message; flushes stderr so it shows up immediately even
# when stdout/stderr are piped through PowerShell (block-buffered).
function _logsheet(name::AbstractString)
    @info "  reading sheet" sheet=name
    flush(stderr)
end

# ----------------------------------------------------------- column helpers --
function _col_index(col::AbstractString)::Int
    idx = 0
    for c in uppercase(col)
        idx = idx * 26 + (Int(c) - Int('A') + 1)
    end
    return idx
end

function _col_letter(n::Int)::String
    s = ""
    while n > 0
        rem = (n - 1) % 26
        s = string(Char(Int('A') + rem)) * s
        n = div(n - 1, 26)
    end
    return s
end

# ------------------------------------------------- header-name column lookup --
# Columns are located by header text (see column_names.jl / `ColumnNames`),
# not by hardcoded Excel letters — mirrors the reference IESA-Sim Python
# loader's `Constants.Parameters` + `.get_loc(name)` pattern.

"""
    _header_row_texts(sh, row, last_col_idx) -> Vector{String}

Read `row` across columns `1:last_col_idx` as plain strings (empty string for
blank/missing cells).
"""
function _header_row_texts(sh, row::Int, last_col_idx::Int)::Vector{String}
    return [_str(sh[row, c]) for c in 1:last_col_idx]
end

"""
    _flatten_header(group_row, field_row) -> Vector{String}

2-row (group/field) header flatten, matching the Python loader's
`flatten_header`: `group_row` is forward-filled across its span (Excel merges
only carry text in the first cell) and joined to `field_row` with " / ".
Disambiguates field names reused under different groups (e.g. Technologies'
"Benefited activity", used by both flexibility and buffer data).
"""
function _flatten_header(group_row::Vector{String}, field_row::Vector{String})::Vector{String}
    out = Vector{String}(undef, length(field_row))
    current_group = ""
    for i in eachindex(field_row)
        isempty(group_row[i]) || (current_group = group_row[i])
        field = field_row[i]
        out[i] = isempty(current_group) ? field : (isempty(field) ? current_group : current_group * " / " * field)
    end
    return out
end

"""
    _col_by_header(header_texts, name) -> Int

First column (1-based) whose header text equals `name`. Errors loudly if not
found — a missing header means the workbook layout no longer matches what the
reader expects, which should surface immediately rather than silently reading
the wrong column.
"""
function _col_by_header(header_texts::Vector{String}, name::AbstractString)::Int
    idx = findfirst(==(name), header_texts)
    idx === nothing && error("Column header not found: $(repr(name))")
    return idx
end

"""
    _col_by_header_or_nothing(header_texts, name) -> Union{Int,Nothing}

Non-throwing sibling of `_col_by_header`, for compatibility probing
(`compat_check.jl`) where a missing header is a result to report, not a
reader-breaking error.
"""
_col_by_header_or_nothing(header_texts::Vector{String}, name::AbstractString) = findfirst(==(name), header_texts)

"""
    _hcol(header_texts, name) -> String

Like `_col_by_header`, but returns the Excel column letter — the form the
existing block-reader helpers (`_read_list_to_sym!` etc.) accept.
"""
_hcol(header_texts::Vector{String}, name::AbstractString)::String = _col_letter(_col_by_header(header_texts, name))

"""
    _row_by_name(sh, name_col_idx, name; r_start, r_end) -> Int

First row (within `r_start:r_end`) whose cell in column `name_col_idx` equals
`name`. Used for sheets laid out as one named scalar per row (e.g.
Parameters), the transposed counterpart of `_col_by_header`.
"""
function _row_by_name(sh, name_col_idx::Int, name::AbstractString; r_start::Int = 1, r_end::Int = 200)::Int
    for r in r_start:r_end
        _str(sh[r, name_col_idx]) == name && return r
    end
    error("Row not found for name: $(repr(name))")
end

function _last_row(sh, col::AbstractString)::Int
    ci = _col_index(col)
    # XLSX's stored dimension is the worksheet's recorded bounding box — use it
    # as the upper bound instead of scanning up to row 10 000 (which is
    # extremely slow for sparse sheets).
    dim_end = try
        XLSX.row_number(XLSX.get_dimension(sh).stop)
    catch
        10000
    end
    last = 1
    consec_empty = 0
    @inbounds for r in 1:dim_end
        v = sh[r, ci]
        if v !== nothing && !ismissing(v) && _str(v) != ""
            last = r
            consec_empty = 0
        else
            consec_empty += 1
            consec_empty > 200 && r > last + 200 && break
        end
    end
    return last
end

function _last_col(sh)::String
    dim = try
        XLSX.get_dimension(sh)
    catch
        nothing
    end
    max_col = dim === nothing ? 1000 : XLSX.column_number(dim.stop)
    max_row = dim === nothing ? 5     : min(5, XLSX.row_number(dim.stop))
    last = 1
    consec_empty = 0
    @inbounds for c in 1:max_col
        found = false
        for r in 1:max_row
            v2 = sh[r, c]
            if v2 !== nothing && !ismissing(v2) && _str(v2) != ""
                found = true; break
            end
        end
        if found
            last = c
            consec_empty = 0
        else
            consec_empty += 1
            consec_empty > 50 && c > last + 50 && break
        end
    end
    return _col_letter(last)
end

# Like `_last_col`, but scans a single specified row instead of assuming the
# sheet's header sits within rows 1-5 — needed for Activities, whose real
# per-column header is at row 7/8 (rows 1-6 hold a separate "external
# drivers" mini-table with far fewer columns).
function _last_col_at_row(sh, row::Int)::String
    dim = try
        XLSX.get_dimension(sh)
    catch
        nothing
    end
    max_col = dim === nothing ? 1000 : XLSX.column_number(dim.stop)
    last = 1
    consec_empty = 0
    @inbounds for c in 1:max_col
        v = sh[row, c]
        if v !== nothing && !ismissing(v) && _str(v) != ""
            last = c
            consec_empty = 0
        else
            consec_empty += 1
            consec_empty > 50 && c > last + 50 && break
        end
    end
    return _col_letter(last)
end

# ----------------------------------------------------------- vector readers --
function _read_column_symbols(sh, col::AbstractString, r_start::Int, r_end::Int)::Vector{Symbol}
    ci = _col_index(col)
    out = Symbol[]
    for r in r_start:r_end
        s = _str(sh[r, ci])
        if s != ""
            push!(out, Symbol(strip(s)))
        end
    end
    return out
end

function _read_column_ints(sh, col::AbstractString, r_start::Int, r_end::Int)::Vector{Int}
    ci = _col_index(col)
    out = Int[]
    for r in r_start:r_end
        v = sh[r, ci]
        if v !== nothing && !ismissing(v)
            push!(out, _int(v))
        end
    end
    return out
end

function _read_row_strings(sh, row::Int, col_start::AbstractString, col_end::AbstractString)::Vector{String}
    cs = _col_index(col_start)
    ce = _col_index(col_end)
    out = String[]
    for c in cs:ce
        s = _str(sh[row, c])
        if s != ""
            push!(out, s)
        end
    end
    return out
end

function _read_row_symbols(sh, row::Int, col_start::AbstractString, col_end::AbstractString)::Vector{Symbol}
    return [Symbol(strip(s)) for s in _read_row_strings(sh, row, col_start, col_end)]
end

function _read_row_ints(sh, row::Int, col_start::AbstractString, col_end::AbstractString)::Vector{Int}
    cs = _col_index(col_start)
    ce = _col_index(col_end)
    out = Int[]
    for c in cs:ce
        v = sh[row, c]
        if v !== nothing && !ismissing(v)
            s = strip(_str(v))
            isempty(s) && continue
            n = tryparse(Int, s)
            n === nothing || push!(out, n)
        end
    end
    return out
end

# ------------------------------------------------------------- list readers --
"""
    _read_list_to_sym!(d, sh, col_key, col_val, rs, re; merge=false)

Read column pairs (Symbol key → Symbol value). When `merge=true`, do not
overwrite existing entries (used for the Infrastructure sheet merge).
"""
function _read_list_to_sym!(d::Dict{Symbol,Symbol}, sh, col_key::AbstractString, col_val::AbstractString,
                             r_start::Int, r_end::Int; merge::Bool=false)
    ck, cv = _col_index(col_key), _col_index(col_val)
    for r in r_start:r_end
        ks = _str(sh[r, ck])
        vs = _str(sh[r, cv])
        ks == "" && continue
        k = Symbol(strip(ks))
        if !merge || !haskey(d, k)
            d[k] = Symbol(strip(vs))
        end
    end
end

function _read_list_to_str!(d::Dict{Symbol,String}, sh, col_key::AbstractString, col_val::AbstractString,
                             r_start::Int, r_end::Int; merge::Bool=false)
    ck, cv = _col_index(col_key), _col_index(col_val)
    for r in r_start:r_end
        ks = _str(sh[r, ck])
        vs = _str(sh[r, cv])
        ks == "" && continue
        k = Symbol(strip(ks))
        if !merge || !haskey(d, k)
            d[k] = vs
        end
    end
end

function _read_list_to_float!(d::Dict{Symbol,Float64}, sh, col_key::AbstractString, col_val::AbstractString,
                                r_start::Int, r_end::Int; merge::Bool=false)
    ck, cv = _col_index(col_key), _col_index(col_val)
    for r in r_start:r_end
        ks = _str(sh[r, ck])
        ks == "" && continue
        v = sh[r, cv]
        (v === nothing || ismissing(v)) && continue
        k = Symbol(strip(ks))
        fval = _float(v)
        if !merge || !haskey(d, k)
            d[k] = fval
        end
    end
end

function _read_list_to_int!(d::Dict{Symbol,Int}, sh, col_key::AbstractString, col_val::AbstractString,
                             r_start::Int, r_end::Int; merge::Bool=false)
    ck, cv = _col_index(col_key), _col_index(col_val)
    for r in r_start:r_end
        ks = _str(sh[r, ck])
        ks == "" && continue
        v = sh[r, cv]
        (v === nothing || ismissing(v)) && continue
        k = Symbol(strip(ks))
        if !merge || !haskey(d, k)
            d[k] = _int(v)
        end
    end
end

function _read_list_2sym_to_float!(d::Dict{Tuple{Symbol,Symbol},Float64}, sh,
                                     col_k1::AbstractString, col_k2::AbstractString, col_val::AbstractString,
                                     r_start::Int, r_end::Int)
    ck1, ck2, cv = _col_index(col_k1), _col_index(col_k2), _col_index(col_val)
    for r in r_start:r_end
        k1s = _str(sh[r, ck1])
        k2s = _str(sh[r, ck2])
        v   = sh[r, cv]
        if k1s != "" && k2s != "" && v !== nothing && !ismissing(v)
            d[(Symbol(strip(k1s)), Symbol(strip(k2s)))] = _float(v)
        end
    end
end

function _read_list_2sym_to_bool!(d::Dict{Tuple{Symbol,Symbol},Bool}, sh,
                                    col_k1::AbstractString, col_k2::AbstractString, col_val::AbstractString,
                                    r_start::Int, r_end::Int)
    ck1, ck2, cv = _col_index(col_k1), _col_index(col_k2), _col_index(col_val)
    for r in r_start:r_end
        k1s = _str(sh[r, ck1])
        k2s = _str(sh[r, ck2])
        v   = sh[r, cv]
        if k1s != "" && k2s != "" && v !== nothing && !ismissing(v)
            d[(Symbol(strip(k1s)), Symbol(strip(k2s)))] = _float(v) != 0.0
        end
    end
end

# ----------------------------------------------------------- table readers --

"""
    _read_table_sym_int_to_float!(d, sh, row_keys, col_period_headers, col_start, rs, re; merge=false, keep_zeros=false)

Read a rectangular 2D block where rows are Symbol keys and columns are Int
periods. Cell `(rk, period)` stored as Float64 in `d`.

When `keep_zeros=false` (default) explicit `0` values are skipped so that the
dict semantically represents "non-default" entries (e.g. for cost parameters
where `0` and `na` are equivalent). For constraint-defining parameters such as
`techStock_max` and `techUse_max`, IESA-Opt 1.0 distinguishes `0` ("must be <= 0")
from `na` ("no upper bound"); pass `keep_zeros=true` to preserve explicit
zero cells in the dict so the constraint loop will pick them up.
"""
function _read_table_sym_int_to_float!(d::Dict{Tuple{Symbol,Int},Float64}, sh,
                                         row_keys::Vector{Symbol}, col_periods::Vector{Int},
                                         col_start::AbstractString,
                                         r_start::Int, r_end::Int;
                                         merge::Bool=false, keep_zeros::Bool=false)
    cs = _col_index(col_start)
    n_rows = min(length(row_keys), r_end - r_start + 1)
    n_cols = length(col_periods)
    (n_rows == 0 || n_cols == 0) && return

    ce = cs + n_cols - 1
    rng = string(_col_letter(cs), r_start, ":", _col_letter(ce), r_start + n_rows - 1)
    block = sh[rng]

    @inbounds for ri in 1:n_rows
        rk = row_keys[ri]
        for ci in 1:n_cols
            v = block[ri, ci]
            (v === nothing || ismissing(v)) && continue
            fval = _float(v)
            (!keep_zeros && fval == 0.0) && continue
            key = (rk, col_periods[ci])
            if !merge || !haskey(d, key)
                d[key] = fval
            end
        end
    end
end

function _read_table_sym_int_to_bool!(d::Dict{Tuple{Symbol,Int},Bool}, sh,
                                        row_keys::Vector{Symbol}, col_periods::Vector{Int},
                                        col_start::AbstractString,
                                        r_start::Int, r_end::Int; merge::Bool=false)
    cs = _col_index(col_start)
    n_rows = min(length(row_keys), r_end - r_start + 1)
    n_cols = length(col_periods)
    (n_rows == 0 || n_cols == 0) && return

    ce = cs + n_cols - 1
    rng = string(_col_letter(cs), r_start, ":", _col_letter(ce), r_start + n_rows - 1)
    block = sh[rng]

    @inbounds for ri in 1:n_rows
        rk = row_keys[ri]
        for ci in 1:n_cols
            v = block[ri, ci]
            (v === nothing || ismissing(v)) && continue
            b = _float(v) != 0.0
            !b && continue
            key = (rk, col_periods[ci])
            if !merge || !haskey(d, key)
                d[key] = b
            end
        end
    end
end

"""
    _read_table_3key_balances!(d, sh, tech_rows, col_headers, col_start, rs, re)

`activity_balancesRef` reader. The Excel column headers at row 3 are activity
names, optionally with a "|YEAR" or "_YEAR" suffix encoding the period. If no
period suffix is present, the value is broadcast across all default periods
(2022..2050).
"""
function _read_table_3key_balances!(d::Dict{Tuple{Symbol,Symbol,Int},Float64}, sh,
                                      row_keys::Vector{Symbol}, col_headers::Vector{String},
                                      col_start::AbstractString, r_start::Int, r_end::Int;
                                      default_periods::NTuple{N,Int} where N = (2022,2025,2030,2035,2040,2045,2050))
    cs = _col_index(col_start)
    n_rows = min(length(row_keys), r_end - r_start + 1)
    n_cols = length(col_headers)
    (n_rows == 0 || n_cols == 0) && return

    ce = cs + n_cols - 1
    rng = string(_col_letter(cs), r_start, ":", _col_letter(ce), r_start + n_rows - 1)
    block = sh[rng]

    @inbounds for ri in 1:n_rows
        rk = row_keys[ri]
        for ci in 1:n_cols
            v = block[ri, ci]
            (v === nothing || ismissing(v)) && continue
            fval = _float(v)
            fval == 0.0 && continue
            header = strip(col_headers[ci])
            m = match(r"^(.*?)[_|](\d{4})$", header)
            if m !== nothing
                act = Symbol(strip(String(m.captures[1])))
                per = parse(Int, m.captures[2])
                key = (rk, act, per)
                d[key] = get(d, key, 0.0) + fval
            else
                act = Symbol(String(header))
                for per in default_periods
                    key = (rk, act, per)
                    d[key] = get(d, key, 0.0) + fval
                end
            end
        end
    end
end

"""
    _read_table_sym_pair_int_to_float!(d, sh, row_pairs, col_periods, col_start, rs, re)

`activity_EffImprov` reader. Rows are (tech, activity) pairs from a two-column
key, columns are periods (Int).
"""
function _read_table_sym_pair_int_to_float!(d::Dict{Tuple{Symbol,Symbol,Int},Float64}, sh,
                                              row_pairs::Vector{Tuple{Symbol,Symbol}},
                                              col_periods::Vector{Int},
                                              col_start::AbstractString,
                                              r_start::Int, r_end::Int)
    cs = _col_index(col_start)
    n_rows = length(row_pairs)
    for (ri, r) in enumerate(r_start:r_end)
        ri > n_rows && break
        (rk1, rk2) = row_pairs[ri]
        for (ci_off, per) in enumerate(col_periods)
            c = cs + ci_off - 1
            v = sh[r, c]
            (v === nothing || ismissing(v)) && continue
            fval = _float(v)
            fval == 0.0 && continue
            d[(rk1, rk2, per)] = fval
        end
    end
end

"""
    _read_table_int_sym_to_float!(d, sh, row_hours, col_yps, col_start, rs, re)

`hourly_profilesReadOrig` reader. Rows are Int hour indices, columns are
Symbol profile-type names.
"""
function _read_table_int_sym_to_float!(d::Dict{Tuple{Int,Symbol},Float64}, sh,
                                         row_hours::Vector{Int}, col_yps::Vector{Symbol},
                                         col_start::AbstractString,
                                         r_start::Int, r_end::Int)
    cs = _col_index(col_start)
    n_rows = min(length(row_hours), r_end - r_start + 1)
    n_cols = length(col_yps)
    n_rows == 0 || n_cols == 0 && return
    # Bulk-read the dense block — orders of magnitude faster than per-cell `sh[r, c]`
    ce = cs + n_cols - 1
    rng = string(_col_letter(cs), r_start, ":", _col_letter(ce), r_start + n_rows - 1)
    block = sh[rng]
    @assert size(block) == (n_rows, n_cols)
    @inbounds for ri in 1:n_rows
        h = row_hours[ri]
        for ci in 1:n_cols
            v = block[ri, ci]
            (v === nothing || ismissing(v)) && continue
            d[(h, col_yps[ci])] = _float(v)
        end
    end
end

"""
    _read_price_profiles_table!(d, sh, hours_orig, rs, re, last_col)

`interconnectedHourly_pricesOrig` reader. Column headers in rows 2 (activity)
and 3 (period int); row key is the orig hour.
"""
function _read_price_profiles_table!(d::Dict{Tuple{Int,Symbol,Int},Float64}, sh,
                                       hours_orig::Vector{Int}, col_start::AbstractString,
                                       r_start::Int, r_end::Int, last_col::AbstractString)
    cs = _col_index(col_start)
    ce = _col_index(last_col)
    n_h = min(length(hours_orig), r_end - r_start + 1)
    n_c = ce - cs + 1
    (n_h == 0 || n_c == 0) && return

    # Bulk-read the (header rows 2,3 + body) once
    header_rng = string(_col_letter(cs), 2, ":", _col_letter(ce), 3)
    body_rng   = string(_col_letter(cs), r_start, ":", _col_letter(ce), r_start + n_h - 1)
    hdr  = sh[header_rng]                       # 2 × n_c
    body = sh[body_rng]                         # n_h × n_c

    @inbounds for ci in 1:n_c
        act_str = _str(hdr[1, ci])
        per_str = _str(hdr[2, ci])
        per     = tryparse(Int, strip(per_str))
        (act_str == "" || per === nothing) && continue
        act = Symbol(strip(act_str))
        for ri in 1:n_h
            v = body[ri, ci]
            (v === nothing || ismissing(v)) && continue
            d[(hours_orig[ri], act, per)] = _float(v)
        end
    end
end

function _read_column_to_float_dict_sym!(d::Dict{Symbol,Float64}, sh,
                                          col_key::AbstractString, col_val::AbstractString,
                                          r_start::Int, r_end::Int)
    ck, cv = _col_index(col_key), _col_index(col_val)
    for r in r_start:r_end
        ks = _str(sh[r, ck])
        ks == "" && continue
        v = sh[r, cv]
        (v === nothing || ismissing(v)) && continue
        d[Symbol(strip(ks))] = _float(v)
    end
end

function _read_column_to_int_dict_int!(d::Dict{Int,Int}, sh,
                                         col_key::AbstractString, col_val::AbstractString,
                                         r_start::Int, r_end::Int)
    ck, cv = _col_index(col_key), _col_index(col_val)
    for r in r_start:r_end
        kv = sh[r, ck]
        v  = sh[r, cv]
        kv === nothing && continue
        if v !== nothing && !ismissing(v)
            d[_int(kv)] = _int(v)
        end
    end
end

function _read_two_col_keys_sym(sh, col1::AbstractString, col2::AbstractString,
                                  r_start::Int, r_end::Int)::Vector{Tuple{Symbol,Symbol}}
    c1, c2 = _col_index(col1), _col_index(col2)
    out = Tuple{Symbol,Symbol}[]
    for r in r_start:r_end
        s1 = _str(sh[r, c1])
        s2 = _str(sh[r, c2])
        if s1 != "" && s2 != ""
            push!(out, (Symbol(strip(s1)), Symbol(strip(s2))))
        end
    end
    return out
end

function _read_act_grouping_table!(act_to_group::Dict{Symbol,Symbol}, sh,
                                     col_orig::AbstractString, col_group::AbstractString,
                                     r_start::Int, r_end::Int)
    ch = _col_index(col_orig)
    ci = _col_index(col_group)
    for r in r_start:r_end
        orig = _str(sh[r, ch])
        grp  = _str(sh[r, ci])
        if orig != "" && grp != ""
            act_to_group[Symbol(strip(orig))] = Symbol(strip(grp))
        end
    end
end

function _read_retrofit_cost!(d::Dict{Tuple{Symbol,Symbol,Int},Float64}, sh,
                                col_from::AbstractString, col_to::AbstractString, col_val::AbstractString,
                                r_start::Int, r_end::Int, periods::Vector{Int})
    cf, ct, cv = _col_index(col_from), _col_index(col_to), _col_index(col_val)
    for r in r_start:r_end
        sf = _str(sh[r, cf])
        st = _str(sh[r, ct])
        v  = sh[r, cv]
        if sf != "" && st != "" && v !== nothing && !ismissing(v)
            fval = _float(v)
            for per in periods
                d[(Symbol(strip(sf)), Symbol(strip(st)), per)] = fval
            end
        end
    end
end

# =============================================================================
# Post-read derivations (called from `read_data` after all sheets are loaded)
# =============================================================================

"""
    _resolve_activity_names!(md::ModelData)

After `act_to_group` is populated, resolve all "*Orig" name maps to their
grouped form:
- `CHP_prod`, `CHP_fuel` from `CHP_prodOrig`, `CHP_fuelOrig`
- `flex_activity` (already resolved during read, but re-applies grouping)
- `buffer_activity`, `infra_activity` from `*Orig`
- `activityPer_tech` from `activityPer_techOrig`
- `actChange_max_act` from `actChange_maxOrig` via `act_to_group`
"""
function _resolve_activity_names!(md::ModelData)
    s, p = md.sets, md.params

    canonical_activity = Dict{String,Symbol}()
    for a in s.activities
        get!(canonical_activity, lowercase(String(a)), a)
    end
    _canonical_activity(a::Symbol)::Symbol = get(canonical_activity, lowercase(String(a)), a)
    _resolve!(orig::Symbol)::Symbol = _canonical_activity(get(p.act_to_group, orig, orig))

    # Idempotent: clear all derived targets before re-populating. This is
    # critical because some assignments use `+=` (sum over originals feeding a
    # group), so re-running without clearing would double values.
    empty!(p.CHP_prod)
    empty!(p.CHP_fuel)
    empty!(p.buffer_activity)
    empty!(p.infra_activity)
    empty!(p.flex_activity)
    empty!(p.activityPer_tech)
    empty!(p.actChange_max_act)
    empty!(p.activities_netVolumes)

    for (t, orig) in p.CHP_prodOrig
        p.CHP_prod[t] = _resolve!(orig)
    end
    for (t, orig) in p.CHP_fuelOrig
        p.CHP_fuel[t] = _resolve!(orig)
    end
    for (t, orig) in p.buffer_activityOrig
        p.buffer_activity[t] = _resolve!(orig)
    end
    for (t, orig) in p.infra_activityOrig
        p.infra_activity[t] = _resolve!(orig)
    end
    for (t, orig) in p.flex_activityOrig
        p.flex_activity[t] = _resolve!(orig)
    end
    for (t, orig) in p.activityPer_techOrig
        p.activityPer_tech[t] = _resolve!(orig)
    end

    # actChange_max_act: from actChange_maxOrig keyed by activity_orig → group
    for (a_orig, v) in p.actChange_maxOrig
        a = _resolve!(a_orig)
        # Take the max over original activities mapping to the same group
        existing = get(p.actChange_max_act, a, 0.0)
        if v > existing
            p.actChange_max_act[a] = v
        end
    end

    # activities_netVolumes: sum over original activities feeding the same group
    for ((a_orig, per), v) in p.activities_netVolumesOrig
        a = _resolve!(a_orig)
        key = (a, per)
        p.activities_netVolumes[key] = get(p.activities_netVolumes, key, 0.0) + v
    end
    return nothing
end

"""
    _derive_profile_and_node_maps!(md::ModelData)

Build `profileType_tech` (= `profileType_techRead` resolved through any
indirect mapping) and `nodePer_techBal` from per-tech activity → node lookup.
Also seeds `actSolvePer_actOrig` (Identity map; IESA-Opt 1.0 uses this for legacy
reasons; can be overridden by grouping).
"""
function _derive_profile_and_node_maps!(md::ModelData)
    s, p = md.sets, md.params

    # IESA-Opt 1.0 line 3014:
    #   profileType_tech(tb) :=
    #       if (activityPer_tech(tb) in activities_indirect) then activityPer_tech(tb)
    #       elseif (CHP_prod(tb) in activities_indirect) then CHP_prod(tb)
    #       else profileType_techRead(tb)
    # Falls back to profileType_techRead when activities_indirect is not yet
    # built (e.g. when this is called pre-derive_sets!) so re-running
    # compute_derived_params! after derive_sets! settles the indirect mapping.
    ind_set = isempty(s.activities_indirect) ? Set{Symbol}() : Set(s.activities_indirect)
    empty!(p.profileType_tech)
    for (t, ptr) in p.profileType_techRead
        a   = get(p.activityPer_tech, t, get(p.activityPer_techOrig, t, Symbol("")))
        chp = get(p.CHP_prod,         t, get(p.CHP_prodOrig,         t, Symbol("")))
        p.profileType_tech[t] =
            (a   != Symbol("") && a   in ind_set) ? a   :
            (chp != Symbol("") && chp in ind_set) ? chp :
            ptr
    end

    empty!(p.profileType_EVuse)
    for tfv in s.tech_fEV
        ptype = get(p.profileType_tech, tfv, Symbol(""))
        ptype == Symbol("") && continue
        p.profileType_EVuse[tfv] = Symbol(string(ptype), " - Use")
    end

    # nodePer_techBal: node per tech_balancer via activity
    empty!(p.nodePer_techBal)
    for t in s.tech_balancers
        a = get(p.activityPer_tech, t, get(p.activityPer_techOrig, t, Symbol("")))
        n = get(p.nodePer_act, a, Symbol(""))
        if n != Symbol("")
            p.nodePer_techBal[t] = n
        end
    end

    # actSolvePer_actOrig: identity by default
    for a in s.activities_original
        p.actSolvePer_actOrig[a] = get(p.act_to_group, a, a)
    end

    # activities := union of activities_original + activities_group (no duplicates)
    seen = Set{Symbol}()
    out  = Symbol[]
    for a in s.activities_original
        a in seen || (push!(out, a); push!(seen, a))
    end
    for a in s.activities_group
        a in seen || (push!(out, a); push!(seen, a))
    end
    s.activities = out
    return nothing
end
