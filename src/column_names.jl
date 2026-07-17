# =============================================================================
# column_names.jl — named header-text constants for the IESA-Opt Excel workbook
#
# Mirrors `Constants/Parameters.py` in the reference IESA-Sim Python project:
# every column `data_reading.jl` reads is located by its header text (verified
# against data/default_data.xlsx), not a hardcoded Excel column letter, so the
# reader keeps working if columns are reordered/inserted as long as the header
# text itself doesn't change.
#
# Sheets with a 2-row (group/field) header — Technologies, Infrastructure — are
# looked up via the *flattened* "group / field" text (group forward-filled
# across its span and joined with " / ", exactly like the Python loader's
# `flatten_header`), since a few field names repeat under different groups
# (e.g. Technologies' "Benefited activity", used by both flexibility and
# buffer data). Sheets where the header is effectively single-row for the
# fields read here use the plain field text.
#
# A handful of columns have no distinct field name at all — only a period-year
# row and a group label (e.g. Technologies' "Planned decommissioning" block,
# NodeParameters' emission-target blocks) — those constants hold the *group*
# label and are looked up against the unflattened group row directly.
# =============================================================================
module ColumnNames

module Parameters
    const xc_transmission_loss  = "XC Transmission Loss"
    const baseload_threshold    = "Flexibility threshold for baseload"
    const shedding_in_load      = "Account for shedding technologies as part of the load"
    const social_discount_rate  = "Social discount rate"
    const base_year             = "Base year (for NPV calculations)"
    const active_constraint_set = "Emission Policy"
end

module Types
    const dispatch_type    = "Market Types"
    const activity_type    = "Activity Types"
    const process_type     = "Process Types"
    const flexibility_type = "Flexibility Types"
    const range_type       = "Range Types"
    const sectors          = "Sectors"
    const iem_sector       = "IEM sector"
    const nodes            = "Nodes"
    const node_name        = "Country name"
    const iem_node         = "IEM node"
    const energy_labels    = "Energy Labels"
    const is_renewable     = "Renewables"
    const sectors_kev      = "KEV Sectors"
end

module NodeParameters
    const node                       = "Node"
    const emission_target_air        = "Emission target [MtonCO2eq/yr]"
    const cumulative_emission_budget = "Cumulative emission"
    const cumulative_co2_storage     = "Cumulative CO2 storage capacity"
    const emission_target_all        = "Emission target including feedstock & bunkers (Scope3) [MtonCO2eq/yr]"
    const emission_target_bunker     = "Bunker Emissions"
    const emission_target_feedstock  = "FeedStock Emissions"
end

module Activities
    const name                = "Activities"
    const unit                = "UoA"
    const volumes_group       = "Evolution of volumes in time"
    const change_max          = "Maximum transformation"
    const dispatch_resolution = "Dispatch resolution"
    const activity_type       = "Activity Type"
    const node                = "Node"
    const emission_target_bin = "Target"
    const energy_label        = "Energy Label"
end

module HourlyProfiles
    const hour  = "hour"
    const month = "month"
end

module PriceProfiles
    const month = "month"
end

