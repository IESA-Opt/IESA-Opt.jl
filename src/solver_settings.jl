"""
Default Gurobi / HiGHS attribute presets matching the current IESA-Opt 1.0
production settings (Phase 7: 2026-06-10).

Source: `MainProject/IESA-Opt.ams` Procedure `DefineSolverSettings`
hoursPer_day >= 12 branch (the TS sweep hot path).
"""

"""
    default_gurobi_attributes(; threads=0, rep_days=nothing) -> Dict{String,Any}

Default Gurobi attributes for the production TS solve path. Mirrors the
IESA-Opt 1.0 Phase 7 settings: Barrier method, no crossover, BarHomogeneous=1
for Optimal certification, all tolerances at 1e-6, all-cores threading. When
`rep_days` is provided, representative-day tuning ranges add Gurobi presolve
and scaling settings validated with `grbtune` on 2026-06-14.

Usage:
```julia
using Gurobi, JuMP
m = Model(Gurobi.Optimizer)
for (k, v) in IESAOpt.default_gurobi_attributes()
    set_optimizer_attribute(m, k, v)
end
```
"""
const GUROBI_TUNED_RD_RANGES = (
    (lo = 1,  hi = 7,            attrs = Pair{String,Any}[]),
    (lo = 8,  hi = 12,           attrs = Pair{String,Any}["AggFill" => 0, "Presolve" => 1, "PreSparsify" => 2, "ScaleFlag" => 0]),
    (lo = 13, hi = 17,           attrs = Pair{String,Any}["AggFill" => 10, "NumericFocus" => 1, "ScaleFlag" => 0]),
    (lo = 18, hi = 22,           attrs = Pair{String,Any}["AggFill" => 100, "PreDepRow" => 1, "PreSparsify" => 0, "ScaleFlag" => 0]),
    (lo = 23, hi = 27,           attrs = Pair{String,Any}["AggFill" => 100, "PrePasses" => 1, "ScaleFlag" => 0]),
    (lo = 28, hi = 32,           attrs = Pair{String,Any}["AggFill" => 100, "PrePasses" => 3, "ScaleFlag" => 0]),
    (lo = 33, hi = 37,           attrs = Pair{String,Any}["ScaleFlag" => 0]),
    (lo = 38, hi = 42,           attrs = Pair{String,Any}["AggFill" => 100, "Aggregate" => 2, "Presolve" => 1, "ScaleFlag" => 0]),
    (lo = 43, hi = 47,           attrs = Pair{String,Any}["PrePasses" => 3, "ScaleFlag" => 0]),
    (lo = 48, hi = 55,           attrs = Pair{String,Any}["AggFill" => 100, "Presolve" => 1, "ScaleFlag" => 0]),
    (lo = 56, hi = 80,           attrs = Pair{String,Any}["AggFill" => 10, "Presolve" => 1, "ScaleFlag" => 0]),
    (lo = 81, hi = typemax(Int), attrs = Pair{String,Any}["Presolve" => 1]),
)

"""
    gurobi_tuned_attributes_for_repdays(rep_days) -> Dict{String,Any}

Return the Gurobi-only tuned attributes for a representative-day count. These
settings intentionally exclude `Threads`, `Method`, and `Crossover` so caller
thread counts and solve-method selections remain authoritative.
"""
function gurobi_tuned_attributes_for_repdays(rep_days::Integer)::Dict{String,Any}
    rd = max(1, Int(rep_days))
    for range in GUROBI_TUNED_RD_RANGES
        if range.lo <= rd <= range.hi
            return Dict{String,Any}(range.attrs)
        end
    end
    return Dict{String,Any}()
end

function default_gurobi_attributes(; threads::Int = 0, rep_days::Union{Nothing,Integer} = nothing)::Dict{String,Any}
    attrs = Dict{String,Any}(
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
        "FeasibilityTol"    => 1e-6,
        "OptimalityTol"     => 1e-6,
        "BarConvTol"        => 1e-7,

        # Output
        "OutputFlag"        => 1,
        "LogToConsole"      => 1,
    )
    if rep_days !== nothing
        merge!(attrs, gurobi_tuned_attributes_for_repdays(rep_days))
    end
    return attrs
end

"""
 Keep selected chronological barrier models in primal form to avoid excessive
factorization fill-in. Representative-day tuning and explicit overrides win.
"""
function _apply_full_hour_gurobi_attributes!(attrs::Dict{String,Any};
                                            hours_per_day::Union{Nothing,Integer} = nothing,
                                            rep_days::Union{Nothing,Integer} = nothing)
    if rep_days === nothing && hours_per_day in (1, 2, 3, 6, 8, 12, 24) &&
       get(attrs, "Method", 2) == 2 && get(attrs, "Crossover", 0) == 0
        get!(attrs, "PreDual", 0)
    end
    return attrs
end

"""
    gurobi_suboptimal_fallback!(model, attrs; optimize_fn = optimize!) -> Bool

Barrier without crossover can stop with Gurobi "Sub-optimal termination" (reported by JuMP as `LOCALLY_SOLVED`)
on numerically difficult LPs, e.g. regional full-hourly models. In that case re-solve with the homogeneous
Barrier algorithm (`BarHomogeneous=1`), and if that still ends sub-optimal, once more with crossover. Returns
`true` when a fallback ran and records the step used as `SuboptimalFallback` in `attrs`. Normal Barrier runs
are untouched.
"""
function gurobi_suboptimal_fallback!(model::JuMP.Model, attrs::AbstractDict; optimize_fn::Function = optimize!)
    get(attrs, "Method", -1) == 2 && get(attrs, "Crossover", -1) == 0 || return false
    termination_status(model) == MOI.LOCALLY_SOLVED || return false
    occursin("gurobi", lowercase(solver_name(model))) || return false
    if get(attrs, "BarHomogeneous", -1) != 1
        set_optimizer_attribute(model, "BarHomogeneous", 1)
        attrs["SuboptimalFallback"] = "BarHomogeneous=1"
        optimize_fn(model)
        termination_status(model) == MOI.LOCALLY_SOLVED || return true
    end
    set_optimizer_attribute(model, "Crossover", -1)
    attrs["SuboptimalFallback"] = "BarHomogeneous=1+Crossover"
    optimize_fn(model)
    return true
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
