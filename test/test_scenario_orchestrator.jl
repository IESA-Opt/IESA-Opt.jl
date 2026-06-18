using Test
using IESAOpt
using IESAOpt: _sample_lhs_targets, _sample_sobol_targets, _sample_morris_targets,
               _sample_factorial_targets, _spec_to_dict, _dict_to_spec,
               _target_to_dict, _dict_to_target,
               _indices_to_str, _str_to_indices

@testset "LeafTarget construction" begin
    t = LeafTarget(:emissionTargetBunker, (:NL, 2050); type = :multiply, min = 0.5, max = 1.5)
    @test t.field    == :emissionTargetBunker
    @test t.indices  == (:NL, 2050)
    @test t.type     == :multiply
    @test t.min      == 0.5
    @test t.max      == 1.5
    @test t.step     === nothing
    @test t.label    == "emissionTargetBunker(:NL, 2050)"

    # Auto-wraps a bare scalar index into a 1-tuple.
    t2 = LeafTarget(:totalSlack, :NL; type = :set, min = 0.0, max = 1.0, label = "slack")
    @test t2.indices == (:NL,)
    @test t2.label   == "slack"

    # Rejects min > max.
    @test_throws ArgumentError LeafTarget(:x, (1,); type = :set, min = 1.0, max = 0.0)
    # Rejects bad type.
    @test_throws ArgumentError LeafTarget(:x, (1,); type = :reset, min = 0.0, max = 1.0)
    # Rejects negative step.
    @test_throws ArgumentError LeafTarget(:x, (1,); type = :set, min = 0.0, max = 1.0, step = -0.1)
end

@testset "ScenarioSpec construction" begin
    targets = [LeafTarget(:emissionTargetBunker, (:NL, 2050); type = :multiply, min = 0.5, max = 1.5)]
    spec = ScenarioSpec(name = "test", method = :lhs, n_variants = 8, seed = 42, targets = targets)
    @test spec.name       == "test"
    @test spec.method     == :lhs
    @test spec.n_variants == 8
    @test spec.seed       == 42
    @test length(spec.targets) == 1

    # Empty targets rejected.
    @test_throws ArgumentError ScenarioSpec(name = "t", method = :lhs, n_variants = 1, seed = 0, targets = LeafTarget[])
    # Non-positive n_variants rejected.
    @test_throws ArgumentError ScenarioSpec(name = "t", method = :lhs, n_variants = 0, seed = 0, targets = targets)
end

@testset "sample_scenario_space — LHS" begin
    targets = [LeafTarget(:a, (1,); type = :set, min = 0.0, max = 10.0),
               LeafTarget(:b, (1,); type = :set, min = -5.0, max = 5.0)]
    spec = ScenarioSpec(name = "lhs", method = :lhs, n_variants = 16, seed = 123, targets = targets)
    s = sample_scenario_space(spec)
    @test size(s) == (16, 2)
    # All within bounds.
    @test all(s[:, 1] .>= 0.0)
    @test all(s[:, 1] .<= 10.0)
    @test all(s[:, 2] .>= -5.0)
    @test all(s[:, 2] .<= 5.0)
    # Deterministic w.r.t. seed.
    s2 = sample_scenario_space(spec)
    @test s == s2
end

@testset "sample_scenario_space — Sobol" begin
    targets = [LeafTarget(:a, (1,); type = :set, min = 0.0, max = 1.0),
               LeafTarget(:b, (1,); type = :set, min = 0.0, max = 1.0)]
    spec = ScenarioSpec(name = "sobol", method = :sobol, n_variants = 8, seed = 0, targets = targets)
    s = sample_scenario_space(spec)
    @test size(s) == (8, 2)
    @test all(0.0 .<= s .<= 1.0)
    # Sobol skips the origin → no all-zero row.
    @test !any(all(s[i, :] .== 0.0) for i in 1:8)
end

@testset "sample_scenario_space — Factorial" begin
    targets = [LeafTarget(:a, (1,); type = :set, min = 0.0, max = 1.0, step = 0.5),
               LeafTarget(:b, (1,); type = :set, min = 0.0, max = 2.0, step = 1.0)]
    spec = ScenarioSpec(name = "fact", method = :factorial, n_variants = 1, seed = 0, targets = targets)
    s = sample_scenario_space(spec)
    # 3 levels for a (0, 0.5, 1.0) × 3 levels for b (0, 1, 2) = 9 rows.
    @test size(s) == (9, 2)
    @test sort(unique(s[:, 1])) == [0.0, 0.5, 1.0]
    @test sort(unique(s[:, 2])) == [0.0, 1.0, 2.0]
end

@testset "sample_scenario_space — Morris" begin
    targets = [LeafTarget(:a, (1,); type = :set, min = 0.0, max = 1.0),
               LeafTarget(:b, (1,); type = :set, min = 0.0, max = 1.0)]
    spec = ScenarioSpec(name = "morris", method = :morris, n_variants = 6, seed = 1, targets = targets)
    s = sample_scenario_space(spec)
    @test size(s) == (6, 2)
    @test all(0.0 .<= s .<= 1.0)
end

