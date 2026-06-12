using Test
using IESA_J

@testset "IESA_J Phase 0 smoke tests" begin
    include("test_smoke.jl")
end

@testset "Phase 1: data reading" begin
    include("test_data_reading.jl")
    include("test_sets.jl")
    include("test_parameters.jl")
end

@testset "Phase 1: data writing + solver factories" begin
    include("test_data_writing.jl")
end

