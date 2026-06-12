"""
scripts/smoke_test_read.jl — quick verification that read_data + derive_sets +
compute_derived_params work end-to-end against `data/default_data.xlsx`.

Run from the repository root:
    julia --project=. scripts/smoke_test_read.jl
"""

using IESA_J

const XLSX_PATH = joinpath(@__DIR__, "..", "data", "default_data.xlsx")

println("Loading $(XLSX_PATH) ...")
md = read_data(XLSX_PATH)

println("---- SETS ----")
println("tech_balancers       = ", length(md.sets.tech_balancers))
println("tech_infra           = ", length(md.sets.tech_infra))
println("technologies (union) = ", length(md.sets.technologies))
println("activities_original  = ", length(md.sets.activities_original))
println("activities_group     = ", length(md.sets.activities_group))
println("activities           = ", length(md.sets.activities))
println("activities_solve     = ", length(md.sets.activities_solve))
println("activities_balance   = ", length(md.sets.activities_balance))
println("activities_hour      = ", length(md.sets.activities_hour))
println("activities_target    = ", length(md.sets.activities_target))
println("tech_hourlyDispatch  = ", length(md.sets.tech_hourlyDispatch))
println("tech_hourlyCHPflex   = ", length(md.sets.tech_hourlyCHPflex))
println("tech_shedding        = ", length(md.sets.tech_shedding))
println("tech_flexible        = ", length(md.sets.tech_flexible))
println("tech_fStorage        = ", length(md.sets.tech_fStorage))
println("tech_gasBuffer       = ", length(md.sets.tech_gasBuffer))
println("tech_emission        = ", length(md.sets.tech_emission))
println("hours_orig           = ", length(md.sets.hours_orig))
println("profile_typeRead     = ", length(md.sets.profile_typeRead))
println("nodes                = ", length(md.sets.nodes))
println("periods              = ", md.sets.periods)
println("periods_solve        = ", md.sets.periods_solve)
println()
println("---- PARAMS ----")
println("scenario_description = ", md.params.scenario_description)
println("base_year            = ", md.params.base_year)
println("hoursPer_day         = ", md.params.hoursPer_day)
println("inv_cost entries                 = ", length(md.params.inv_cost))
println("fom_cost entries                 = ", length(md.params.fom_cost))
println("economic_lifetime entries        = ", length(md.params.economic_lifetime))
println("hourly_profilesReadOrig entries  = ", length(md.params.hourly_profilesReadOrig))
println("activity_balancesRef entries     = ", length(md.params.activity_balancesRef))
println("activity_balances entries        = ", length(md.params.activity_balances))
println("CHP_eta entries                  = ", length(md.params.CHP_eta))
println("CHP_eps entries                  = ", length(md.params.CHP_eps))
println("CRF entries                      = ", length(md.params.CRF))
println("InvMat_lifeTime entries          = ", length(md.params.InvMat_lifeTime))
println("decomMat_NewInv entries          = ", length(md.params.decomMat_NewInv))
println("dayPer_hour entries              = ", length(md.params.dayPer_hour))
println("period_weight entries            = ", length(md.params.period_weight))
println("period_span entries              = ", length(md.params.period_span))
println("social_discount_factor entries   = ", length(md.params.social_discount_factor))
println("flex_loss_charge entries         = ", length(md.params.flex_loss_charge))
println("flex_loss_discharge_eff entries  = ", length(md.params.flex_loss_discharge_eff))
println("dQ_hourly entries                = ", length(md.params.dQ_hourly))
println()
println("Smoke test OK.")
