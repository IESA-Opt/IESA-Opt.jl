# Model Scope

IESA-Opt.jl is designed for integrated energy-system optimization studies that combine investment planning with operational representation. The model focuses on transition-pathway questions where technology portfolios, energy-sector coupling, storage, flexibility, and emissions constraints interact over one or more study periods.

## Study Questions

The model is suited to questions such as:

- Which technologies are selected under a given cost, demand, and policy scenario?
- How do storage and flexibility options affect system cost and dispatch?
- How do representative-day runs compare with more detailed temporal representations?
- How do emissions constraints and sector-coupling choices change investment pathways?

## Temporal Representation

IESA-Opt.jl supports scripts for annual, full-hourly, and representative-day time-slice workflows. Representative-day workflows can reduce runtime while preserving selected temporal structure for dispatch and storage analysis.

## Repository Boundary

The public repository contains the Julia implementation, default example data, tests, scripts, and documentation. Study-specific workbooks, generated output folders, solver logs, and local run wrappers should remain outside Git unless they are intentionally prepared for public release.

## Scientific Background

The Julia implementation follows the IESA-Opt modelling lineage. For academic and policy work, cite the two core IESA-Opt papers listed in [References](references.md).

Back to the [documentation home](../index.md) or the [repository README](https://github.com/IESA-Opt/IESA-Opt.jl#readme).