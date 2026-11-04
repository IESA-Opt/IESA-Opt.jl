using JuMP
using HiGHS
using XLSX

# Synthetic regional data mirroring the 10Nodes workbook conventions:
# `CLn_` tech prefixes, Technologies!DS "Space (Ha)" and Parameters
# `CLn_AvailableArea` rows (AIMMS `c_ClusterSpace_Limit`).
function _land_use_test_data(; periods = [2040, 2050])
    techs = Symbol.([
        "CL1_IBM01_01",      # cluster 1, space 116.5
        "CL1_ICH01_01",      # cluster 1, space 120.5
        "CL1_NOSPACE01_01",  # cluster 1, zero space -> not in the constraint
        "CL2_IBM01_01",      # cluster 2, space 116.5
        "CL3_IFE01_01",      # cluster 3 has zero available area -> skipped
        "CL6_IBM01_01",      # no available area defined for CL6
        "PNL01_01",          # national tech without cluster prefix
    ])
    md = ModelData()
    md.sets.technologies = copy(techs)
    md.sets.tech_balancers = copy(techs)
    md.sets.periods_solve = copy(periods)
    md.params.techSpace = Dict(
        :CL1_IBM01_01 => 116.5, :CL1_ICH01_01 => 120.5, :CL1_NOSPACE01_01 => 0.0,
        :CL2_IBM01_01 => 116.5, :CL3_IFE01_01 => 35.0, :CL6_IBM01_01 => 10.0, :PNL01_01 => 5.0,
    )
    md.params.clusterAvailableArea = Dict(:CL1 => 1450.0, :CL2 => 850.9, :CL3 => 0.0)
    return md
end

@testset "Land use: one 2050 limit per cluster with an available area" begin
    md = _land_use_test_data()
    md.params.extensions = Set([:land_use])
    model = Model()
    vars = add_annual_variables!(model, md)
    n_added = IESAOpt.apply_land_use!(model, vars, md; mode = :annual)

    @test n_added == 2
    cl1 = constraint_by_name(model, "c_ClusterSpace_Limit[CL1,2050]")
    cl2 = constraint_by_name(model, "c_ClusterSpace_Limit[CL2,2050]")
    @test cl1 !== nothing
    @test cl2 !== nothing
    @test normalized_rhs(cl1) == 1450.0
    @test normalized_rhs(cl2) == 850.9
    @test normalized_coefficient(cl1, vars.techStock[:CL1_IBM01_01, 2050]) == 116.5
    @test normalized_coefficient(cl1, vars.techStock[:CL1_ICH01_01, 2050]) == 120.5
    @test normalized_coefficient(cl1, vars.techStock[:CL1_NOSPACE01_01, 2050]) == 0.0
    @test normalized_coefficient(cl1, vars.techStock[:CL2_IBM01_01, 2050]) == 0.0
    @test normalized_coefficient(cl1, vars.techStock[:PNL01_01, 2050]) == 0.0
    @test normalized_coefficient(cl1, vars.techStock[:CL1_IBM01_01, 2040]) == 0.0
    @test normalized_coefficient(cl2, vars.techStock[:CL2_IBM01_01, 2050]) == 116.5
    @test constraint_by_name(model, "c_ClusterSpace_Limit[CL3,2050]") === nothing
    @test constraint_by_name(model, "c_ClusterSpace_Limit[CL6,2050]") === nothing
    @test constraint_by_name(model, "c_ClusterSpace_Limit[CL1,2040]") === nothing
end

@testset "Land use: extension dispatcher gating" begin
    md = _land_use_test_data()
    model = Model()
    vars = add_annual_variables!(model, md)
    @test IESAOpt.apply_extensions!(model, vars, md; mode = :annual) == 0
    @test constraint_by_name(model, "c_ClusterSpace_Limit[CL1,2050]") === nothing

    md.params.extensions = Set([:land_use])
    @test IESAOpt.apply_extensions!(model, vars, md; mode = :annual) == 2
    @test constraint_by_name(model, "c_ClusterSpace_Limit[CL1,2050]") !== nothing
end

@testset "Land use: no constraint without land data or without 2050" begin
    md = _land_use_test_data()
    empty!(md.params.clusterAvailableArea)
    model = Model()
    vars = add_annual_variables!(model, md)
    @test IESAOpt.apply_land_use!(model, vars, md) == 0
    @test occursin("no land-use data", IESAOpt.land_use_plan(md))

    md = _land_use_test_data(; periods = [2040])
    model = Model()
    vars = add_annual_variables!(model, md)
    @test IESAOpt.apply_land_use!(model, vars, md) == 0
    @test occursin("2050 is not selected", IESAOpt.land_use_plan(md))

    md = _land_use_test_data()
    @test occursin("adding 2 constraint(s) for 2050", IESAOpt.land_use_plan(md))
