# Outputs

IESA-Opt.jl writes structured result files to the selected output folder. Parquet files are the primary output format, and most result writers also create CSV sidecars with the same base name for quick inspection.

Output folders are run artifacts. Keep important study outputs outside Git or archive them separately.

## Output Location

The default run script writes under `Output/`. Batch workflows write under `Output_Batch/`. Both folders are ignored by Git except for `.gitkeep` placeholders.

The default representative-day run writes to a folder named from the scenario, representative-day count, and thread count, for example:

```text
Output/julia_timing_default_data_rd30_threads5/
```

Custom output locations can be set in a local wrapper script with `IESA_OUT_DIR`; see [Getting Started](getting-started.md).

## Common Result Tables

| File | Description |
| --- | --- |
| `timing_summary.csv` | Scenario name, period, representative-day count, solve stage timings, model dimensions, objective value, and solver status. |
| `run_statistics.parquet` / `run_statistics.csv` | Run-level metadata and solver statistics. |
| `totalCosts.parquet` / `totalCosts.csv` | Objective value by solve period. |
| `cost_breakdown.parquet` / `cost_breakdown.csv` | Investment, fixed operation and maintenance, variable operation and maintenance, retrofit, salvage, and other cost components. |
| `techStock.parquet` / `techStock.csv` | Installed technology stock by technology and period. |
| `tech_use.parquet` / `tech_use.csv` | Annual technology use by technology and period. |
| `tech_use_TS.parquet` / `tech_use_TS.csv` | Representative-day dispatch results for time-slice runs. |
| `cluster_map.parquet` / `cluster_map.csv` | Mapping from calendar days to representative days. |
| `CO2_price.parquet` / `CO2_price.csv` | Emission-cap shadow prices when the corresponding dual outputs are available. |

Some output files depend on the selected solve mode and enabled writer options.

## Reading Results

CSV sidecars can be opened directly in spreadsheet tools for quick inspection. For larger studies, read the Parquet files from Julia, Python, R, or another analysis environment that supports columnar data.

Example Julia snippet:

```julia
using DataFrames
using Parquet2

df = DataFrame(Parquet2.Dataset("Output/my_scenario_rd40/tech_use.parquet"))
first(df, 10)
```

Back to the [documentation home](../index.md) or the [repository README](https://github.com/IESA-Opt/IESA-Opt.jl#readme).