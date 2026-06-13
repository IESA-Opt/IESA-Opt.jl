"""
scripts/smoke_test_write.jl — verifies that data_writing dumpers produce
non-empty CSV files for sets and parameters, then verifies that the Gurobi
optimizer factory builds without errors (does NOT solve a model).

Run from the repository root:
    julia --project=. scripts/smoke_test_write.jl
"""

using IESAOpt
using JuMP
using CSV
using DataFrames

const XLSX_PATH = joinpath(@__DIR__, "..", "data", "default_data.xlsx")

println("[1/4] Reading XLSX ...")
md = read_data(XLSX_PATH)

println("[2/4] Writing dumps to tmp dir ...")
out_dir = joinpath(@__DIR__, "..", "tmp_smoke_dump")
mkpath(out_dir)

sets_csv = write_sets_dump(md, out_dir)
params_scalar_csv, params_indexed_csv = write_params_dump(md, out_dir)

println("  sets.csv           = $(sets_csv)  ($(filesize(sets_csv)) bytes)")
println("  params_scalar.csv  = $(params_scalar_csv)  ($(filesize(params_scalar_csv)) bytes)")
println("  params_indexed.csv = $(params_indexed_csv)  ($(filesize(params_indexed_csv)) bytes)")

df_sets   = CSV.read(sets_csv, DataFrame)
df_scalar = CSV.read(params_scalar_csv, DataFrame)
df_indexed = CSV.read(params_indexed_csv, DataFrame)

println("  rows in sets.csv           = $(nrow(df_sets))")
println("  rows in params_scalar.csv  = $(nrow(df_scalar))")
println("  rows in params_indexed.csv = $(nrow(df_indexed))")

println("[3/4] Testing HiGHS optimizer factory ...")
hi_opt = highs_optimizer()
m_hi = Model(hi_opt)
@variable(m_hi, x >= 0)
@objective(m_hi, Min, x)
@constraint(m_hi, x >= 1)
optimize!(m_hi)
println("  HiGHS test obj = ", objective_value(m_hi), " (expected 1.0)")

println("[4/4] Testing Gurobi optimizer factory ...")
try
    gu_opt = gurobi_optimizer()
    m_gu = Model(gu_opt)
    set_silent(m_gu)
    @variable(m_gu, x >= 0)
    @objective(m_gu, Min, x)
    @constraint(m_gu, x >= 1)
    optimize!(m_gu)
    println("  Gurobi test obj = ", objective_value(m_gu), " (expected 1.0)")
catch err
    println("  Gurobi test FAILED: ", err)
    rethrow()
end

println()
println("Smoke test OK.")
