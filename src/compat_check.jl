# =============================================================================
# compat_check.jl — non-destructive "is this file shaped right for IESA-Opt.jl
# / IESA-Sim" probes, used by the data-merge wizard.
#
# These check *shape* only (sheet/table/header presence), not data validity —
# the real readers (data_reading.jl's `_read_*_sheet!`) also coerce values and
# can throw for reasons unrelated to "is this workbook laid out right" (a
# stray non-numeric cell, say). A missing header is collected into a report
# here rather than throwing on the first miss, unlike the real reader's
# `_col_by_header`, which must fail loudly since it's building an actual
# ModelData.
# =============================================================================

# ----------------------------------------------------------------------- --
# Shared header-list check helper
# ----------------------------------------------------------------------- --
function _check_headers!(missing_headers::Vector{String}, sheet::AbstractString, header_texts::Vector{String}, names)
    for n in names
        _col_by_header_or_nothing(header_texts, n) === nothing && push!(missing_headers, "$(sheet): $(n)")
    end
    return nothing
end

# =============================================================================
# IESA-Opt.jl Excel compatibility
# =============================================================================

"""
    check_iesa_opt_excel_compatibility(path) -> Dict{String,Any}

Check whether the workbook at `path` has the sheets/header text
`data_reading.jl`'s `read_data` needs, without actually parsing values.
Returns `Dict("compatible"=>Bool, "missingSheets"=>[...], "missingHeaders"=>[...])`.
"""
function check_iesa_opt_excel_compatibility(path::AbstractString)::Dict{String,Any}
    missing_sheets = String[]
    missing_headers = String[]
    C = ColumnNames
    try
        XLSX.openxlsx(path, mode = "r") do xf
            sheetnames = Set(XLSX.sheetnames(xf))
            need(name) = name in sheetnames

            if need("IESA-Opt database")
                # Single fixed title cell (E21), not a tabular header — sheet
                # presence is the only meaningful check.
            else
                push!(missing_sheets, "IESA-Opt database")
            end

            if need("Parameters")
                sh = xf["Parameters"]
                found(name) = any(r -> _str(sh[r, 1]) == name, 4:60)
                for n in (C.Parameters.xc_transmission_loss, C.Parameters.baseload_threshold,
                          C.Parameters.shedding_in_load, C.Parameters.social_discount_rate,
                          C.Parameters.base_year, C.Parameters.active_constraint_set)
                    found(n) || push!(missing_headers, "Parameters: $(n)")
                end
            else
                push!(missing_sheets, "Parameters")
            end

            if need("Types")
                sh = xf["Types"]
                hdr = _header_row_texts(sh, 2, _col_index(_last_col(sh)))
                _check_headers!(missing_headers, "Types", hdr, (
                    C.Types.dispatch_type, C.Types.activity_type, C.Types.process_type,
                    C.Types.flexibility_type, C.Types.range_type, C.Types.sectors, C.Types.nodes,
                    C.Types.node_name, C.Types.energy_labels, C.Types.sectors_kev,
                    C.Types.iem_sector, C.Types.iem_node, C.Types.is_renewable,
                ))
            else
                push!(missing_sheets, "Types")
            end

            if need("NodeParameters")
                sh = xf["NodeParameters"]
                idx = _col_index(_last_col(sh))
                hdr_group = _header_row_texts(sh, 2, idx)
                hdr_row4 = _header_row_texts(sh, 4, idx)
                _check_headers!(missing_headers, "NodeParameters", hdr_group, (
                    C.NodeParameters.emission_target_air, C.NodeParameters.cumulative_emission_budget,
                    C.NodeParameters.cumulative_co2_storage, C.NodeParameters.emission_target_all,
                    C.NodeParameters.emission_target_bunker, C.NodeParameters.emission_target_feedstock,
                ))
                _check_headers!(missing_headers, "NodeParameters", hdr_row4, (C.NodeParameters.node,))
            else
                push!(missing_sheets, "NodeParameters")
            end

            if need("Activities")
                sh = xf["Activities"]
                idx = _col_index(_last_col_at_row(sh, 8))
                hdr_group = _header_row_texts(sh, 7, idx)
                hdr_field = _header_row_texts(sh, 8, idx)
                _check_headers!(missing_headers, "Activities", hdr_field, (C.Activities.name, C.Activities.unit))
                _check_headers!(missing_headers, "Activities", hdr_group, (
                    C.Activities.volumes_group, C.Activities.change_max, C.Activities.dispatch_resolution,
                    C.Activities.activity_type, C.Activities.node, C.Activities.emission_target_bin,
                    C.Activities.energy_label,
                ))
            else
                push!(missing_sheets, "Activities")
            end

            if need("HourlyProfiles")
                sh = xf["HourlyProfiles"]
                hdr = _header_row_texts(sh, 3, _col_index(_last_col(sh)))
                _check_headers!(missing_headers, "HourlyProfiles", hdr, (C.HourlyProfiles.hour, C.HourlyProfiles.month))
            else
                push!(missing_sheets, "HourlyProfiles")
            end

            if need("Technologies")
                sh = xf["Technologies"]
                idx = _col_index(_last_col(sh))
                hdr_group = _header_row_texts(sh, 2, idx)
                hdr_field = _header_row_texts(sh, 3, idx)
                hdr = _flatten_header(hdr_group, hdr_field)
                _check_headers!(missing_headers, "Technologies", hdr, (
                    C.Technologies.tech_id, C.Technologies.sector_kev, C.Technologies.category,
                    C.Technologies.sector, C.Technologies.subsector, C.Technologies.main_activity,
                    C.Technologies.name, C.Technologies.unit, C.Technologies.investment,
                    C.Technologies.salvage_value, C.Technologies.fixed_om, C.Technologies.variable_om,
                    C.Technologies.wacc, C.Technologies.construction_time, C.Technologies.economic_lifetime,
                    C.Technologies.technical_lifetime, C.Technologies.cap2act, C.Technologies.process_type,
                    C.Technologies.profile_type, C.Technologies.ramping, C.Technologies.chp_prod,
                    C.Technologies.chp_fuel, C.Technologies.chp_eta, C.Technologies.chp_range,
                    C.Technologies.chp_dev_use, C.Technologies.chp_dev_ptoh, C.Technologies.shed_capacity,
                    C.Technologies.shed_volume, C.Technologies.shed_range, C.Technologies.pumphead_ratio,
                    C.Technologies.reservoir_capacity, C.Technologies.phs_losses, C.Technologies.flexibility_form,
                    C.Technologies.flex_activity, C.Technologies.flex_capacity, C.Technologies.flex_storage,
                    C.Technologies.flex_range, C.Technologies.flex_losses, C.Technologies.flex_nnload,
                    C.Technologies.avg_journey, C.Technologies.avg_speed, C.Technologies.buffer_activity,
                    C.Technologies.buffer_up, C.Technologies.buffer_down, C.Technologies.buffer_capacity,
                    C.Technologies.buffer_storage, C.Technologies.change_max, C.Technologies.stock_exist,
                ))
                _check_headers!(missing_headers, "Technologies", hdr_group, (
                    C.Technologies.decom_planned_group, C.Technologies.stock_min_group,
                    C.Technologies.stock_max_group, C.Technologies.use_min_group,
                    C.Technologies.use_max_group, C.Technologies.no_new_invest_group,
                    C.Technologies.no_eco_decom_group,
                ))
            else
                push!(missing_sheets, "Technologies")
            end

            if need("EnergyBalance")
                sh = xf["EnergyBalance"]
                idx = _col_index(_last_col(sh))
                hdr_field = _header_row_texts(sh, 3, idx)
                hdr_group = _header_row_texts(sh, 2, idx)
                _check_headers!(missing_headers, "EnergyBalance", hdr_field, (C.EnergyBalance.tech_id,))
                _check_headers!(missing_headers, "EnergyBalance", hdr_group, (C.EnergyBalance.data_source_col,))
            else
                push!(missing_sheets, "EnergyBalance")
            end

            if need("Infrastructure")
                sh = xf["Infrastructure"]
                idx = _col_index(_last_col(sh))
                hdr_group = _header_row_texts(sh, 2, idx)
                hdr_field = _header_row_texts(sh, 3, idx)
                hdr = _flatten_header(hdr_group, hdr_field)
                _check_headers!(missing_headers, "Infrastructure", hdr, (
                    C.Infrastructure.tech_id, C.Infrastructure.sector_kev, C.Infrastructure.category,
                    C.Infrastructure.sector, C.Infrastructure.subsector, C.Infrastructure.name,
                    C.Infrastructure.unit, C.Infrastructure.investment, C.Infrastructure.salvage_value,
                    C.Infrastructure.fixed_om, C.Infrastructure.wacc, C.Infrastructure.economic_lifetime,
                    C.Infrastructure.technical_lifetime, C.Infrastructure.cap2act, C.Infrastructure.infra_range,
                    C.Infrastructure.infra_activity, C.Infrastructure.change_max,
                ))
                _check_headers!(missing_headers, "Infrastructure", hdr_group, (
                    C.Infrastructure.stock_exist, C.Infrastructure.decom_planned_group,
                    C.Infrastructure.stock_min_group, C.Infrastructure.stock_max_group,
                ))
            else
                push!(missing_sheets, "Infrastructure")
            end

            if need("PriceProfiles")
                sh = xf["PriceProfiles"]
                hdr = _header_row_texts(sh, 3, _col_index(_last_col(sh)))
                _check_headers!(missing_headers, "PriceProfiles", hdr, (C.PriceProfiles.month,))
            else
                push!(missing_sheets, "PriceProfiles")
            end

            if need("ActGrouping")
                sh = xf["ActGrouping"]
                hdr = _header_row_texts(sh, 2, _col_index(_last_col(sh)))
                _check_headers!(missing_headers, "ActGrouping", hdr, (
                    C.ActGrouping.name, C.ActGrouping.dispatch_type, C.ActGrouping.activity_type,
                    C.ActGrouping.node, C.ActGrouping.emission_target_bin, C.ActGrouping.energy_label,
                    C.ActGrouping.activity_original, C.ActGrouping.activity_group,
                ))
            else
                push!(missing_sheets, "ActGrouping")
            end

            if need("EffLearning")
                sh = xf["EffLearning"]
                idx = _col_index(_last_col(sh))
                hdr_group = _header_row_texts(sh, 2, idx)
                hdr_field = _header_row_texts(sh, 3, idx)
                _check_headers!(missing_headers, "EffLearning", hdr_field, (C.EffLearning.tech_id,))
                _check_headers!(missing_headers, "EffLearning", hdr_group, (C.EffLearning.activity, C.EffLearning.period_group))
            else
                push!(missing_sheets, "EffLearning")
            end

            if need("Feedstocks")
                sh = xf["Feedstocks"]
                idx = _col_index(_last_col(sh))
                hdr_group = _header_row_texts(sh, 2, idx)
                hdr_field = _header_row_texts(sh, 3, idx)
                _check_headers!(missing_headers, "Feedstocks", hdr_field, (C.Feedstocks.tech_id,))
                _check_headers!(missing_headers, "Feedstocks", hdr_group, (C.Feedstocks.activity, C.Feedstocks.use))
            else
                push!(missing_sheets, "Feedstocks")
            end

            if need("Retrofitting")
                sh = xf["Retrofitting"]
                hdr = _header_row_texts(sh, 3, _col_index(_last_col(sh)))
                _check_headers!(missing_headers, "Retrofitting", hdr, (
                    C.Retrofitting.from_tech, C.Retrofitting.to_tech, C.Retrofitting.enabled, C.Retrofitting.investment,
                ))
            else
                push!(missing_sheets, "Retrofitting")
            end
        end
    catch err
        return Dict{String,Any}("compatible" => false, "missingSheets" => ["<could not open as an Excel workbook: $(sprint(showerror, err))>"], "missingHeaders" => String[])
    end
    return Dict{String,Any}(
        "compatible" => isempty(missing_sheets) && isempty(missing_headers),
        "missingSheets" => missing_sheets,
        "missingHeaders" => missing_headers,
    )
