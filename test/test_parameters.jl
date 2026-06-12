using Test
using IESA_J

const XLSX_PATH = joinpath(@__DIR__, "..", "data", "default_data.xlsx")

@testset "Phase 1: compute_derived_params!" begin
    if !isfile(XLSX_PATH)
        @info "Skipping Phase 1 param tests: XLSX not found" path=XLSX_PATH
        return
    end

    md = read_data(XLSX_PATH)

    @testset "Temporal helpers cover full year" begin
        @test length(md.params.dayPer_hour) == 8760
        @test md.params.dayPer_hour[1] == 1
        @test md.params.dayPer_hour[24] == 1
        @test md.params.dayPer_hour[25] == 2
        @test md.params.dayPer_hour[8760] == 365
        @test md.params.prev_hour[1] == 8760
        @test md.params.next_hour[8760] == 1
    end

    @testset "CRF entries populated for technologies" begin
        @test !isempty(md.params.CRF)
        @test length(md.params.CRF) == length(md.sets.technologies)
        for v in values(md.params.CRF)
            @test isfinite(v)
            @test v >= 0.0
        end
    end

    @testset "InvMat_lifeTime is 0/1-valued" begin
        @test !isempty(md.params.InvMat_lifeTime)
        for v in values(md.params.InvMat_lifeTime)
            @test v == 0.0 || v == 1.0
        end
    end

    @testset "social_discount_factor covers all periods_solve" begin
        for ps in md.sets.periods_solve
            @test haskey(md.params.social_discount_factor, ps)
            @test md.params.social_discount_factor[ps] > 0.0
        end
    end

    @testset "period_weight / period_span sane (IESA-Opt 1.0-style)" begin
        # period_span is now per IESA-Opt 1.0: (val(pss)-val(prev))/5  -- in 5-year units
        @test all(>(0), values(md.params.period_span))
        # period_weight is fractions summing to 1.0 (stair formulation)
        @test all(v -> v > 0 && v <= 1, values(md.params.period_weight))
        @test isapprox(sum(values(md.params.period_weight)), 1.0; atol=1e-9)
        # transition_interval is scalar (stored at key 0): val(last) - val(first) + 10
        @test haskey(md.params.transition_interval, 0)
        first_ps = first(md.sets.periods)
        last_ps  = last(md.sets.periods)
        @test md.params.transition_interval[0] == Float64(last_ps - first_ps + 10)
    end
end

