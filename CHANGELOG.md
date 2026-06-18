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
- Default input workbook at `Input/default_data.xlsx`.
- MGA Results tab now includes an *Investments across alternatives* panel with
  a min/max envelope chart per technology (color-coded by category, with a
  baseline diamond marker) and ranked low-regret + high-volatility tables. The
  hybrid ORACLE solver records each alternative's full per-technology
  investment decisions (`techStock` + `cap_investments`), and the campaign
  result aggregates them into `investmentSpread` so the same data is available
  via `/api/mga/result/{id}` for external post-processing.