end

# =============================================================================
# IESA-Sim Excel compatibility (check-only — see column_names_iesa_sim.jl)
# =============================================================================

"""
    check_iesa_sim_excel_compatibility(path) -> Dict{String,Any}

Check whether the workbook at `path` has the sheets/header text IESA-Sim's
own Python reader (`mod0_read_data_save_duck.py`) needs. This is a shape
check only — there is no Julia parser for IESA-Sim's Excel layout, so a
workbook reported compatible here still cannot be used to fill an IESA-Sim
gap in the merge wizard (only an already-built IESA-Sim DuckDB can); callers
should treat this report as `mergeCapable => false`.
"""
function check_iesa_sim_excel_compatibility(path::AbstractString)::Dict{String,Any}
    missing_sheets = String[]
    missing_headers = String[]
    C = ColumnNamesIesaSim
    try
        XLSX.openxlsx(path, mode = "r") do xf
            sheetnames = Set(XLSX.sheetnames(xf))
            need(name) = name in sheetnames

            if need("Parameters")
                sh = xf["Parameters"]
                found(name) = any(r -> _str(sh[r, 1]) == name, 1:100)
                for n in (C.Parameters.powinv_spbt_benchmark, C.Parameters.powinv_spbt_min,
                          C.Parameters.powinv_cr_threshold, C.Parameters.powinv_cr_min,
                          C.Parameters.powinv_nuf_threshold, C.Parameters.powinv_nuf_min,
                          C.Parameters.scarcity_penalization, C.Parameters.gas_premium,
                          C.Parameters.voll_value, C.Parameters.min_spread_value,
                          C.Parameters.gov_dr, C.Parameters.exports_value)
                    found(n) || push!(missing_headers, "Parameters: $(n)")
                end
            else
                push!(missing_sheets, "Parameters")
            end

            if need("Types")
                sh = xf["Types"]
                hdr = _header_row_texts(sh, 1, _col_index(_last_col(sh)))
                _check_headers!(missing_headers, "Types", hdr, (
                    C.Types.activity_type, C.Types.sectors, C.Types.energy_labels, C.Types.energy_price_init,
                ))
            else
                push!(missing_sheets, "Types")
            end

            if need("Agents")
                sh = xf["Agents"]
                hdr = _header_row_texts(sh, 1, _col_index(_last_col(sh)))
                _check_headers!(missing_headers, "Agents", hdr, (
                    C.Agents.types, C.Agents.profiles, C.Agents.ic_criteria, C.Agents.rates,
                ))
            else
                push!(missing_sheets, "Agents")
            end

            if need("Activities")
                sh = xf["Activities"]
                idx = _col_index(_last_col_at_row(sh, 1))
                hdr = _header_row_texts(sh, 1, idx)
                _check_headers!(missing_headers, "Activities", hdr, (
                    C.Activities.name, C.Activities.periods_start, C.Activities.activity_resolution,
                    C.Activities.activity_type, C.Activities.energy_label, C.Activities.agent_profile,
                ))
            else
                push!(missing_sheets, "Activities")
            end

            if need("HourlyProfiles")
                sh = xf["HourlyProfiles"]
                hdr = _header_row_texts(sh, 1, _col_index(_last_col(sh)))
                _check_headers!(missing_headers, "HourlyProfiles", hdr, (C.HourlyProfiles.hour, C.HourlyProfiles.day, C.HourlyProfiles.month))
            else
                push!(missing_sheets, "HourlyProfiles")
            end

            if need("PriceProfiles")
                sh = xf["PriceProfiles"]
                hdr = _header_row_texts(sh, 1, _col_index(_last_col(sh)))
                _check_headers!(missing_headers, "PriceProfiles", hdr, (C.PriceProfiles.interconnector,))
            else
                push!(missing_sheets, "PriceProfiles")
            end

            if need("Technologies")
                sh = xf["Technologies"]
                idx = _col_index(_last_col(sh))
                hdr_group = _header_row_texts(sh, 1, idx)
                hdr_field = _header_row_texts(sh, 2, idx)
                hdr = _flatten_header(hdr_group, hdr_field)
                _check_headers!(missing_headers, "Technologies", hdr, (
                    C.Technologies.tech_id, C.Technologies.category, C.Technologies.sector,
                    C.Technologies.subsector, C.Technologies.main_activity, C.Technologies.name,
                    C.Technologies.unit, C.Technologies.investment, C.Technologies.fixed_om,
                    C.Technologies.variable_om, C.Technologies.ec_lifetime, C.Technologies.cap2act,
                    C.Technologies.dispatch_type, C.Technologies.hourly_profile,
                    C.Technologies.social_perception, C.Technologies.perceived_complexity,
                    C.Technologies.subsidy_subject, C.Technologies.feedin_subject,
                    C.Technologies.shedding_capacity, C.Technologies.shedding_volume,
                    C.Technologies.shedding_guarantee, C.Technologies.flexibility_form,
                    C.Technologies.flexibility_activity, C.Technologies.flexibility_capacity,
                    C.Technologies.flexibility_volume, C.Technologies.flexibility_range,
                    C.Technologies.flexibility_losses, C.Technologies.flexibility_nonnegotiable,
                    C.Technologies.buffer_up, C.Technologies.buffer_down, C.Technologies.buffer_capacity,
                    C.Technologies.tech_stock_deploy, C.Technologies.tech_stock_exist,
                ))
            else
                push!(missing_sheets, "Technologies")
            end

            if need("Infrastructure")
                sh = xf["Infrastructure"]
                idx = _col_index(_last_col(sh))
                hdr_group = _header_row_texts(sh, 1, idx)
                hdr_field = _header_row_texts(sh, 2, idx)
                hdr = _flatten_header(hdr_group, hdr_field)
                _check_headers!(missing_headers, "Infrastructure", hdr, (
                    C.Infrastructure.tech_id, C.Infrastructure.category, C.Infrastructure.name,
                    C.Infrastructure.unit, C.Infrastructure.investment, C.Infrastructure.fixed_om,
                    C.Infrastructure.ec_lifetime, C.Infrastructure.cap2act, C.Infrastructure.activity,
                ))
                _check_headers!(missing_headers, "Infrastructure", hdr_group, (
                    C.Infrastructure.planned_decommissioning_group, C.Infrastructure.stock_min_group,
                    C.Infrastructure.stock_max_group,
                ))
            else
                push!(missing_sheets, "Infrastructure")
            end

            if !need("EnergyBalance")
                push!(missing_sheets, "EnergyBalance")
            end

            if need("Retrofitting")
                sh = xf["Retrofitting"]
                hdr = _header_row_texts(sh, 1, _col_index(_last_col(sh)))
                _check_headers!(missing_headers, "Retrofitting", hdr, (
                    C.Retrofitting.tech_id_original, C.Retrofitting.tech_id_new,
                    C.Retrofitting.enabled, C.Retrofitting.investment_cost,
                ))
            else
                push!(missing_sheets, "Retrofitting")
            end

            if !need("Policies")
                push!(missing_sheets, "Policies")
            end
        end
    catch err
        return Dict{String,Any}("compatible" => false, "missingSheets" => ["<could not open as an Excel workbook: $(sprint(showerror, err))>"], "missingHeaders" => String[])
    end
    return Dict{String,Any}(
        "compatible" => isempty(missing_sheets) && isempty(missing_headers),
        "missingSheets" => missing_sheets,
        "missingHeaders" => missing_headers,
    )