# 2-row header (row2=group, row3=field), flattened as "group / field".
module Technologies
    const tech_id            = "Tech. Specifics / Tech_ID"
    const sector_kev          = "Tech. Specifics / Policy Sectors"
    const category            = "Tech. Specifics / Category"
    const sector              = "Tech. Specifics / Sector"
    const subsector           = "Tech. Specifics / Sub-sector"
    const main_activity       = "Tech. Specifics / Main Activity"
    const name                = "Tech. Specifics / Name"
    const unit                = "Tech. Specifics / UoC"
    const investment          = "Cost data / Investment "
    const salvage_value       = "Cost data / Salvage value"
    const fixed_om            = "Cost data / Fixed O&M "
    const variable_om         = "Cost data / Variable O&M "
    const wacc                = "Cost data / WACC"
    const construction_time   = "Cost data / Const. Time"
    const economic_lifetime   = "Cost data / Ec. Lifetime "
    const technical_lifetime  = "Cost data / Tech. Lifetime "
    const cap2act             = "Operation data / Cap2Act"
    const process_type        = "Operation data / Type of process"
    const profile_type        = "Operation data / Type of profile"
    const ramping             = "Operation data / Ramping constraint"
    const chp_prod            = "CHP flexibility data / CHP product"
    const chp_fuel            = "CHP flexibility data / CHP fuel"
    const chp_eta             = "CHP flexibility data / CHP η"
    const chp_range           = "CHP flexibility data / CHP heat balance range"
    const chp_dev_use         = "CHP flexibility data / CHP deviation in USE          tolerance"
    const chp_dev_ptoh        = "CHP flexibility data / CHP deviation in     P/H RATIO     tolerance"
    const shed_capacity       = "Asymetric flexibility / Shedding capacity"
    const shed_volume         = "Asymetric flexibility / Shedding volume"
    const shed_range          = "Asymetric flexibility / Range for demand curtailing"
    const pumphead_ratio      = "Hydro Reservoirs / Pump to head ratio"
    const reservoir_capacity  = "Hydro Reservoirs / Reservoir capacity"
    const phs_losses          = "Hydro Reservoirs / Pumping losses"
    const flexibility_form    = "Flexibility data / Form of Flexibility"
    const flex_activity       = "Flexibility data / Benefited activity"
    const flex_capacity       = "Flexibility data / Flexible capacity"
    const flex_storage        = "Flexibility data / Storage capacity"
    const flex_range          = "Flexibility data / Shifting range"
    const flex_losses         = "Flexibility data / Losses"
    const flex_nnload         = "Flexibility data / Non-negotiable load"
    const avg_journey         = "Flexibility data / Average journey duration"
    const avg_speed           = "Flexibility data / Average speed"
    const buffer_activity     = "Network buffers / Benefited activity"
    const buffer_up           = "Network buffers / Upward capacity"
    const buffer_down         = "Network buffers / Downward capacity"
    const buffer_capacity     = "Network buffers / Buffer capacity"
    const buffer_storage      = "Network buffers / Current installed capacity needed"
    const change_max          = "Network buffers / Maximum technology deployment"
    const stock_exist         = "Network buffers / Current Installed Capacity"
    # No distinct field name of their own (row3 is just period-years or ordinal
    # markers) — looked up against the unflattened group row.
    const decom_planned_group = "Planned decommissioning"
    const stock_min_group     = "Minimum stock in a year"
    const stock_max_group     = "Maximum stock in a year"
    const use_min_group       = "Minimum use in a year"
    const use_max_group       = "Maximum use in a year"
    const no_new_invest_group = "No new investments"
    const no_eco_decom_group  = "No economic/early decommissioning"
end

module EnergyBalance
    const tech_id = "Tech_ID"
    # Row-2 group label of the single blank spacer column between the tech
    # metadata block and the per-activity balance columns (which start at the
    # *next* column) — row-3's last metadata field name ("International
    # emissions") is one column too early, since it's immediately followed by
    # that blank spacer, not directly by the first activity column.
    const data_source_col = "Data source"
end

# 2-row header (row2=group, row3=field), flattened as "group / field".
module Infrastructure
    const tech_id            = "Tech. Specifics / Tech_ID"
    const sector_kev          = "Tech. Specifics / Policy Sectors"
    const category            = "Tech. Specifics / Category"
    const sector              = "Tech. Specifics / Sector"
    const subsector           = "Tech. Specifics / Sub-sector"
    const name                = "Tech. Specifics / Name"
    const unit                = "Tech. Specifics / UoC"
    const investment          = "Cost data / Investment "
    # The sheet's own header text at this position is "Economic decommisioning",
    # not "Salvage value" — kept verbatim (not "corrected") so the column
    # resolved here is exactly the one the pre-existing hardcoded-letter reader
    # used; whether that's itself a workbook labeling mistake is out of scope
    # for this lookup-mechanism refactor.
    const salvage_value       = "Cost data / Economic decommisioning"
    const fixed_om            = "Cost data / Fixed O&M "
    const wacc                = "Cost data / WACC"
    const economic_lifetime   = "Cost data / Ec. Lifetime "
    const technical_lifetime  = "Cost data / Tech. Lifetime "
    const cap2act             = "Other data / Cap2Act"
    const infra_range         = "Other data / Constraining range"
    const infra_activity      = "Other data / Activity Constrained"
    const change_max          = "Other data / Maximum technology deployment"
    # Single-column group (no period block) — looked up against the
    # unflattened group row.
    const stock_exist         = "Existing"
    const decom_planned_group = "Planned decommisioning"
    const stock_min_group     = "Minimum stock in a year"
    const stock_max_group     = "Maximum stock in a year"
end

module ActGrouping
    const name                = "Activity Group"
    const dispatch_type       = "Dispatch resolution"
    const activity_type       = "Activity Type"
    const node                = "Node"
    const emission_target_bin = "Target"
    const energy_label        = "Energy Label"
    const activity_original   = "New Activity"
    const activity_group      = "Grouped Activities"
end

module EffLearning
    const tech_id      = "Tech_ID"
    const activity     = "Activity"
    const period_group = "Efficiency Learning [%2020]"
end

module Feedstocks
    const tech_id  = "Tech_ID"
    const activity = "Activity"
    const use      = "Feedstock Use"
end

module Retrofitting
    const from_tech  = "Tech_ID Original "
    const to_tech    = "Tech_ID New"
    const enabled    = "Enabled\n[y/n]"
    const investment = "Overnight retrofitting investment [M€/UoC]"
end

end # module ColumnNames
