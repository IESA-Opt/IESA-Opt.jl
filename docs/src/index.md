![IESA-Opt.jl logo](assets/iesa-opt-logo.png)

# IESA-Opt.jl

IESA-Opt.jl is the Julia implementation of the IESA-Opt integrated energy-system optimization model. It is built for capacity-expansion and dispatch studies that need sector coupling, temporal detail, storage, flexibility, emissions, and reproducible scenario comparison.

This documentation is the main user guide for the Julia package. The repository README remains a concise project front page; the pages here explain how to install, run, configure, interpret, and extend the model.

## Start Here

- [Getting Started](user-guide/getting-started.md): install Julia, instantiate dependencies, check the default workbook, and run the default case.
- [Input Database](user-guide/input-database/index.md): understand the workbook sheets, table conventions, and ingestion pipeline.
- [Solver Settings](user-guide/solver-settings.md): understand the Gurobi and HiGHS presets and how to keep run settings persistent.
- [Outputs](user-guide/outputs.md): see the main result files produced by IESA-Opt.jl.
- [Formulation](scientific-foundation/formulation/index.md): read the core activity, policy, cost, stock, temporal, and flexibility equations.

## What IESA-Opt.jl Is For

IESA-Opt.jl is intended for studies that analyse long-term energy-system transition pathways while preserving operational detail. Typical applications include:

- investment and dispatch planning across coupled energy sectors;
- comparison of hourly and representative-day temporal resolutions;
- assessment of storage, flexibility, emissions caps, and technology portfolios;
- scenario comparison using structured input workbooks and reproducible output folders.

## Documentation Map

The documentation is organized around the way users work with the model:

- User guide pages explain setup, run configuration, and outputs.
- Scientific foundation pages summarize the model scope, formulation families, and core IESA-Opt papers.
- Reference pages expose the Julia package API as docstrings mature.

Back to the [repository on GitHub](https://github.com/IESA-Opt/IESA-Opt.jl).

## Citation

If you use IESA-Opt.jl in academic or policy work, cite both core IESA-Opt model papers listed in [Scientific References](scientific-foundation/references.md) and in the repository `CITATION.cff` file.