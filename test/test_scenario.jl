using Test
using IESAOpt
using Random
using Statistics

@testset "scenario/spec.jl" begin
    @testset "parse_sampling_method" begin
        @test parse_sampling_method("LHS")              == :lhs
        @test parse_sampling_method("Latin hypercube")  == :lhs
        @test parse_sampling_method("Morris")           == :morris
        @test parse_sampling_method("Sobol")            == :sobol
        @test parse_sampling_method("Factorial")        == :factorial
        @test parse_sampling_method(:lhs)               == :lhs
        @test_throws ArgumentError parse_sampling_method("nope")
    end

    @testset "parse_param_type" begin
        @test parse_param_type("set")      == :set
        @test parse_param_type("multiply") == :multiply
        @test parse_param_type(:multiply)  == :multiply
        @test_throws ArgumentError parse_param_type("xyz")
    end

    @testset "ParameterRow construction + helpers" begin
        rows = [
            ParameterRow(parameter = "P1", sheet = "S", cell = "A1",
                         type = :set, min = 0.0, max = 10.0),
            ParameterRow(parameter = "P2", sheet = "S", cell = "A2",
                         type = :multiply, min = 0.5, max = 2.0),
            ParameterRow(parameter = "P2", subparameter = "alt", sheet = "S",
                         cell = "A3", type = :multiply),    # Min/Max omitted -> inherit
        ]
        spec = CampaignSpec(name = "t", method = :lhs, n_variants = 4,
                            seed = 7, rows = rows)
        @test unique_parameters(spec) == ["P1", "P2"]
        @test parameter_bounds(spec) == [(0.0, 10.0), (0.5, 2.0)]
        @test parameter_steps(spec) == Union{Float64,Nothing}[nothing, nothing]
    end

    @testset "validate_spec catches errors" begin
        # Missing bounds entirely on one parameter
        spec_bad = CampaignSpec(name = "t", method = :lhs, n_variants = 4, seed = 7,
            rows = [ParameterRow(parameter = "P1", sheet = "S", cell = "A1",
                                 type = :set)])
        v = validate_spec(spec_bad)
        @test !v.valid
        @test any(occursin("Min", e) || occursin("Max", e) for e in v.errors)

        # Min > Max
        spec_swap = CampaignSpec(name = "t", method = :lhs, n_variants = 4, seed = 7,
            rows = [ParameterRow(parameter = "P1", sheet = "S", cell = "A1",
                                 type = :set, min = 10.0, max = 5.0)])
        v2 = validate_spec(spec_swap)
        @test !v2.valid
        @test any(occursin("exceeds Max", e) for e in v2.errors)

        # Empty name + n_variants 0
        @test_throws ArgumentError CampaignSpec(name = "", method = :lhs,
                                                n_variants = 0, seed = 0,
                                                rows = ParameterRow[])

        # Factorial without Step
        spec_fact = CampaignSpec(name = "t", method = :factorial, n_variants = 1,
            seed = 0, rows = [ParameterRow(parameter = "P", sheet = "S", cell = "A1",
                                           type = :set, min = 0.0, max = 10.0)])
        v3 = validate_spec(spec_fact)
        @test !v3.valid
        @test any(occursin("Step", e) for e in v3.errors)
    end

    @testset "spec_from_dict / spec_to_dict round-trip" begin
        spec = CampaignSpec(name = "rt", method = :sobol, n_variants = 16, seed = 12,
            rows = [ParameterRow(parameter = "P", sheet = "S", cell = "A1",
                                 type = :set, min = 0.0, max = 1.0,
                                 notes = "hello")])
        d = spec_to_dict(spec)
        spec2 = spec_from_dict(d)
        @test spec2.name == spec.name
        @test spec2.method == spec.method
        @test spec2.n_variants == spec.n_variants
        @test spec2.seed == spec.seed
        @test length(spec2.rows) == 1
        @test spec2.rows[1].parameter == "P"
        @test spec2.rows[1].notes == "hello"
        @test spec2.rows[1].min == 0.0
        @test spec2.rows[1].max == 1.0
    end

    @testset "UI validation resolves workbook coordinates" begin
        direct_body = Dict(
            "name" => "ui_valid",
            "method" => "lhs",
            "n_variants" => 2,
            "seed" => 1,
            "rows" => [Dict(
                "parameter" => "Bunker emission cap",
                "subparameter" => "NL 2050",
                "sheet" => "emissionTargetBunker",
                "cell" => "(NL, 2050)",
                "type" => "multiply",
                "min" => 0.5,
                "max" => 1.5,
            )],
        )
        direct = IESAOpt._scenario_validate(direct_body)
        @test direct["valid"] == true

        workbook_body = deepcopy(direct_body)
        workbook_body["inputWorkbook"] = "data/default_data.xlsx"
        workbook_body["rows"][1]["sheet"] = "NodeParameters"
        workbook_body["rows"][1]["cell"] = "AE5"
        workbook = IESAOpt._scenario_validate(workbook_body)
        @test workbook["valid"] == true
        @test any(occursin("NodeParameters!AE5 -> ModelParams.emissionTargetBunker", w) for w in workbook["warnings"])
        @test any(occursin("emTargetBunker[NL,2050]", w) for w in workbook["warnings"])

        feedstock_body = deepcopy(workbook_body)
        feedstock_body["rows"][1]["parameter"] = "Feedstock emission cap"
        feedstock_body["rows"][1]["sheet"] = "NodeParameters"
        feedstock_body["rows"][1]["cell"] = "AL5"
        feedstock = IESAOpt._scenario_validate(feedstock_body)
        @test feedstock["valid"] == true
        @test any(occursin("NodeParameters!AL5 -> ModelParams.emissionTargetFS", w) for w in feedstock["warnings"])

        unsupported = deepcopy(direct_body)
        unsupported["inputWorkbook"] = "data/default_data.xlsx"
        unsupported["rows"][1]["sheet"] = "Technologies"
        unsupported["rows"][1]["cell"] = "AA10"
        invalid = IESAOpt._scenario_validate(unsupported)
        @test invalid["valid"] == false
        @test any(occursin("resolved to ModelParams.vom_cost", e) for e in invalid["errors"])
        @test any(occursin("no live scenario mutation builder", e) for e in invalid["errors"])

        unknown_sheet = deepcopy(direct_body)
        unknown_sheet["rows"][1]["sheet"] = "UnknownSheet"
        unknown_sheet["rows"][1]["cell"] = "AE5"
        invalid_sheet = IESAOpt._scenario_validate(unknown_sheet)
        @test invalid_sheet["valid"] == false
        @test any(occursin("Workbook has no sheet named", e) for e in invalid_sheet["errors"])

        bad_indices = deepcopy(direct_body)
        bad_indices["rows"][1]["cell"] = "AA10"
        invalid_indices = IESAOpt._scenario_validate(bad_indices)
        @test invalid_indices["valid"] == false
        @test any(occursin("expects (node, period)", e) for e in invalid_indices["errors"])
    end

    @testset "Campaign phases reset later cards on worker startup" begin
        spec = CampaignSpec(name = "phase_reset", method = :lhs, n_variants = 2, seed = 1,
            rows = [ParameterRow(parameter = "Bunker emission cap", sheet = "emissionTargetBunker",
                                 cell = "(NL, 2050)", type = :multiply, min = 0.5, max = 1.5)])
        snap = IESAOpt._campaign_session_skeleton("phase_reset", spec, 2, 1, :highs, :ts)
        IESAOpt._campaign_set_phase!(snap, "generate", "done"; detail = "2 variants generated")

        IESAOpt._campaign_set_phase!(snap, "workers", "active"; detail = "Starting 2 workers", advance = false)
        IESAOpt._campaign_reset_after_phase!(snap, "workers")

        phases = Dict(String(p["id"]) => p for p in snap["phases"])
        @test phases["workers"]["status"] == "active"
        @test phases["generate"]["status"] == "pending"
        @test phases["generate"]["detail"] == ""
    end

    @testset "Campaign worker cards prefer actual worker pid" begin
        spec = CampaignSpec(name = "worker_pid", method = :lhs, n_variants = 3, seed = 1,
            rows = [ParameterRow(parameter = "Bunker emission cap", sheet = "emissionTargetBunker",
                                 cell = "(NL, 2050)", type = :multiply, min = 0.5, max = 1.5)])
        snap = IESAOpt._campaign_session_skeleton("worker_pid", spec, 3, 1, :highs, :ts)
        snap["workers"][1]["pid"] = 101
        snap["workers"][2]["pid"] = 202
        snap["workers"][3]["pid"] = 303

        @test IESAOpt._campaign_worker_slot(snap["workers"], 202, 1) == 2
        @test IESAOpt._campaign_worker_slot(snap["workers"], 999, 3) == 3
    end

    @testset "Campaign worker cards show planned task totals" begin
        spec = CampaignSpec(name = "worker_totals", method = :lhs, n_variants = 10, seed = 1,
            rows = [ParameterRow(parameter = "Bunker emission cap", sheet = "emissionTargetBunker",
                                 cell = "(NL, 2050)", type = :multiply, min = 0.5, max = 1.5)])
        snap = IESAOpt._campaign_session_skeleton("worker_totals", spec, 3, 1, :highs, :ts)
        IESAOpt._campaign_set_worker_task_totals!(snap, 10, 3)

        @test [w["assigned"] for w in snap["workers"]] == [4, 3, 3]
        @test [w["started"] for w in snap["workers"]] == [0, 0, 0]
    end
