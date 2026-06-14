using Test
using IESAOpt
using DataFrames
using Statistics: cor

# Tiny fixture builder. Mimics the structure produced by Phase 4
# (run_scenario_space → ScenarioResult) without paying solver cost.
function _make_test_result(; method = :lhs, n = 5)
    targets = [
        LeafTarget(:price_co2, (:NL,); type = :set, min = 50.0, max = 200.0,
                   label = "co2_NL"),
        LeafTarget(:emissionTargetBunker, (:NL, 2050); type = :multiply,
                   min = 0.5, max = 1.5, label = "bunker_2050"),
    ]
    spec = ScenarioSpec(name = "phase5_fixture", method = method,
                        n_variants = n, seed = 42, targets = targets)
    # Deterministic samples so the asserts below are stable.
    # Construct objective = 1000 + 2*co2 - 100*bunker so co2 dominates and the
    # Pareto front (minimize=both) is the row with the lowest objective.
    samples = Matrix{Float64}(undef, n, 2)
    variants = VariantResult[]
    for i in 1:n
        co2 = 50.0 + (i - 1) * (150.0 / max(n - 1, 1))   # 50..200
        bn  = 0.5 + (i - 1) * (1.0  / max(n - 1, 1))     # 0.5..1.5
        samples[i, 1] = co2
        samples[i, 2] = bn
        obj = 1000.0 + 2.0 * co2 - 100.0 * bn
        # Last variant is infeasible to exercise the OPTIMAL filter.
        status = i == n ? "INFEASIBLE" : "OPTIMAL"
        push!(variants, VariantResult(
            variant_id = i,
            leaf_values = [co2, bn],
            objective = obj,
            term_status = status,
            primal_status = status == "OPTIMAL" ? "FEASIBLE_POINT" : "NO_SOLUTION",
            worker_pid = 1,
            build_seconds = 3.0,
            apply_seconds = 0.05,
            solve_seconds = 1.0 + i * 0.1,
            error = nothing))
    end
    return ScenarioResult(spec, samples, variants, 8.7)
end

@testset "objective_table — schema + values" begin
    res = _make_test_result(n = 5)
    df = objective_table(res)
    @test nrow(df) == 5
    # variant_id + 2 sample cols + 8 metadata cols = 11
    @test ncol(df) == 11
    @test :variant_id in propertynames(df)
    @test :co2_NL in propertynames(df)
    @test :bunker_2050 in propertynames(df)
    @test :objective in propertynames(df)
    @test :term_status in propertynames(df)
    @test :worker_pid in propertynames(df)
    @test :solve_seconds in propertynames(df)
    @test :error in propertynames(df)
    # Row 1: co2=50, bunker=0.5, obj = 1000 + 100 - 50 = 1050
    @test df.co2_NL[1] ≈ 50.0
    @test df.bunker_2050[1] ≈ 0.5
    @test df.objective[1] ≈ 1050.0
    # Errors must round-trip as empty strings for nothing.
    @test all(x -> x == "", df.error)
    # term_status mixing OPTIMAL + INFEASIBLE.
    @test df.term_status[end] == "INFEASIBLE"
    @test count(==("OPTIMAL"), df.term_status) == 4
end

@testset "objective_table — inconsistent variants raises" begin
    res = _make_test_result(n = 3)
    bad = ScenarioResult(res.spec, res.samples,
                         res.variants[1:2],   # length mismatch
                         res.runtime_seconds)
    @test_throws ArgumentError objective_table(bad)
end

@testset "sensitivity_scan — correlations + ranking" begin
    res = _make_test_result(n = 5)
    df = sensitivity_scan(res)
    @test names(df) == ["target", "correlation", "abs_corr", "rank", "n_used"]
    @test nrow(df) == 2
    # Only the 4 OPTIMAL rows are used.
    @test all(df.n_used .== 4)
    # Both targets are perfectly correlated with objective in this fixture
    # (co2 positively, bunker negatively in the optimal subset).
    @test all(abs.(df.correlation) .≈ 1.0)
    @test df.rank == [1, 2]
end

@testset "sensitivity_scan — too few optimal variants" begin
    res = _make_test_result(n = 3)
    @test_throws ArgumentError sensitivity_scan(res; min_optimal = 5)
end

@testset "sensitivity_scan — zero-variance target returns NaN" begin
    res = _make_test_result(n = 5)
    # Override target column 2 with a constant value -> std == 0 -> NaN cor
    constants = fill(1.0, 5)
    samples2 = copy(res.samples)
    samples2[:, 2] .= constants
    variants2 = [VariantResult(
        variant_id = v.variant_id,
        leaf_values = [samples2[v.variant_id, 1], samples2[v.variant_id, 2]],
        objective = v.objective,
        term_status = v.term_status,
        primal_status = v.primal_status,
        worker_pid = v.worker_pid,
        build_seconds = v.build_seconds,
        apply_seconds = v.apply_seconds,
        solve_seconds = v.solve_seconds,
        error = v.error) for v in res.variants]
    res2 = ScenarioResult(res.spec, samples2, variants2, res.runtime_seconds)
    df = sensitivity_scan(res2)
    # The constant target must be present and report NaN correlation.
    const_row = df[df.target .== "bunker_2050", :]
    @test nrow(const_row) == 1
    @test isnan(const_row.correlation[1])
    # NaN rows must be ranked last.
    @test const_row.rank[1] == 2
end

@testset "pareto_front — both minimise" begin
    res = _make_test_result(n = 5)
    # Lower co2 AND lower objective at the same time -> only variant 1 is
    # non-dominated. (variant 1: co2=50, obj=1050; later variants have higher
    # co2 AND higher objective.)
    front = pareto_front(res, :co2_NL, :objective; minimize = (true, true))
    @test nrow(front) == 1
    @test front.variant_id[1] == 1
end

@testset "pareto_front — one max, one min" begin
    res = _make_test_result(n = 5)
    # Maximise co2 (smaller co2 worse) AND minimise objective. The fixture
    # makes obj increase with co2, so this is a true trade-off -> every
    # OPTIMAL variant is non-dominated.
    front = pareto_front(res, :co2_NL, :objective; minimize = (false, true))
    @test nrow(front) == 4   # 4 OPTIMAL variants
    # Sorted by :co2_NL ascending.
    @test issorted(front.co2_NL)
end

@testset "pareto_front — unknown column rejected" begin
    res = _make_test_result(n = 5)
    @test_throws ArgumentError pareto_front(res, :nonexistent, :objective)
    @test_throws ArgumentError pareto_front(res, :objective, :also_nope)
end

@testset "pareto_front — no optimal variants" begin
    res = _make_test_result(n = 2)
    # Force everything to infeasible.
    bad_variants = [VariantResult(
        variant_id = v.variant_id, leaf_values = v.leaf_values,
        objective = v.objective, term_status = "INFEASIBLE",
        primal_status = "NO_SOLUTION", worker_pid = v.worker_pid,
        build_seconds = v.build_seconds, apply_seconds = v.apply_seconds,
        solve_seconds = v.solve_seconds, error = v.error) for v in res.variants]
    res2 = ScenarioResult(res.spec, res.samples, bad_variants, res.runtime_seconds)
    front = pareto_front(res2, :co2_NL, :objective)
    @test nrow(front) == 0
end
