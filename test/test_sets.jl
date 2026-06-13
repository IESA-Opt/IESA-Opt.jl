using Test
using IESAOpt

const XLSX_PATH = joinpath(@__DIR__, "..", "data", "default_data.xlsx")

@testset "Phase 1: derive_sets! produces consistent subsets" begin
    if !isfile(XLSX_PATH)
        @info "Skipping Phase 1 set tests: XLSX not found" path=XLSX_PATH
        return
    end

    md = read_data(XLSX_PATH)

    # technologies = tech_balancers ∪ tech_infra (Symbol union)
    @test length(md.sets.technologies) == length(md.sets.tech_balancers) + length(md.sets.tech_infra)
    @test issubset(Set(md.sets.tech_balancers), Set(md.sets.technologies))
    @test issubset(Set(md.sets.tech_infra),     Set(md.sets.technologies))

    # storage subsets nest correctly
    @test issubset(Set(md.sets.tech_fStorage), Set(md.sets.tech_flexible))

    # period subsets
    @test issubset(Set(md.sets.periods_solve), Set(md.sets.periods))
end

