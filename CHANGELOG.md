# Changelog

All notable changes to IESA-Opt.jl are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Initial Julia/JuMP package source for IESA-Opt.jl.
- Excel data loading, derived set and parameter helpers, clustering utilities,
  JuMP model construction, result writers, and solver settings.
- AIMMS-compatible CSV export (`write_aimms_csv_results`): UI runs now write the
  14 AIMMS result CSVs (`cap_investments`, `tech_Stock`, `tech_UseNet`,
  `tech_Use_h`, `tech_Use_d`, `deltaS_Shed`, `deltaU_CHP`, `eco_decommisioning`,
  `Salvage_value`, `prices_h`, `prices_d`, `commodity_prices`, `CO2_price`,
  `TotalCosts`) next to `results.duckdb`. Representative-day results are
  expanded to the full calendar using the day-mix weights; `commodity_prices`
  reports the true average (AIMMS multiplies it by the node count). Hourly and
  daily files follow the UI "Hourly reports" option.
- Automatic UI output folders are named
  `{N}Nodes_{resolution}_{clustering}_{yyyymmdd-HHMM}`, for example
  `1Nodes_FH24h_noclustering_20261110-0211` or
  `30Nodes_15RDx24h_kmedoids_20261110-1430`. The node count is the number of
  `CL*` cluster nodes actually used by technologies or activities (1 otherwise).
- The UI regional map reads cluster shapes and node locations directly from
  the GeoPackages in `ui/assets/maps` (new `src/ui_maps.jl`, `SQLite.jl`
  dependency). Files are discovered at request time and matched to a run by
  their number of clusters; a *Map* selector chooses between variants with the
  same node count. Electricity flows use the power-node layer, natural gas,
  hydrogen and CCS flows use the gas-node layer. The old
  `clusters_{15,30}.geojson` / `centroids_{15,30}.geojson` assets were removed.
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

### Changed

- Representative-day clustering now uses TulipaClustering.jl: peak-normalized
  hourly profiles and interconnector prices, five selection methods, and fitted
  convex, conical, bounded-conical, or Dirac day weights. The default is
  convex-hull selection with cosine distance and convex weights.
- Calendar-storage scope weights now sum fitted day mixtures. Single Run,
  Scenario Space, and MGA use the new clustering choices; separate forced
  extreme-day controls and generated capacity-envelope profiles are removed.
- Scenario Space now passes the selected temporal settings to campaign
  preparation and retains them for resume. Input caches rebuild automatically.
- The IESA-Opt 1.0 CHP ramping constraints (`rampingUP/DW_deltaUchp`,
  `rampingUP/DW_deltaPchp`, FH and TS) are now opt-in via
  `IESA_ENABLE_CHP_RAMP=1`, because the current AIMMS model has no CHP
  ramping. On the 10-node workbook they added about 130k rows at 1 h/day.
- Gurobi Barrier runs without crossover that stop with "Sub-optimal
  termination" (`LOCALLY_SOLVED`) are re-solved with the homogeneous Barrier
  algorithm (`BarHomogeneous=1`), and with crossover if still sub-optimal
  (`gurobi_suboptimal_fallback!`, used by UI runs). The step used is recorded
  as `attr:SuboptimalFallback` in `solver_settings`.

### Fixed

- The `CO2_price` and `emission_prices` DuckDB tables, the UI CO2-price chart
  and the scenario-space `co2_price` now divide the emission-cap dual by the
  social discount factor. They previously reported the discounted dual, which
  for 2050 is about 0.57 times the EUR/tCO2 price in `CO2_price.CSV` and AIMMS.
- `CO2_price.CSV` adds `CO2_Price_Air`, `CO2_Price_Bunker` and `CO2_Price_FS`
  (the price of each emission cap). `CO2_Price` is unchanged: like AIMMS it is
  the largest of the three, which follows the Bunker or FeedStock cap whenever
  that cap binds. Those duals are not unique, so compare the Air price between
  models.
- Infrastructure-volume limits (`infraVol_H`, `infraVol_D`, FH and TS) are no
  longer skipped for activities that no technology consumes but that have
  flexible-demand (`deltaQ`) or gas-buffer (`deltaB_UP`) terms, matching AIMMS.
  In the 10-node workbook this restores the hourly network limit on the CL1–CL5
  `Heat LT Network` flexibility; without it the regional LP was a relaxation of
  the AIMMS model.
- Time slicing no longer becomes infeasible on representative-day energy
  shortfalls: each clustered hourly profile is rescaled once to its exact
  8760-hour annual total.
- Full-hourly UI runs no longer apply representative-day Gurobi tuning,
  which disabled scaling and caused numerical failures. Runs without a solver
  solution now stop with the solver status instead of a result-writer error.
- The hourly flexibility-profile writer now reads model parameters correctly.
- Time slicing with *Force extreme periods* no longer fails with "reducing
  over an empty collection" on regional workbooks: the extreme-day criteria now
  recognise per-region wind/sun profiles (`CLn_Wind Onshore NL`, `CLn_Sun NL`,
  `Wind Offshore NSn`). Results for the national workbook are unchanged.
- Clustering approaches other than `kmeans_avg` now run a seeded k-means
  (`clustering_seed`), so identical settings always give identical
  representative days.