end

@testset "scenario/sampling.jl" begin
    base_rows = [
        ParameterRow(parameter = "P1", sheet = "S", cell = "A1",
                     type = :set, min = 0.0, max = 10.0),
        ParameterRow(parameter = "P2", sheet = "S", cell = "A2",
                     type = :multiply, min = 0.5, max = 2.0),
    ]

    @testset "LHS shape, bounds, reproducibility" begin
        spec = CampaignSpec(name = "lhs", method = :lhs, n_variants = 32,
                            seed = 42, rows = base_rows)
        s1 = sample_campaign(spec)
        s2 = sample_campaign(spec)
        @test size(s1.values) == (32, 2)
        @test s1.parameters == ["P1", "P2"]
        # Bounds
        @test all(0.0 .<= s1.values[:, 1] .<= 10.0)
        @test all(0.5 .<= s1.values[:, 2] .<= 2.0)
        # Reproducibility via seed
        @test s1.values == s2.values
        # Different seed -> different draws
        spec3 = CampaignSpec(name = "lhs", method = :lhs, n_variants = 32,
                             seed = 43, rows = base_rows)
        s3 = sample_campaign(spec3)
        @test s1.values != s3.values
    end

    @testset "LHS Latin property: each column has one point per stratum" begin
        n = 100
        spec = CampaignSpec(name = "lhs", method = :lhs, n_variants = n,
                            seed = 1, rows = base_rows)
        s = sample_campaign(spec)
        for j in 1:2
            lo, hi = (j == 1 ? (0.0, 10.0) : (0.5, 2.0))
            t = (s.values[:, j] .- lo) ./ (hi - lo)
            strata = Int.(floor.(t .* n)) .+ 1
            strata = clamp.(strata, 1, n)
            @test length(unique(strata)) == n
        end
    end

    @testset "Sobol shape and bounds" begin
        spec = CampaignSpec(name = "sob", method = :sobol, n_variants = 32,
                            seed = 0, rows = base_rows)
        s = sample_campaign(spec)
        @test size(s.values) == (32, 2)
        @test all(0.0 .<= s.values[:, 1] .<= 10.0)
        @test all(0.5 .<= s.values[:, 2] .<= 2.0)
        # Sobol skips the origin -> first row is not (lo, lo)
        @test !(s.values[1, 1] == 0.0 && s.values[1, 2] == 0.5)
    end

    @testset "Morris row count = r * (k+1)" begin
        for r in (1, 3, 10)
            spec = CampaignSpec(name = "m", method = :morris, n_variants = r,
                                seed = 9, rows = base_rows)
            s = sample_campaign(spec)
            @test size(s.values) == (r * 3, 2)
            @test implied_sample_size(spec) == r * 3
            @test all(0.0 .<= s.values[:, 1] .<= 10.0)
            @test all(0.5 .<= s.values[:, 2] .<= 2.0)
        end
    end

    @testset "Factorial cartesian product" begin
        spec = CampaignSpec(name = "f", method = :factorial, n_variants = 1,
            seed = 0, rows = [ParameterRow(parameter = "Q", sheet = "S",
                                           cell = "A1", type = :set,
                                           min = 0.0, max = 6.0, step = 2.0)])
        s = sample_campaign(spec)
        @test size(s.values) == (4, 1)
        @test sort(vec(s.values)) == [0.0, 2.0, 4.0, 6.0]
    end

    @testset "implied_sample_size" begin
        @test implied_sample_size(CampaignSpec(name = "x", method = :lhs,
            n_variants = 25, seed = 0, rows = base_rows)) == 25
        @test implied_sample_size(CampaignSpec(name = "x", method = :sobol,
            n_variants = 64, seed = 0, rows = base_rows)) == 64
        @test implied_sample_size(CampaignSpec(name = "x", method = :morris,
            n_variants = 5, seed = 0, rows = base_rows)) == 5 * 3
    end
end
