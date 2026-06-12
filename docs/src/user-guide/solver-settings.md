# Solver Settings

IESA-Opt.jl builds linear optimization models with JuMP and solves them with a supported LP solver. The solver presets are defined in `src/solver_settings.jl` so users do not need to re-enter solver attributes for every run.

## Recommended Solver

Use Gurobi for production-scale studies. HiGHS is useful for smoke tests, installation checks, and development work where a commercial solver license is not available.

Before running production cases, install Gurobi, make sure the license is active, and verify that Julia can load Gurobi.jl:

```powershell
julia --project=. -e "using Gurobi; println(Gurobi.version())"
```

If Julia cannot find Gurobi, set `GUROBI_HOME` according to the Gurobi.jl installation guide, rebuild or instantiate the environment again, and restart Julia.

## Built-In Presets

IESA-Opt.jl exposes two solver preset helpers:

- `IESA_J.default_gurobi_attributes(; threads=0)`: production-oriented Gurobi settings.
- `IESA_J.default_highs_attributes(; threads=0)`: license-free HiGHS settings for smoke tests and development.

Inspect the Gurobi preset from the repository root:

```powershell
julia --project=. -e "using IESA_J; display(IESA_J.default_gurobi_attributes())"
```

The default Gurobi preset uses barrier, skips crossover, lets Gurobi choose presolve and scaling, and applies numerical tolerances suitable for the model's large LPs. Thread count defaults to `0`, meaning Gurobi may use all available cores.

## Overriding Settings

For custom scripts, start from the preset and override only the options needed for the study:

```julia
using IESA_J
using JuMP

attrs = IESA_J.default_gurobi_attributes(; threads = 8)
attrs["Crossover"] = 0
attrs["OutputFlag"] = 1

model = Model(IESA_J.gurobi_optimizer(; attrs = attrs))
```

For HiGHS:

```julia
using IESA_J
using JuMP

attrs = IESA_J.default_highs_attributes(; threads = 4)
model = Model(IESA_J.highs_optimizer(; attrs = attrs))
```

## Persistent Run Settings

Run-specific choices such as workbook path, output folder, representative-day count, and thread count can be placed in a local wrapper script under `local/`. That folder is ignored by Git, so users can keep machine-specific settings without changing repository files.

Example:

```powershell
# local/run-study-a.ps1
$env:IESA_DATA_XLSX = "data\study_a.xlsx"
$env:IESA_REPDAYS = "40"
$env:IESA_THREADS = "8"
$env:IESA_OUT_DIR = "Output\study_a_rd40"
julia --project=. scripts\run_ts_timing.jl
```

Use solver presets for solver behavior and local wrapper scripts for run configuration. This keeps the repository clean while avoiding repeated manual environment-variable setup.

Back to the [documentation home](../index.md) or the [repository README](https://github.com/IESA-Opt/IESA-Opt.jl#readme).