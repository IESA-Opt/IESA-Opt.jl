using Test
using IESA_J
using CSV
using DataFrames
using JuMP

const XLSX_PATH = joinpath(@__DIR__, "..", "data", "default_data.xlsx")

@testset "Phase 1: data_writing dumpers" begin
    if !isfile(XLSX_PATH)
        @info "Skipping Phase 1 writing tests: XLSX not found" path=XLSX_PATH
        return
    end

    md = read_data(XLSX_PATH)
    out_dir = mktempdir()

    @testset "write_sets_dump produces non-empty CSV" begin
        path = write_sets_dump(md, out_dir)
        @test isfile(path)
        @test filesize(path) > 100
        df = CSV.read(path, DataFrame)
        @test names(df) == ["set_name", "member"]
        @test nrow(df) > 1000
        @test "technologies" in unique(df.set_name)
    end

    @testset "write_params_dump produces scalar + indexed CSVs" begin
        scalar_path, indexed_path = write_params_dump(md, out_dir)
        @test isfile(scalar_path)
        @test isfile(indexed_path)

        df_s = CSV.read(scalar_path, DataFrame)
        @test names(df_s) == ["param_name", "value"]
        @test "base_year" in df_s.param_name

        df_i = CSV.read(indexed_path, DataFrame)
        @test names(df_i) == ["param_name", "key", "value"]
        @test nrow(df_i) > 10_000
        @test "CRF" in unique(df_i.param_name)
        @test "dayPer_hour" in unique(df_i.param_name)
    end
end

@testset "Phase 1: Gurobi/HiGHS optimizer factories" begin
    @testset "highs_optimizer builds + solves trivial LP" begin
        m = Model(highs_optimizer())
        set_silent(m)
        @variable(m, x >= 0)
        @objective(m, Min, x)
        @constraint(m, x >= 1)
        optimize!(m)
        @test termination_status(m) == MOI.OPTIMAL
        @test isapprox(objective_value(m), 1.0; atol=1e-8)
    end

    @testset "gurobi_optimizer builds + solves trivial LP (if Gurobi available)" begin
        try
            m = Model(gurobi_optimizer())
            set_silent(m)
            @variable(m, x >= 0)
            @objective(m, Min, x)
            @constraint(m, x >= 1)
            optimize!(m)
            @test termination_status(m) == MOI.OPTIMAL
            @test isapprox(objective_value(m), 1.0; atol=1e-8)
        catch err
            @info "Gurobi not available, skipping Gurobi test" err=err
            @test_broken false
        end
    end
end
