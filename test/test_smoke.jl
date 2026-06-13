using Test
using IESAOpt

@testset "Module loads cleanly" begin
    @test isdefined(IESAOpt, :ModelSets)
    @test isdefined(IESAOpt, :ModelParams)
    @test isdefined(IESAOpt, :ModelData)
    @test isdefined(IESAOpt, :RunResult)
end

@testset "Empty ModelData constructs" begin
    md = IESAOpt.ModelData()
    @test isa(md.sets, IESAOpt.ModelSets)
    @test isa(md.params, IESAOpt.ModelParams)
    @test isempty(md.sets.technologies)
    @test md.params.n_repDays == 15
    @test md.params.base_year == 2022
end

@testset "Solver attribute presets" begin
    g = IESAOpt.default_gurobi_attributes()
    @test g["Method"]         == 2
    @test g["Crossover"]      == 0
    @test g["BarHomogeneous"] == 1
    @test g["Presolve"]       == -1
    @test g["ScaleFlag"]      == -1
    @test g["FeasibilityTol"] == 1e-7
    @test g["BarConvTol"]     == 1e-7

    h = IESAOpt.default_highs_attributes()
    @test h["solver"]              == "ipm"
    @test h["run_crossover"]       == "off"
    @test h["parallel"]            == "on"
end

@testset "Temporal helpers compute when hours_orig populated" begin
    md = IESAOpt.ModelData()
    md.sets.hours_orig = collect(1:8760)
    md.params.hoursPer_day = 24
    IESAOpt.compute_derived_params!(md)

    @test md.params.dayPer_hour[1]    == 1
    @test md.params.dayPer_hour[24]   == 1
    @test md.params.dayPer_hour[25]   == 2
    @test md.params.dayPer_hour[8760] == 365

    @test md.params.firstHourOfDay[1]   == 1
    @test md.params.lastHourOfDay[1]    == 24
    @test md.params.firstHourOfDay[365] == 8737
    @test md.params.lastHourOfDay[365]  == 8760

    # cyclic wrap
    @test md.params.prev_hour[1]    == 8760
    @test md.params.next_hour[8760] == 1
    @test md.params.prev_hour[100]  == 99
    @test md.params.next_hour[100]  == 101
end

@testset "derive_sets! populates default temporal sets" begin
    md = IESAOpt.ModelData()
    md.params.hoursPer_day = 24
    md.params.hoursPer_day_cluster = 24
    IESAOpt.derive_sets!(md)

    @test md.sets.hours_inDay == collect(1:24)
    @test md.sets.hours_inDay_cluster == collect(1:24)
    @test md.sets.days == collect(1:365)
    @test md.sets.weeks == collect(1:53)
    @test md.sets.months == collect(1:12)
    @test md.sets.seasons == collect(1:4)
    @test md.sets.semesters == collect(1:2)
end
