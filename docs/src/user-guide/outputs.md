# Outputs

IESA-Opt.jl writes structured result tables to the selected output folder. New runs store model outputs in a single DuckDB database named `results.duckdb`.

Output folders are run artifacts. Keep important study outputs outside Git or archive them separately.

## Output Location

The default run script writes under `Output/`. Batch workflows write under `Output_Batch/`. Both folders are ignored by Git except for `.gitkeep` placeholders.

The default representative-day run writes to a folder named from the scenario, representative-day count, and thread count, for example:

```text
Output/julia_timing_default_data_rd30_threads5/
```

Custom output locations can be set in a local wrapper script with `IESA_OUT_DIR`; see [Getting Started](getting-started.md).

## Common Result Tables

| DuckDB table | Description |
| --- | --- |
| `timing_summary` | Scenario name, period, representative-day count, solve stage timings, model dimensions, objective value, and solver status. |
| `run_statistics` | Run-level metadata and solver statistics. |
| `solver_settings` | Solver attributes used for the run, when available. |
| `totalCosts` | Objective value by solve period. |
| `cost_breakdown` | Investment, fixed operation and maintenance, variable operation and maintenance, retrofit, salvage, and other cost components. |
| `techStock` | Installed technology stock by technology and period. |
| `tech_use` | Annual technology use by technology and period. |
| `tech_use_TS` | Representative-day dispatch results for time-slice runs. |
| `cluster_map` | Mapping from calendar days to representative days. |
| `CO2_price` | Emission-cap shadow prices when the corresponding dual outputs are available. |

Some output files depend on the selected solve mode and enabled writer options.

## Reading Results

Read DuckDB outputs from Julia, Python, R, or another analysis environment that supports DuckDB.

Example Julia snippet:

```julia
using DataFrames
using DuckDB
import DBInterface

con = DBInterface.connect(DuckDB.DB, "Output/my_scenario_rd40/results.duckdb"; readonly = true)
result = DBInterface.execute(con, "SELECT * FROM tech_use LIMIT 10")
df = DataFrame(result)
DBInterface.close!(result)
DBInterface.close!(con)
first(df, 10)
```

Older run folders containing Parquet files can still be read by the local UI for comparison during the migration period.

Back to the [documentation home](../index.md) or the [repository README](https://github.com/IESA-Opt/IESA-Opt.jl#readme).