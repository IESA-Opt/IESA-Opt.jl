# Getting Started

This guide walks through a first local run from a clean checkout. Commands are shown for PowerShell from the repository root.

## 1. Install Julia And Open The Repository

Install Julia 1.10 or newer from [julialang.org/downloads](https://julialang.org/downloads/). VS Code with the Julia extension is a convenient IDE, but any editor plus a terminal is enough.

Clone the repository and open it in your IDE:

```powershell
git clone https://github.com/IESA-Opt/IESA-Opt.jl.git
cd IESA-Opt.jl
```

Confirm that Julia is available from the terminal:

```powershell
julia --version
```

If this command is not recognized, add Julia to your system `PATH` or use the Julia terminal configured by your IDE.

## 2. Install Project Dependencies

Instantiate the package environment from the repository root:

```powershell
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

Run the same command after pulling repository updates. Julia will reuse already installed packages where possible.

## 3. Configure The Solver

The default solver presets are defined in `src/solver_settings.jl` and explained in [Solver Settings](solver-settings.md). Gurobi is recommended for production-scale studies. HiGHS is useful for smoke tests, installation checks, and development work where a commercial solver license is not available.

Check the Gurobi preset from Julia:

```powershell
julia --project=. -e "using IESA_J; display(IESA_J.default_gurobi_attributes())"
```

If using Gurobi for production runs, verify that Julia can load Gurobi.jl and that the license is active:

```powershell
julia --project=. -e "using Gurobi; println(Gurobi.version())"
```

## 4. Run Basic Checks

Run the test suite:

```powershell
julia --project=. test/runtests.jl
```

Load the default workbook and print a data summary:

```powershell
julia --project=. scripts/load_only.jl data/default_data.xlsx
```

## 5. Run The Default Case

Start the default representative-day time-slice solve:

```powershell
julia --project=. scripts/run_ts_timing.jl
```

By default, the run script reads `data/default_data.xlsx`, solves the 2050 period with 30 representative days, and writes to an output folder under `Output/` named from the scenario, representative-day count, and thread count.

## 6. Keep Repeated Run Settings In A Local Wrapper

For repeated custom runs, keep your settings in a local wrapper script under `local/`. That folder is ignored by Git, so machine-specific and study-specific choices do not enter the public repository.

Example:

```powershell
# local/run-my-case.ps1
$env:IESA_DATA_XLSX = "data\my_scenario.xlsx"
$env:IESA_REPDAYS = "40"
$env:IESA_THREADS = "8"
$env:IESA_OUT_DIR = "Output\my_scenario_rd40"
julia --project=. scripts\run_ts_timing.jl
```

Then run:

```powershell
.\local\run-my-case.ps1
```

Use local wrappers for run choices such as workbook path, representative-day count, thread count, and output directory. Use the solver preset mechanism in [Solver Settings](solver-settings.md) for solver behavior.

Back to the [documentation home](../index.md) or the [repository README](https://github.com/IESA-Opt/IESA-Opt.jl#readme).