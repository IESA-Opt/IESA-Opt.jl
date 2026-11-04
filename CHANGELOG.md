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
- Opt-in *Cluster land use* extension (`:land_use`, UI toggle under
  *Reporting and advanced settings*, off by default) porting the AIMMS
  constraint `c_ClusterSpace_Limit`: in 2050, the stock of each industrial
  cluster's `CLn_` technologies weighted by Technologies column DS
  "Space (Ha)" may not exceed the Parameters row `CLn_AvailableArea`. The run
  log reports the land used per cluster after every solve (AIMMS
  `p_clusterSpace_used`), and `solver_settings` records the extension toggles.
  The DuckDB input-cache format version is bumped so cached workbooks are
  re-read with the new land-use inputs.

### Fixed

- Time slicing with *Force extreme periods* no longer fails with "reducing
  over an empty collection" on regional workbooks: the extreme-day criteria now
  recognise per-region wind/sun profiles (`CLn_Wind Onshore NL`, `CLn_Sun NL`,
  `Wind Offshore NSn`). Results for the national workbook are unchanged.
- Clustering approaches other than `kmeans_avg` now run a seeded k-means
  (`clustering_seed`), so identical settings always give identical
  representative days.
