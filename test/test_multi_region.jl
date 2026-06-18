using JuMP

@testset "MultiRegion aggregate use caps" begin
    techs = Symbol.(
        [
            "CL5_PEU01_03",
            "CL6_PEU01_03",
            "CL9_PEU01_03",
            "CL11_PEU01_03",
            "CL12_PEU01_03",
            "CL24_PEU01_03",
            "CL30_PEU01_03",
        ],
    )

    md = ModelData()
    md.sets.technologies = copy(techs)
    md.sets.tech_balancers = copy(techs)
    md.sets.periods_solve = [2050]
    md.params.extensions = Set([:multi_region])
    for t in techs
        md.params.techUse_max[(t, 2050)] = 87.0
    end

    model = Model()
    vars = add_annual_variables!(model, md)
    add_balance_constraints!(model, vars, md)
    n_added = IESAOpt.apply_multi_region!(model, vars, md; mode = :annual)

    aggregate = constraint_by_name(model, "mr_useCap_PEU01_03_2050")
    @test aggregate !== nothing
    @test n_added == 1
    @test normalized_rhs(aggregate) == 87.0
    for t in techs
        @test constraint_by_name(model, "maxUse[$(t),2050]") !== nothing
        @test normalized_coefficient(aggregate, vars.tech_use[t, 2050]) == 1.0
    end
end

@testset "MultiRegion discovers workbook use cap families" begin
    techs = Symbol.(
        [
            "CL1_DEMO01_01",
            "CL2_DEMO01_01",
            "CL3_DEMO01_01",
            "CL1_UNCAPPED01_01",
            "CL2_UNCAPPED01_01",
            "CL1_REGIONAL01_01",
            "CL2_REGIONAL01_01",
        ],
    )

    md = ModelData()
    md.sets.technologies = copy(techs)
    md.sets.tech_balancers = copy(techs)
    md.sets.periods_solve = [2050]
    md.params.extensions = Set([:multi_region])
    for t in techs[1:3]
        md.params.techUse_max[(t, 2050)] = 42.0
    end
    md.params.techUse_max[(:CL1_REGIONAL01_01, 2050)] = 10.0
    md.params.techUse_max[(:CL2_REGIONAL01_01, 2050)] = 12.0

    model = Model()
    vars = add_annual_variables!(model, md)
    add_balance_constraints!(model, vars, md)
    n_added = IESAOpt.apply_multi_region!(model, vars, md; mode = :annual)

    aggregate = constraint_by_name(model, "mr_useCap_DEMO01_01_2050")
    @test aggregate !== nothing
    @test constraint_by_name(model, "mr_useCap_UNCAPPED01_01_2050") === nothing
    @test constraint_by_name(model, "mr_useCap_REGIONAL01_01_2050") === nothing
    @test constraint_by_name(model, "mr_useCap_PEU01_03_2050") === nothing
    @test n_added == 1
    @test normalized_rhs(aggregate) == 42.0
    for t in techs[1:3]
        @test normalized_coefficient(aggregate, vars.tech_use[t, 2050]) == 1.0
    end
end

@testset "MultiRegion discovers exact repeated stock caps" begin
    techs = Symbol.(
        [
            "CL1_STOCK01_01",
            "CL2_STOCK01_01",
            "CL3_STOCK01_01",
            "CL1_LOCAL01_01",
            "CL2_LOCAL01_01",
        ],
    )

    md = ModelData()
    md.sets.technologies = copy(techs)
    md.sets.tech_balancers = Symbol[techs[1]]
    md.sets.periods_solve = [2050]
    md.params.extensions = Set([:multi_region])
    for t in techs[1:3]
        md.params.techStock_max[(t, 2050)] = 100.0
    end
    md.params.techStock_max[(:CL1_LOCAL01_01, 2050)] = 6.0
    md.params.techStock_max[(:CL2_LOCAL01_01, 2050)] = 9.0

    model = Model()
    vars = add_annual_variables!(model, md)
    n_added = IESAOpt.apply_multi_region!(model, vars, md; mode = :annual)

    aggregate = constraint_by_name(model, "mr_stockCap_STOCK01_01_2050")
    @test aggregate !== nothing
    @test constraint_by_name(model, "mr_stockCap_LOCAL01_01_2050") === nothing
    @test n_added == 1
    @test normalized_rhs(aggregate) == 100.0
    for t in techs[1:3]
        @test normalized_coefficient(aggregate, vars.techStock[t, 2050]) == 1.0
    end
end