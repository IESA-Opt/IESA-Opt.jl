"""
Default Gurobi / HiGHS attribute presets matching the current IESA-Opt 1.0
production settings (Phase 7: 2026-06-10).

Source: `MainProject/IESA-Opt.ams` Procedure `DefineSolverSettings`
hoursPer_day >= 12 branch (the TS sweep hot path).
"""

"""
    default_gurobi_attributes() -> Dict{String,Any}

Default Gurobi attributes for the production TS solve path. Mirrors the
IESA-Opt 1.0 Phase 7 settings: Barrier method, no crossover, BarHomogeneous=1
for Optimal certification, Gurobi auto-presolve, Gurobi auto-scaling,
all tolerances at 1e-7, all-cores threading.

Usage:
```julia
using Gurobi, JuMP
m = Model(Gurobi.Optimizer)
for (k, v) in IESAOpt.default_gurobi_attributes()
    set_optimizer_attribute(m, k, v)
end
```
"""
function default_gurobi_attributes(; threads::Int = 0)::Dict{String,Any}
    Dict{String,Any}(
        # Method selection (TS sweep hot path = Barrier)
        "Method"            => 2,        # 2 = Barrier
        "Crossover"         => 0,        # No crossover (we accept Barrier endpoint)
        "BarHomogeneous"    => 1,        # Required for Optimal on smaller WY1 LPs

        # Threading
        "Threads"           => threads,  # 0 = all cores

        # Presolve & scaling (Auto: let Gurobi pick)
        "Presolve"          => -1,
        "ScaleFlag"         => -1,

        # Numerics
        "NumericFocus"      => 0,        # Default (fastest)
        "FeasibilityTol"    => 1e-7,
        "OptimalityTol"     => 1e-7,
        "BarConvTol"        => 1e-7,

        # Output
        "OutputFlag"        => 1,
        "LogToConsole"      => 1,
    )
end

"""
    default_highs_attributes() -> Dict{String,Any}

Default HiGHS attributes for license-free CI / development. HiGHS interior
point uses different attribute names than Gurobi; this mapping picks the
closest equivalents. The IPM tolerances are the settings used for the IESA
LPs where HiGHS needs a looser crossover start tolerance than Gurobi.
"""
function default_highs_attributes(; threads::Int = 0)::Dict{String,Any}
    Dict{String,Any}(
        "solver"               => "ipm",            # interior point (HiGHS IPM ~= Barrier)
        "parallel"             => "on",
        "threads"              => threads,
        "presolve"             => "on",
        "primal_feasibility_tolerance"   => 1e-6,
        "dual_feasibility_tolerance"     => 1e-6,
        "ipm_optimality_tolerance"       => 1e-4,
        "start_crossover_tolerance"      => 1e-4,
        "output_flag"          => true,
        "log_to_console"       => true,
        "run_crossover"        => "off",            # skip crossover, accept IPM endpoint
    )
end

"""
    apply_solver_attributes!(model::JuMP.Model, attrs::AbstractDict)

Apply each key-value attribute to the model. Logs warnings if any
attribute is rejected by the optimizer.
"""
function apply_solver_attributes!(model::JuMP.Model, attrs::AbstractDict)
    for (k, v) in attrs
        try
            set_optimizer_attribute(model, k, v)
        catch e
            @warn "Could not set solver attribute" attribute=k value=v error=e
        end
    end
    model
end

"""
    gurobi_optimizer(; attrs::AbstractDict = default_gurobi_attributes()) -> JuMP optimizer factory

Returns an `optimizer_with_attributes(Gurobi.Optimizer, attrs...)` factory
ready to pass into `Model(...)`. Throws an informative error if Gurobi.jl
is not installed in the active environment.

```julia
using JuMP, IESAOpt
m = Model(IESAOpt.gurobi_optimizer())
# ... build constraints ...
optimize!(m)
```
"""
function gurobi_optimizer(; attrs::AbstractDict = default_gurobi_attributes())
    if !isdefined(@__MODULE__, :Gurobi)
        error("""
            Gurobi.jl is not loaded. Either:
              1. Set GUROBI_HOME and run `import Pkg; Pkg.add("Gurobi")`, then
              2. Restart Julia so `using IESAOpt` reloads with Gurobi available.

            Without Gurobi, use `Model(IESAOpt.highs_optimizer())` for HiGHS.
        """)
    end
    # Convert Dict{String,Any} to flat positional pairs for optimizer_with_attributes
    pairs_vec = [string(k) => v for (k, v) in attrs]
    return optimizer_with_attributes(getfield(@__MODULE__, :Gurobi).Optimizer, pairs_vec...)
end

"""
    highs_optimizer(; attrs::AbstractDict = default_highs_attributes()) -> JuMP optimizer factory

License-free fallback. Returns an `optimizer_with_attributes(HiGHS.Optimizer,
attrs...)` factory.
"""
function highs_optimizer(; attrs::AbstractDict = default_highs_attributes())
    if !isdefined(@__MODULE__, :HiGHS)
        error("HiGHS.jl not loaded. Add to Project.toml and restart Julia.")
    end
    pairs_vec = [string(k) => v for (k, v) in attrs]
    return optimizer_with_attributes(getfield(@__MODULE__, :HiGHS).Optimizer, pairs_vec...)
end
