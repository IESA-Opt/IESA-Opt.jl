using Test
using IESAOpt

@testset "IESA-Opt.jl Phase 0 smoke tests" begin
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

@testset "Scenario-space exploration (Phase 1)" begin
    include("test_scenario.jl")
end

@testset "Scenario-space exploration (Phase 2: in-place mutation)" begin
    include("test_scenario_mutation.jl")
end

@testset "Scenario-space exploration (Phase 3: campaign runner)" begin
    include("test_scenario_runner.jl")
end

@testset "Scenario-space exploration (Phase 4: orchestrator + persistence)" begin
    include("test_scenario_orchestrator.jl")
end

@testset "Scenario-space exploration (Phase 5: analysis helpers)" begin
    include("test_scenario_analysis.jl")
end