end

@testset "Land use: limit binds and moves the optimum" begin
    techs = [:CL1_CHEAP01_01, :CL1_COMPACT01_01]
    md = ModelData()
    md.sets.technologies = copy(techs)
    md.sets.tech_balancers = copy(techs)
    md.sets.periods_solve = [2050]
    md.params.techSpace = Dict(:CL1_CHEAP01_01 => 2.0, :CL1_COMPACT01_01 => 1.0)
    md.params.clusterAvailableArea = Dict(:CL1 => 15.0)

    function solve_toy(with_limit::Bool)
        model = Model(HiGHS.Optimizer)
        set_silent(model)
        vars = add_annual_variables!(model, md)
        cheap, compact = vars.techStock[techs[1], 2050], vars.techStock[techs[2], 2050]
        @constraint(model, cheap + compact >= 10)
        @objective(model, Min, 1.0 * cheap + 3.0 * compact)
        with_limit && IESAOpt.apply_land_use!(model, vars, md)
        optimize!(model)
        @test termination_status(model) == MOI.OPTIMAL
        return model, vars
    end
    stock(vars, t) = value(vars.techStock[t, 2050])

    model, vars = solve_toy(false)
    @test stock(vars, techs[1]) ≈ 10.0 atol = 1e-6
    @test stock(vars, techs[2]) ≈ 0.0 atol = 1e-6
    @test only(IESAOpt.land_use_report(vars, md)).used ≈ 20.0 atol = 1e-6

    md.params.extensions = Set([:land_use])
    model, vars = solve_toy(true)
    @test stock(vars, techs[1]) ≈ 5.0 atol = 1e-6
    @test stock(vars, techs[2]) ≈ 5.0 atol = 1e-6
    row = only(IESAOpt.land_use_report(vars, md))
    @test (row.cluster, row.period, row.available) == (:CL1, 2050, 15.0)
    @test row.used ≈ 15.0 atol = 1e-6

    # Post-solve summary shown in the UI run log.
    job_id = "land_use_report_test"
    IESAOpt.UI_JOBS[job_id] = Dict{String,Any}("status" => "running", "stage" => "solve",
                                               "logs" => Vector{Dict{String,String}}())
    try
        IESAOpt._report_land_use!(job_id, model, vars, md)
        message = only(IESAOpt.UI_JOBS[job_id]["logs"])["message"]
        @test occursin("limit ON", message)
        @test occursin("CL1 2050: 15.0 of 15.0 ha (100.0%)", message)
    finally
        delete!(IESAOpt.UI_JOBS, job_id)
    end
end

@testset "Land use: workbook readers" begin
    path = joinpath(mktempdir(), "land_use.xlsx")
    XLSX.openxlsx(path, mode = "w") do xf
        params = xf[1]
        XLSX.rename!(params, "Parameters")
        params["A48"] = "Solar CP";          params["B48"] = 0.1643
        params["A49"] = "CL1_AvailableArea"; params["B49"] = 1450
        params["A50"] = "CL2_AvailableArea"; params["B50"] = 850.9
        params["A51"] = "cl3_availablearea"; params["B51"] = 238.1
        params["A52"] = "CL4_AvailableArea"
        techs = XLSX.addsheet!(xf, "Technologies")
        techs["A7"] = "CL1_IBM01_01"; techs["DS7"] = 116.5
        techs["A8"] = "CL3_IFE01_01"; techs["DS8"] = 35
        techs["A9"] = "PNL01_01"
    end

    s, p = ModelSets(), ModelParams()
    XLSX.openxlsx(path, mode = "r") do xf
        IESAOpt._read_parameters_sheet!(s, p, xf)
        IESAOpt._read_technologies_sheet!(s, p, xf)
    end
    @test p.clusterAvailableArea == Dict(:CL1 => 1450.0, :CL2 => 850.9, :CL3 => 238.1)
    @test p.techSpace == Dict(:CL1_IBM01_01 => 116.5, :CL3_IFE01_01 => 35.0)
end

@testset "Land use: UI run config toggle" begin
    @test IESAOpt._normalize_run_config(Dict{String,Any}())["landUse"] === false
    @test IESAOpt._normalize_run_config(Dict{String,Any}("landUse" => true))["landUse"] === true
end
