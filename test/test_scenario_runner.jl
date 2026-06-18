using Test
using IESAOpt
using JuMP
using HiGHS

# =============================================================================
# Phase 3 — Scenario campaign runner
#
# We unit-test the runner's *pieces*:
#   * `VariantResult` struct (defaults + named ctor)
#   * `_run_one_variant!` (the body of the per-variant loop)
#   * `_campaign_optimizer` solver factory
#
# The orchestration layer (`run_campaign` serial + Distributed paths) is
# exercised end-to-end by local manual diagnostics against a real workbook
# with a real `build_ts_lp!` call. Unit-testing
# `run_campaign` itself would require monkey-patching `_build_campaign_model`
# which is fragile (the function reference is the same singleton — restoring
# the original easily produces infinite recursion).
# =============================================================================

# Minimal model fixture: one var, one named constraint that the default
# emission-cap mutation builder can find by name.
function _emcap_fixture()
    m = Model(HiGHS.Optimizer)
    set_silent(m)
    @variable(m, u >= 0, base_name = "u")
    @constraint(m, u <= 100.0, base_name = "emTargetAir[NL,2050]")
    @objective(m, Max, u)
    return m
end

@testset "VariantResult struct" begin
    r = VariantResult(variant_id = 7)
    @test r.variant_id == 7
    @test isnan(r.objective)
    @test r.error === nothing
    @test r.term_status == ""
    @test r.leaf_values == Float64[]
    @test r.worker_pid == 1  # default = master

    r2 = VariantResult(variant_id = 1,
                       objective = 42.0,
                       term_status = "OPTIMAL",
                       primal_status = "FEASIBLE_POINT",
                       leaf_values = [3.14, 2.71],
                       build_seconds = 1.5,
                       apply_seconds = 0.2,
                       solve_seconds = 0.7,
                       worker_pid = 3)
    @test r2.objective == 42.0
    @test r2.term_status == "OPTIMAL"
    @test r2.leaf_values == [3.14, 2.71]
    @test r2.build_seconds == 1.5
    @test r2.worker_pid == 3
end

@testset "_run_one_variant! happy path" begin
    m = _emcap_fixture()
    optimize!(m)
    @test isapprox(objective_value(m), 100.0; atol = 1e-6)

    md = ModelData()
    md.params.emissionTargetAir[(:NL, 2050)] = 100.0
    changes = LeafChange[LeafChange(:emissionTargetAir, (:NL, 2050), 40.0)]

    r = IESAOpt._run_one_variant!(m, md, changes, 5)
    @test r.variant_id == 5
    @test r.term_status == "OPTIMAL"
    @test r.error === nothing
    @test isapprox(r.objective, 40.0; atol = 1e-6)
    @test r.leaf_values == [40.0]
    @test r.solve_seconds >= 0
    @test r.apply_seconds >= 0
end

@testset "_run_one_variant! second & third variants on same model" begin
    m = _emcap_fixture()
    md = ModelData()
    md.params.emissionTargetAir[(:NL, 2050)] = 100.0

    r1 = IESAOpt._run_one_variant!(m, md,
        LeafChange[LeafChange(:emissionTargetAir, (:NL, 2050), 80.0)], 1)
    r2 = IESAOpt._run_one_variant!(m, md,
        LeafChange[LeafChange(:emissionTargetAir, (:NL, 2050), 25.0)], 2)
    r3 = IESAOpt._run_one_variant!(m, md,
        LeafChange[LeafChange(:emissionTargetAir, (:NL, 2050), 50.0)], 3)

    @test r1.term_status == "OPTIMAL" && isapprox(r1.objective, 80.0; atol = 1e-6)
    @test r2.term_status == "OPTIMAL" && isapprox(r2.objective, 25.0; atol = 1e-6)
    @test r3.term_status == "OPTIMAL" && isapprox(r3.objective, 50.0; atol = 1e-6)
    @test [r1.variant_id, r2.variant_id, r3.variant_id] == [1, 2, 3]
end

@testset "_run_one_variant! error path: missing constraint" begin
    m = Model(HiGHS.Optimizer)
    set_silent(m)
    @variable(m, u >= 0)
    @constraint(m, u <= 100.0, base_name = "someOtherName")
    @objective(m, Max, u)

    md = ModelData()
    md.params.emissionTargetAir[(:NL, 2050)] = 100.0
    r = IESAOpt._run_one_variant!(m, md,
        LeafChange[LeafChange(:emissionTargetAir, (:NL, 2050), 50.0)], 1)
    @test r.term_status == "ERROR"
    @test r.error !== nothing
    @test occursin("not found", r.error)
end

@testset "run_campaign empty input" begin
    md = ModelData()
    @test run_campaign(md, Vector{LeafChange}[]) == VariantResult[]
end

@testset "_campaign_optimizer factory" begin
    f_highs = IESAOpt._campaign_optimizer(:highs, 1)
    @test f_highs !== nothing
    m = Model(f_highs)
    set_silent(m)
    @variable(m, x >= 0)
    @objective(m, Min, x)
    optimize!(m)
    @test termination_status(m) == JuMP.MOI.OPTIMAL
    @test isapprox(objective_value(m), 0.0; atol = 1e-8)

    @test_throws ArgumentError IESAOpt._campaign_optimizer(:bogus, 1)
end

@testset "scenario Gurobi RD tuned attributes" begin
    attrs = IESAOpt._campaign_gurobi_attributes(3, 40)
    @test attrs["Threads"] == 3
    @test attrs["OutputFlag"] == 0
    @test attrs["AggFill"] == 100
    @test attrs["Aggregate"] == 2
    @test attrs["Presolve"] == 1
    @test attrs["ScaleFlag"] == 0

    attrs = IESAOpt._campaign_gurobi_attributes(3, 40, Dict("ScaleFlag" => 2, "Crossover" => -1))
    @test attrs["ScaleFlag"] == 2
    @test attrs["Crossover"] == -1
end