end

# =============================================================================
# DuckDB compatibility (either model)
# =============================================================================

const _IESA_OPT_CORE_TABLES = String[
    "periods", "activity_types", "dispatch_types", "process_types", "flexibility_types", "range_types",
    "hourly_profile_types", "sectors", "nodes", "energy_labels", "interconnectors",
    "activities", "activity_volumes", "hours", "hourly_profiles", "price_profiles",
    "technologies", "technology_costs", "technology_stocks",
    "infrastructure", "infrastructure_costs",
    "energy_balance", "parameters",
]

# write_input_tables_duckdb! skips a table entirely when its underlying data
# is empty (e.g. no ActGrouping rows configured, no retrofittings defined) —
# that's by design, not a defect, so these must not gate "compatible". Report
# them separately as advisory, non-blocking gaps instead.
const _IESA_OPT_OPTIONAL_TABLES = String[
    "sectors_kev", "technology_flexibility_activities", "infrastructure_stocks",
    "retrofittings", "feedstock_use", "activity_efficiency_improvement",
    "activity_grouping", "node_emission_targets", "node_co2_budget",
]

const _IESA_SIM_TABLES = String[
    "activities", "activity_types", "agent_criteria", "agent_profiles", "agent_types", "criteria_weights",
    "energy_balance", "energy_types", "hourly_profile_types", "hourly_profiles", "infrastructure",
    "infrastructure_categories", "infrastructure_costs", "interconnectors", "parameter_categories",
    "parameters", "periods", "policy_feedins", "policy_subsidies", "policy_taxes", "population",
    "price_profiles", "retrofittings", "sectors", "technologies", "technology_categories",
    "technology_complexities", "technology_costs", "technology_dispatch_types",
    "technology_flexibility_activities", "technology_flexibility_forms", "technology_social_perceptions",
    "technology_stocks",
]

