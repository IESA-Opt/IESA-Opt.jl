![IESA-Opt.jl logo](docs/src/assets/iesa-opt-logo.png)

# IESA-Opt 2.0 (IESA-Opt.jl)

[![Julia](https://img.shields.io/badge/julia-1.10%2B-9558B2.svg)](https://julialang.org/)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-Documenter.jl-blue.svg)](https://iesa-opt.github.io/IESA-Opt.jl/v0.1/)
[![Citation](https://img.shields.io/badge/citation-CITATION.cff-green.svg)](CITATION.cff)

IESA-Opt 2.0, also published as IESA-Opt.jl, is the Julia implementation of the IESA-Opt integrated energy-system optimization model. It is designed for capacity-expansion and dispatch studies with sector coupling, technology investment, storage, flexibility, emissions, hourly operation, representative-day operation, and scenario comparison.

The repository contains the package source, tests, reusable run scripts, documentation, and a default input workbook. Generated outputs, private scenario files, solver logs, and machine-specific run settings are intentionally kept out of Git.

## Model Scope

IESA-Opt.jl is intended for studies that need to analyse long-term energy-system transition pathways while preserving operational detail. Typical applications include:

- investment and dispatch planning across coupled energy sectors;
- comparison of hourly and representative-day temporal resolutions;
- assessment of storage, flexibility, emissions caps, and technology portfolios;
- scenario comparison using structured input workbooks and reproducible output folders.

## Documentation

User-facing documentation is built with Documenter.jl and published at [iesa-opt.github.io/IESA-Opt.jl/v0.1](https://iesa-opt.github.io/IESA-Opt.jl/v0.1/). Start there for the maintained setup, input, formulation, and workflow pages:

- [Getting started](https://iesa-opt.github.io/IESA-Opt.jl/v0.1/user-guide/getting-started/): install Julia, open the repository, instantiate dependencies, and run the default case.
- [Input database](https://iesa-opt.github.io/IESA-Opt.jl/v0.1/user-guide/input-database/): workbook structure, sheet meanings, data flow, and quality checks.
- [Formulation](https://iesa-opt.github.io/IESA-Opt.jl/v0.1/scientific-foundation/formulation/): objective, stock evolution, temporal representation, and flexibility archetypes.
- [Outputs](https://iesa-opt.github.io/IESA-Opt.jl/v0.1/user-guide/outputs/): expected result files and how to interpret the main tables.

The README is kept short on purpose. Detailed input-data notes, formulation notes, examples, and API documentation should be added under `docs/src/` rather than expanded here.

## Quick Start

Install Julia 1.10 or newer, clone the repository, open it in your IDE, and start a terminal in the repository root.

```powershell
git clone https://github.com/IESA-Opt/IESA-Opt.jl.git
cd IESA-Opt.jl
julia --version
julia --project=. -e "using Pkg; Pkg.instantiate()"
```

Check that the example workbook can be loaded:

```powershell
julia --project=. scripts/load_only.jl data/default_data.xlsx
```

Run the default representative-day solve:

```powershell
julia --project=. scripts/run_ts_timing.jl
```

For repeated study runs, keep local run wrappers under `local/`, which is ignored by Git. See the [getting started guide](https://iesa-opt.github.io/IESA-Opt.jl/v0.1/user-guide/getting-started/) for a complete example.

## Input Data And Results

IESA-Opt.jl reads Excel workbooks from paths relative to the repository root. The tracked example input is [data/default_data.xlsx](data/default_data.xlsx). Additional local study workbooks can be placed in `data/` or `data_Batch/`; those folders are configured so private scenario files stay out of Git.

Solve results are written under `Output/` or `Output_Batch/`. New runs store model outputs in a single DuckDB database named `results.duckdb` in each run folder. Common result tables include run statistics, solve timings, total costs, cost breakdowns, technology stock, technology use, representative-day dispatch, cluster maps, and emission-price outputs. The Excel workbook remains the editable input source; repeated runs automatically reuse a compiled DuckDB input cache and rebuild it when the workbook changes. See the [outputs guide](https://iesa-opt.github.io/IESA-Opt.jl/v0.1/user-guide/outputs/) for details.

## Local UI Dashboard

IESA-Opt.jl ships with a local browser-based UI for configuring runs, monitoring solver progress, and exploring results. The UI runs as a small HTTP server on `http://127.0.0.1:8123` and reads/writes the same workbooks and `Output/` folders that the command-line scripts use, so anything you do in the UI stays reproducible from the terminal.

### Launching the UI

Make sure dependencies are installed once (`julia --project=. -e "using Pkg; Pkg.instantiate()"`), then start the UI with one of the following options:

- **Windows (one-click):** double-click `IESA-Opt UI.lnk` in the repository root (the shortcut is created automatically on first launch -- if it isn't there yet, double-click [scripts/launcher/start-ui.bat](scripts/launcher/start-ui.bat) once and the shortcut will appear next to it). A PowerShell window opens, starts Julia, and your default browser immediately opens a small loading page that automatically reloads into the UI as soon as the server is ready (typically around 20 s on a warm install, longer on the very first run). Keep the launcher window open while using the UI; closing it stops the server.
- **PowerShell:** right-click [scripts/launcher/start-ui.ps1](scripts/launcher/start-ui.ps1) and choose *Run with PowerShell*, or from a PowerShell prompt run `./scripts/launcher/start-ui.ps1`.
- **Cross-platform terminal:** from the repository root run `julia --threads=auto --project=. scripts/serve_ui.jl`. The same script works on Windows, macOS, and Linux.
- **From inside Julia:** `using IESAOpt; serve_ui!()` (defaults: `host="127.0.0.1"`, `port=8123`, `open_browser=true`). To run headless (no auto-open), use `serve_ui!(open_browser=false)`.

The first launch precompiles the package and warms an input cache for `data/default_data.xlsx`; subsequent launches start in a few seconds.

#### Developer fast-start

Active development triggers a Julia re-precompile every time you save a source file. The default precompile workload runs the full TS LP build path to bake JIT'd code into the cache, which adds ~60–90 s to each `Pkg.precompile`. If you are iterating quickly on the source and don't want that delay, set:

- `IESA_OPT_SKIP_PRECOMPILE=1` — skip the `@compile_workload` block during `Pkg.precompile` (rebuilds the package in seconds rather than minutes).
- `IESA_OPT_SKIP_WARMUP=1` — skip the in-server warmup at `serve_ui!()` startup. The first `Run` click then JIT-compiles on demand instead.

Pair both for the fastest development loop. Unset them (or set to `0`) to get the production behavior back: precompile bakes the run path, warmup loads the workbook into memory, and the first `Run` click is essentially instant.

### Using the UI

The UI has three tabs:

- **Run.** Pick an input workbook (Browse selects any `.xlsx` / `.xlsm` / `.xls` file under `data/`), choose temporal mode (annual, time-slice, or full-hourly), set periods, representative days, hours per day, solver, threads, and output name, then click *Run*. The right-hand panel streams live solver output and per-stage progress (read → prepare → cluster → generate → solve → write).
- **Results.** Lists every folder under `Output/` and `Output_Batch/` that contains result files, sorted by most recent first. Click a run to inspect it; Ctrl/⌘-click adds runs to a compare set, Shift-click selects a range. Each panel has a *Show table* toggle for the underlying data.
- **Compare.** When two or more runs are selected, the comparison panel displays side-by-side system costs, solve times, and component-cost breakdowns.

All results charts are interactive (zoom, pan, click-to-toggle legend, save-as-PNG):

- *System Costs* — stacked bars by cost component per period or per run.
- *Solve Time And Solver Stats* — stacked bars by phase (read / prepare / cluster / generate / solve / write).
- *CO₂ Price* — shadow price of the emission cap per period.
- *Activity Prices* — shadow prices of balance constraints (table view).
- *Power System Capacities* — stacked bars by technology per period.
- *Hourly Dispatch* — full-year stacked-area chart with node and period selectors, From/To hour range, and box-zoom (drag a region to zoom; double-click to reset). Negative values (charging, consumption) stack below zero.
- *Emissions* and *Supply / Demand* — vertical stacked bars with a black diamond marker for the per-period net total, grouped by sector / activity / tech.

### Stopping the UI

Close the launcher window, or press **Ctrl+C** in the terminal where Julia is running. The UI does not modify your input workbooks.

### Troubleshooting

- *Browser does not open automatically.* Open `http://127.0.0.1:8123` manually. If the loading page opens but never redirects, your browser may be blocking the cross-origin probe from `file://`; open `http://127.0.0.1:8123/` manually in the same browser.
- *Port 8123 already in use.* Stop the other process, or start the UI on a different port from Julia: `using IESAOpt; serve_ui!(port=8800)`.
- *"Julia was not found on PATH."* Install Julia 1.10 or newer from [julialang.org](https://julialang.org/), reopen the terminal, and run the launcher again.
- *Solver missing.* The Run page only offers solvers that resolve at startup (HiGHS is bundled; Gurobi requires a valid license and `Gurobi.jl` available in the project).

## Repository Layout

```text
src/              Julia package source
src/model/        Variable, objective, and constraint families
scripts/          Reusable run and smoke-test scripts
test/             Unit and smoke tests
data/             Default and local single-run input workbooks
data_Batch/       Local batch input workbooks and scenario variants
Output/           Generated single-run outputs, ignored by Git
Output_Batch/     Generated batch outputs, ignored by Git
ui/               Local UI dashboard assets (HTML, JS, CSS, vendored Plotly)
scripts/launcher/ Windows .bat / PowerShell .ps1 launchers for the local UI
docs/             User-facing documentation
```

## Citation

If you use IESA-Opt.jl in academic or policy work, cite both core IESA-Opt model papers. The same information is available in [CITATION.cff](CITATION.cff) for GitHub's citation interface.

1. Sánchez Diéguez M., Fattahi A., Sijm J., Morales España G., Faaij A. (2021). *Modelling of decarbonisation transition in national integrated energy system with hourly resolution.* *Advances in Applied Energy*, 3, 100043. https://doi.org/10.1016/j.adapen.2021.100043

2. Fattahi A., Sánchez Diéguez M., Sijm J., Morales España G., Faaij A. (2021). *Measuring accuracy and computational capacity trade-offs in an hourly integrated energy system model.* *Advances in Applied Energy*, 1, 100009. https://doi.org/10.1016/j.adapen.2020.100009

## Questions And Contributions

Use GitHub issues for bug reports, installation problems, and suggestions for improving the model or documentation. Please include the Julia version, operating system, solver, command used, and the relevant error message or output summary.

Contribution guidance is available in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

IESA-Opt 2.0 / IESA-Opt.jl is released under the Apache License, Version 2.0. See [LICENSE](LICENSE). The model may depend on third-party solvers or data sources with their own licenses; Gurobi requires a valid Gurobi license for production runs.