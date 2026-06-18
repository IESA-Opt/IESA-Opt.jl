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

IESA-Opt.jl exposes these solver preset helpers:

- `IESAOpt.default_gurobi_attributes(; threads=0, rep_days=nothing)`: production-oriented Gurobi settings. Pass `rep_days` to apply representative-day tuned Gurobi settings.
- `IESAOpt.gurobi_tuned_attributes_for_repdays(rep_days)`: the tuned Gurobi attributes only, excluding thread count and solve method.
- `IESAOpt.default_highs_attributes(; threads=0)`: license-free HiGHS settings for smoke tests and development.

Inspect the Gurobi preset from the repository root:

```powershell
julia --project=. -e "using IESAOpt; display(IESAOpt.default_gurobi_attributes())"
```

The default Gurobi preset uses barrier, skips crossover, lets Gurobi choose presolve and scaling unless `rep_days` is supplied, and applies numerical tolerances suitable for the model's large LPs. Thread count defaults to `0`, meaning Gurobi may use all available cores.

## Representative-Day Gurobi Tuning

The Gurobi representative-day presets come from a `grbtune` campaign on the default workbook, run for 60 minutes per RD with `Method=2`, `Crossover=-1`, and `Threads=10`. The production helper keeps `Threads`, `Method`, and `Crossover` outside the tuned range table so UI and script selections still control those values.

| Representative days | Tuned Gurobi attributes |
|---:|---|
| 1-7 | Baseline production preset; no tuned override improved RD5. |
| 8-12 | `AggFill=0`, `Presolve=1`, `PreSparsify=2`, `ScaleFlag=0` |
| 13-17 | `AggFill=10`, `NumericFocus=1`, `ScaleFlag=0` |
| 18-22 | `AggFill=100`, `PreDepRow=1`, `PreSparsify=0`, `ScaleFlag=0` |
| 23-27 | `AggFill=100`, `PrePasses=1`, `ScaleFlag=0` |
| 28-32 | `AggFill=100`, `PrePasses=3`, `ScaleFlag=0` |
| 33-37 | `ScaleFlag=0` |
| 38-42 | `AggFill=100`, `Aggregate=2`, `Presolve=1`, `ScaleFlag=0` |
| 43-47 | `PrePasses=3`, `ScaleFlag=0` |
| 48-55 | `AggFill=100`, `Presolve=1`, `ScaleFlag=0` |
| 56-80 | `AggFill=10`, `Presolve=1`, `ScaleFlag=0` |
| 81+ | `Presolve=1` |

The top tuned candidates observed for each sampled RD were:

| RD | Baseline runtime | Tuned candidates |
|---:|---:|---|
| 5 | 1.69 s | No improvement over baseline. |
| 10 | 5.71 s | 3.30 s: `AggFill=0`, `Presolve=1`, `PreSparsify=2`, `ScaleFlag=0`; 3.73 s: `AggFill=100`, `PreSparsify=2`, `ScaleFlag=0`; 3.86 s: `AggFill=100`, `ScaleFlag=0` |
| 15 | 12.17 s | 6.34 s: `AggFill=10`, `NumericFocus=1`, `ScaleFlag=0`; 7.72 s: `NumericFocus=1`, `ScaleFlag=0`; 9.92 s: `ScaleFlag=0` |
| 20 | 20.48 s | 10.54 s: `AggFill=100`, `PreDepRow=1`, `PreSparsify=0`, `ScaleFlag=0`; 11.38 s: `AggFill=100`, `PreDepRow=1`, `ScaleFlag=0`; 11.52 s: `AggFill=100`, `ScaleFlag=0` |
| 25 | 32.87 s | 13.78 s: `AggFill=100`, `PrePasses=1`, `ScaleFlag=0`; 15.76 s: `AggFill=100`, `ScaleFlag=0`; 25.13 s: `ScaleFlag=0` |
| 30 | 41.98 s | 20.42 s: `AggFill=100`, `PrePasses=3`, `ScaleFlag=0`; 21.42 s: `AggFill=100`, `ScaleFlag=0`; 32.82 s: `ScaleFlag=0` |
| 35 | 62.78 s | 25.49 s: `ScaleFlag=0` |
| 40 | 74.96 s | 33.64 s: `AggFill=100`, `Aggregate=2`, `Presolve=1`, `ScaleFlag=0`; 34.45 s: `Aggregate=2`, `PreDepRow=0`, `ScaleFlag=0`; 35.36 s: `Aggregate=2`, `ScaleFlag=0` |
| 45 | 79.91 s | 42.77 s: `PrePasses=3`, `ScaleFlag=0`; 46.50 s: `ScaleFlag=0` |
| 50 | 139.26 s | 40.28 s: `AggFill=100`, `Presolve=1`, `ScaleFlag=0`; 42.59 s: `AggFill=100`, `ScaleFlag=0`; 49.88 s: `ScaleFlag=0` |
| 60 | 139.63 s | 70.82 s: `AggFill=10`, `Presolve=1`, `ScaleFlag=0`; 71.82 s: `Presolve=1`, `ScaleFlag=0`; 129.65 s: `Presolve=1` |
| 100 | 393.64 s | 351.50 s: `Presolve=1` |

## Overriding Settings

For custom scripts, start from the preset and override only the options needed for the study:

```julia
using IESAOpt
using JuMP

attrs = IESAOpt.default_gurobi_attributes(; threads = 8)
attrs["Crossover"] = 0
attrs["OutputFlag"] = 1

model = Model(IESAOpt.gurobi_optimizer(; attrs = attrs))
```

For HiGHS:

```julia
using IESAOpt
using JuMP

attrs = IESAOpt.default_highs_attributes(; threads = 4)
model = Model(IESAOpt.highs_optimizer(; attrs = attrs))
```

The HiGHS preset uses IPM with crossover off by default. When the UI or a
script selects `barrier_crossover`, IESA-Opt requests HiGHS IPM crossover and
sets the validated crossover tolerances used for the large LPs. Post-crossover
simplex cleanup can be disabled for benchmark-style timing runs by setting
`simplex_iteration_limit = 0`; those runs can time barrier+crossover, but they
may not expose a full JuMP solution for result-table writing.

When running from the UI, the selected solver and solve method are mapped to
that solver's own controls: Gurobi, HiGHS, CPLEX, and XPRESS each receive their
own barrier, barrier+crossover, concurrent, primal-simplex, or dual-simplex
attributes where the solver supports them.

## Persistent Run Settings

Run-specific choices such as workbook path, output folder, representative-day count, and thread count can be placed in a local wrapper script under `local/`. That folder is ignored by Git, so users can keep machine-specific settings without changing repository files.

Example:

```powershell
# local/run-study-a.ps1
$env:IESA_DATA_XLSX = "Input\study_a.xlsx"
$env:IESA_REPDAYS = "40"
$env:IESA_THREADS = "8"
$env:IESA_OUT_DIR = "Output\study_a_rd40"
julia --project=. scripts\run_ts_timing.jl
```

Use solver presets for solver behavior and local wrapper scripts for run configuration. This keeps the repository clean while avoiding repeated manual environment-variable setup.

Back to the [documentation home](../index.md) or the [repository README](https://github.com/IESA-Opt/IESA-Opt.jl#readme).