"""
    check_duckdb_compatibility(db_path) -> Dict{String,Any}

Check whether the DuckDB file at `db_path` has the core tables IESA-Opt.jl
(`write_input_tables_duckdb!`) or IESA-Sim (its own `mod0_load_duckdb.py`)
need. Returns `Dict("iesaOpt"=>Dict("compatible"=>Bool,"missing"=>[...],
"missingOptional"=>[...]), "iesaSim"=>Dict(...))`. `missing` only lists tables
that are always expected to exist; `missingOptional` lists ones
`write_input_tables_duckdb!` skips entirely when their source data is empty
(e.g. no retrofittings configured) — advisory, does not affect `compatible`.
"""
function check_duckdb_compatibility(db_path::AbstractString)::Dict{String,Any}
    con = _duckdb_connect(db_path; readonly = true)
    try
        existing = Set(String.(_duckdb_query_df(con, "SELECT table_name FROM information_schema.tables").table_name))
        missing_opt = [t for t in _IESA_OPT_CORE_TABLES if !(t in existing)]
        missing_opt_optional = [t for t in _IESA_OPT_OPTIONAL_TABLES if !(t in existing)]
        missing_sim = [t for t in _IESA_SIM_TABLES if !(t in existing)]
        return Dict{String,Any}(
            "iesaOpt" => Dict{String,Any}("compatible" => isempty(missing_opt), "missing" => missing_opt, "missingOptional" => missing_opt_optional),
            "iesaSim" => Dict{String,Any}("compatible" => isempty(missing_sim), "missing" => missing_sim),
        )
    finally
        DBInterface.close!(con)
        GC.gc()
    end
