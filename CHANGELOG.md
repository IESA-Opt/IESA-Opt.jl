# Changelog

All notable changes to IESA-Opt.jl are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Initial Julia/JuMP package source for IESA-Opt.jl.
- Excel data loading, derived set and parameter helpers, clustering utilities,
  JuMP model construction, result writers, and solver settings.
- Reusable run scripts for loading data, smoke tests, single solves, time-slice
  timing runs, and sweep entry points.
- Unit and smoke tests for package loading, data reading, derived parameters,
  data writing, solver factories, and model helpers.
- Default input workbook at `data/default_data.xlsx`.
