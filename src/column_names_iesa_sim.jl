# =============================================================================
# column_names_iesa_sim.jl — named header-text constants for IESA-Sim's own
# Excel workbook layout.
#
# Mirrors column_names.jl's structure (one module per sheet), but sourced
# from the reference Python project's own header constants
# (IESA-Sim-v1.09-py/Constants/Parameters.py), not IESA-Opt.jl's workbook.
# Used only for compatibility *checking* (compat_check.jl) — there is no
# Julia parser for IESA-Sim's Excel layout (that logic lives only in
# IESA-Sim-v1.09-py/code/read/mod0_read_data_save_duck.py), so an IESA-Sim
# Excel file can be recognized here but not merged in; only an already-built
# IESA-Sim DuckDB can fill an IESA-Sim gap in the merge wizard.
# =============================================================================
module ColumnNamesIesaSim

module Parameters
    const powinv_spbt_benchmark  = "Power investments simple payback time benchmark"
    const powinv_spbt_min        = "Power investments simple payback time minimum"
    const powinv_cr_threshold    = "Power investments capture rate threshold"
    const powinv_cr_min          = "Power investments capture rate minimum"
    const powinv_nuf_threshold   = "Power investments normalized utilization factor threshold"
    const powinv_nuf_min         = "Power investments normalized utilization factor minimum"
    const scarcity_penalization  = "Scarcity penalization parameter"
    const gas_premium            = "Gas price premium spread under high demand"
    const voll_value             = "Value of lost load"
    const min_spread_value       = "Minimum battery spread"
    const gov_dr                 = "Government depreciation rate"
    const exports_value          = "Exports value as ratio of crude oil (0 for no)"
end

module Types
    const activity_type      = "Activity Types"
    const sectors             = "Sectors"
    const energy_labels       = "Energy Labels"
    const energy_price_init   = "Prices Initialization"
end

module Agents
    const types        = "Agent Types"
    const profiles      = "Agent profiles"
    const ic_criteria   = "Weights for investment criteria"
    const rates         = "Expected rates of return"
end

module Activities
    const name                = "Activities"
    const periods_start       = "Evolution of volumes in time"
    const activity_resolution = "Dispatch resolution"
    const activity_type       = "Activity Type"
    const energy_label        = "Energy Label"
    const agent_profile       = "Agent Profile"
end

module HourlyProfiles
    const hour  = "hour"
    const day   = "day"
    const month = "month"
end

module PriceProfiles
    const interconnector = "Electricity IC"
end

# 2-row header (group/field), flattened as "group / field" — same convention
# as column_names.jl's Technologies/Infrastructure.
module Technologies
    const tech_id               = "Tech. Specifics / Tech_ID"
    const category               = "Tech. Specifics / Category"
    const sector                 = "Tech. Specifics / Sector"
    const subsector              = "Tech. Specifics / Sub-sector"
    const main_activity          = "Tech. Specifics / Main Activity"
    const name                   = "Tech. Specifics / Name"
    const unit                   = "Tech. Specifics / UoC"
    const investment             = "Cost data / Investment"
    const fixed_om               = "Cost data / Fixed O&M"
    const variable_om            = "Cost data / Variable O&M"
    const ec_lifetime            = "Cost data / Ec. Lifetime"
    const cap2act                = "Operation data / Cap2Act"
    const dispatch_type          = "Operation data / Type of process"
    const hourly_profile         = "Operation data / Type of profile"
    const social_perception      = "Agents parameters / Social perception"
    const perceived_complexity   = "Agents parameters / Perceived complexity"
    const subsidy_subject        = "Subsidies influence / Subject to investment subsidy"
    const feedin_subject         = "Subsidies influence / Subject to feed-in tariff subsidy"
    const shedding_capacity      = "Asymetric flexibility / Shedding capacity"
    const shedding_volume        = "Asymetric flexibility / Shedding volume"
    const shedding_guarantee     = "Asymetric flexibility / Contract guaranteed volume"
    const flexibility_form       = "Flexibility data / Form of Flexibility"
    const flexibility_activity   = "Flexibility data / Benefited activity"
    const flexibility_capacity   = "Flexibility data / Flexible installed capacity"
    const flexibility_volume     = "Flexibility data / Storage capacity / (hours of charge)"
    const flexibility_range      = "Flexibility data / Shifting range"
    const flexibility_losses     = "Flexibility data / Losses"
    const flexibility_nonnegotiable = "Flexibility data / Non-negotiable load"
    const buffer_up              = "Network buffers / Upward capacity"
    const buffer_down             = "Network buffers / Downward capacity"
    const buffer_capacity         = "Network buffers / Buffer capacity / (in relation to discharge)"
    const tech_stock_deploy       = "Technology Potentials / Maximum technology deployment"
    const tech_stock_exist        = "Technology Potentials / Current Installed Capacity"
end

module Infrastructure
    const tech_id                  = "Tech. Specifics / Tech_ID"
    const category                  = "Tech. Specifics / Category"
    const name                      = "Tech. Specifics / Name"
    const unit                      = "Tech. Specifics / UoC"
    const investment                = "Cost data / Investment"
    const fixed_om                  = "Cost data / Fixed O&M"
    const ec_lifetime                = "Cost data / Ec. Lifetime"
    const cap2act                    = "Other data / Cap2Act"
    const activity                   = "Other data / Activity Constrained"
    # Single-column group (no distinct field name) — looked up against the
    # unflattened group row, same convention as column_names.jl.
    const planned_decommissioning_group = "Planned decommisioning"
    const stock_min_group                = "Minimum stock in a year"
    const stock_max_group                = "Maximum stock in a year"
end

module Retrofitting
    const tech_id_original = "Tech_ID Original "
    const tech_id_new      = "Tech_ID New"
    const enabled          = "Enabled\n[y/n]"
    const investment_cost  = "Overnight retrofitting investment [M€/UoC]"
end

end # module ColumnNamesIesaSim