end

# =============================================================================
# Top-level dispatcher
# =============================================================================

"""
    check_file_compatibility(path) -> Dict{String,Any}

Dispatches to the Excel or DuckDB compatibility checkers by file extension
and returns a uniform report:
```julia
Dict("kind" => "excel"|"duckdb",
     "iesaOpt" => Dict("compatible"=>Bool, "missing"=>[...]),
     "iesaSim" => Dict("compatible"=>Bool, "missing"=>[...], "mergeCapable"=>Bool))
```
`mergeCapable` is `false` whenever `kind == "excel"` — there is no Julia
parser for IESA-Sim's Excel layout, so an IESA-Sim-shaped Excel file can be
recognized as compatible but cannot fill an IESA-Sim gap in the merge
wizard; only an IESA-Sim DuckDB can.
"""
function check_file_compatibility(path::AbstractString)::Dict{String,Any}
    isfile(path) || return Dict{String,Any}("kind" => "unknown",
        "iesaOpt" => Dict("compatible" => false, "missing" => ["file not found: $(path)"]),
        "iesaSim" => Dict("compatible" => false, "missing" => ["file not found: $(path)"], "mergeCapable" => false))

    ext = lowercase(splitext(path)[2])
    if ext in (".xlsx", ".xlsm", ".xls")
        opt = check_iesa_opt_excel_compatibility(path)
        sim = check_iesa_sim_excel_compatibility(path)
        return Dict{String,Any}(
            "kind" => "excel",
            "iesaOpt" => Dict("compatible" => opt["compatible"], "missing" => vcat(opt["missingSheets"], opt["missingHeaders"])),
            "iesaSim" => Dict("compatible" => sim["compatible"], "missing" => vcat(sim["missingSheets"], sim["missingHeaders"]), "mergeCapable" => false),
        )
    elseif ext == ".duckdb"
        report = check_duckdb_compatibility(path)
        report["iesaSim"]["mergeCapable"] = report["iesaSim"]["compatible"]
        return Dict{String,Any}("kind" => "duckdb", "iesaOpt" => report["iesaOpt"], "iesaSim" => report["iesaSim"])
    else
        return Dict{String,Any}("kind" => "unknown",
            "iesaOpt" => Dict("compatible" => false, "missing" => ["unrecognized file extension: $(ext)"]),
            "iesaSim" => Dict("compatible" => false, "missing" => ["unrecognized file extension: $(ext)"], "mergeCapable" => false))
    end
end
