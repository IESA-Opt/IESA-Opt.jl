using Test
using IESAOpt

const XLSX_PATH = joinpath(@__DIR__, "..", "Input", "default_data.xlsx")

@testset "Phase 1: read_data on default_data.xlsx" begin
    if !isfile(XLSX_PATH)
        @info "Skipping Phase 1 tests: XLSX not found" path=XLSX_PATH
        return
    end

    md = read_data(XLSX_PATH)

    @testset "Sets are populated to expected scale" begin
        @test length(md.sets.hours_orig) == 8760
        @test md.sets.periods == [2022, 2025, 2030, 2035, 2040, 2045, 2050]
        @test length(md.sets.periods_solve) >= 1
        @test length(md.sets.technologies) > 100
        @test length(md.sets.tech_balancers) > 100
        @test length(md.sets.tech_infra) > 0
        @test length(md.sets.activities) > 50
        @test length(md.sets.nodes) >= 1
        @test length(md.sets.profile_typeRead) > 0
    end

    @testset "Subsets are non-empty" begin
        @test length(md.sets.tech_hourlyDispatch) > 0
        @test length(md.sets.tech_hourlyCHPflex) > 0
        @test length(md.sets.tech_flexible) > 0
        @test length(md.sets.tech_fStorage) > 0
        @test length(md.sets.tech_gasBuffer) > 0
        @test length(md.sets.tech_emission) > 0
    end

    @testset "Indexed parameters have entries" begin
        @test !isempty(md.params.inv_cost)
        @test !isempty(md.params.fom_cost)
        @test !isempty(md.params.economic_lifetime)
        @test !isempty(md.params.hourly_profilesReadOrig)
        @test !isempty(md.params.activity_balancesRef)
    end

    @testset "Scalar parameters have sane values" begin
        @test md.params.hoursPer_day == 24
        @test md.params.base_year == 2022
    end
end