@testset "samples_to_changes" begin
    targets = [LeafTarget(:emissionTargetBunker, (:NL, 2050); type = :set, min = 0.0, max = 10.0),
               LeafTarget(:co2price, (:NL,); type = :multiply, min = 0.5, max = 2.0)]
    spec = ScenarioSpec(name = "x", method = :lhs, n_variants = 3, seed = 0, targets = targets)
    samples = [1.0  0.7;
               5.0  1.0;
               9.0  1.5]
    changes = samples_to_changes(spec, samples)
    @test length(changes) == 3
    @test length(changes[1]) == 2
    @test changes[1][1].field   == :emissionTargetBunker
    @test changes[1][1].indices == (:NL, 2050)
    @test changes[1][1].value   == 1.0
    @test changes[1][1].type    == :set
    @test changes[2][2].field   == :co2price
    @test changes[2][2].indices == (:NL,)
    @test changes[2][2].value   == 1.0
    @test changes[2][2].type    == :multiply
    @test changes[3][1].value   == 9.0

    # Dim mismatch.
    @test_throws DimensionMismatch samples_to_changes(spec, [1.0; 2.0;;])
end

@testset "Spec ↔ Dict round-trip (with Symbol indices)" begin
    targets = [LeafTarget(:emissionTargetBunker, (:NL, 2050); type = :multiply, min = 0.5, max = 1.5),
               LeafTarget(:co2price, (:DE, 2030, :baseline); type = :set, min = 50.0, max = 200.0, step = 25.0, label = "co2_de_2030")]
    spec = ScenarioSpec(name = "roundtrip", method = :sobol, n_variants = 16, seed = 7, targets = targets)
    d = _spec_to_dict(spec)
    spec2 = _dict_to_spec(d)
    @test spec2.name       == spec.name
    @test spec2.method     == spec.method
    @test spec2.n_variants == spec.n_variants
    @test spec2.seed       == spec.seed
    @test length(spec2.targets) == 2
    @test spec2.targets[1].field   == :emissionTargetBunker
    @test spec2.targets[1].indices == (:NL, 2050)
    @test spec2.targets[1].type    == :multiply
    @test spec2.targets[1].min     == 0.5
    @test spec2.targets[2].field   == :co2price
    @test spec2.targets[2].indices == (:DE, 2030, :baseline)
    @test spec2.targets[2].step    == 25.0
    @test spec2.targets[2].label   == "co2_de_2030"
end

@testset "Indices ↔ string round-trip (DuckDB encoding)" begin
    @test _str_to_indices(_indices_to_str((:NL, 2050))) == (:NL, 2050)
    @test _str_to_indices(_indices_to_str((:DE,)))      == (:DE,)
    @test _str_to_indices(_indices_to_str(()))          == ()
end

@testset "save_scenario_results / load_scenario_results — DuckDB" begin
    targets = [LeafTarget(:emissionTargetBunker, (:NL, 2050); type = :multiply, min = 0.5, max = 1.5, label = "bunker"),
               LeafTarget(:co2price, (:NL,); type = :set, min = 50.0, max = 200.0, label = "co2_NL")]
    spec = ScenarioSpec(name = "persist_duckdb", method = :sobol, n_variants = 2, seed = 0, targets = targets)
    samples = [0.6  100.0;
               1.2  150.0]
    variants = [
        VariantResult(variant_id = 1, objective = 95.0, term_status = "OPTIMAL", primal_status = "FEASIBLE_POINT",
                      worker_pid = 1, build_seconds = 3.0, apply_seconds = 0.2, solve_seconds = 2.0),
        VariantResult(variant_id = 2, objective = 70.0, term_status = "OPTIMAL", primal_status = "FEASIBLE_POINT",
                      worker_pid = 2, build_seconds = 3.1, apply_seconds = 0.2, solve_seconds = 1.5),
    ]
    result = ScenarioResult(spec, samples, variants, 8.7)

    dir = mktempdir()
    try
        save_scenario_results(dir, result)
        @test isfile(joinpath(dir, "scenario_results.duckdb"))

        # Refuses to overwrite without flag.
        @test_throws ArgumentError save_scenario_results(dir, result)
        save_scenario_results(dir, result; overwrite = true)

        r2 = load_scenario_results(dir)
        @test r2.spec.name == "persist_duckdb"
        @test r2.spec.method == :sobol
        @test length(r2.spec.targets) == 2
        @test r2.spec.targets[1].indices == (:NL, 2050)
        @test r2.spec.targets[2].indices == (:NL,)
        @test r2.spec.targets[2].label   == "co2_NL"
        @test r2.samples == samples
        @test length(r2.variants) == 2
        @test r2.variants[2].objective  == 70.0
        @test r2.variants[2].worker_pid == 2
        @test r2.runtime_seconds == 8.7
    finally
        rm(dir; recursive = true, force = true)
    end
end

@testset "Unknown format rejected" begin
    spec = ScenarioSpec(name = "x", method = :lhs, n_variants = 1, seed = 0,
                        targets = [LeafTarget(:a, (1,); type = :set, min = 0.0, max = 1.0)])
    result = ScenarioResult(spec, reshape([0.5], 1, 1),
                            [VariantResult(variant_id = 1)], 1.0)
    dir = mktempdir()
    try
        @test_throws ArgumentError save_scenario_results(dir, result; format = :csv)
        @test_throws ArgumentError load_scenario_results(dir; format = :csv)
        @test_throws ArgumentError save_scenario_results(dir, result; format = :parquet)
        @test_throws ArgumentError load_scenario_results(dir; format = :parquet)
    finally
        rm(dir; recursive = true, force = true)
    end
end
