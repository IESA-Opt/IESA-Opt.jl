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

Solve results are written under `Output/` or `Output_Batch/`. Parquet is the primary output format, and most writers also create CSV sidecars for quick inspection. Common result tables include run statistics, total costs, cost breakdowns, technology stock, technology use, representative-day dispatch, cluster maps, and emission-price outputs. See the [outputs guide](https://iesa-opt.github.io/IESA-Opt.jl/v0.1/user-guide/outputs/) for details.

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