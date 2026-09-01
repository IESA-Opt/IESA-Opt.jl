using Test
using DataFrames
using IESAOpt
using JuMP

@testset "robustness matrix pivot" begin
    rows = DataFrame(
        candidate_design_id = ["d1", "d1", "d2", "d2"],
        originating_future_id = ["s1", "s1", "s2", "s2"],
        evaluation_future_id = ["s1", "s2", "s1", "s2"],
        feasible = [true, true, true, false],
        solver_status = ["OPTIMAL", "OPTIMAL", "OPTIMAL", "INFEASIBLE"],
        primal_status = ["FEASIBLE_POINT", "FEASIBLE_POINT", "FEASIBLE_POINT", ""],
        objective_value = Union{Missing,Float64}[10.0, 12.0, 11.0, missing],
        optimal_objective_evaluation_future = Union{Missing,Float64}[10.0, 11.0, 10.0, 11.0],
        absolute_regret = Union{Missing,Float64}[0.0, 1.0, 1.0, missing],
        relative_regret = Union{Missing,Float64}[0.0, 1 / 11, 0.1, missing],
        co2_price = Union{Missing,Float64}[1.0, 2.0, 3.0, missing],
        error = Union{Missing,String}[missing, missing, missing, "infeasible"],
        evaluated_at = ["", "", "", ""],
    )

    objective = robustness_matrix(rows)
    @test names(objective) == ["candidate_design_id", "originating_future_id", "s1", "s2"]
    @test objective[objective.candidate_design_id .== "d1", :s1][1] == 10.0
    @test objective[objective.candidate_design_id .== "d2", :s2][1] === missing

    feasible = robustness_matrix(rows; kind = :feasible)
    @test feasible[feasible.candidate_design_id .== "d1", :s2][1] == 1.0
    @test feasible[feasible.candidate_design_id .== "d2", :s2][1] == 0.0
end

@testset "fixed design preserves operational freedom" begin
    model = Model()
    @variable(model, cap_investments, base_name = "cap_investments[tech,2050]")
    @variable(model, techStock, base_name = "techStock[tech,2050]")
    @variable(model, tech_use, base_name = "tech_use[tech,2050]")
    fixed = IESAOpt._fix_design!(model, [
        DesignValue("cap_investments", "cap_investments[tech,2050]", 4.0),
        DesignValue("techStock", "techStock[tech,2050]", 4.0),
    ])
    @test fixed == 1
    @test is_fixed(cap_investments)
    @test !is_fixed(techStock)
    @test !is_fixed(tech_use)
end
