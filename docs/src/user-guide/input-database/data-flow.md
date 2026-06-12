# Data Flow

IESA-Opt.jl separates workbook ingestion, set derivation, parameter derivation, model construction, solve, and output writing.

```text
Excel workbook
    |
    v
read_data(xlsx_path)
    |
    +--> ModelSets: periods, hours, activities, technologies, nodes, type sets
    |
    +--> ModelParams: costs, profiles, balances, policy targets, flexibility settings
    |
    v
derive_sets!(md)
    |
    +--> technology subsets: storage, shedding, CHP, hourly dispatch, daily dispatch, infrastructure
    +--> activity subsets: hourly, daily, driver, target, material, grouped activities
    |
    v
compute_derived_params!(md)
    |
    +--> temporal helpers, financial factors, investment matrices, activity balances, flexibility capacities
    |
    v
model build
    |
    +--> variables, stock constraints, balances, objective, temporal constraints, policy constraints
    |
    v
solve
    |
    v
write_parquet_results(...)
    |
    +--> Output/*.parquet and Output/*.csv
```

## Core Julia Entry Points

```julia
md = read_data("data/default_data.xlsx")
derive_sets!(md)
compute_derived_params!(md)
```

`read_data` already calls `derive_sets!` and `compute_derived_params!`. The separate calls are useful when a script edits `md.sets` or `md.params` after reading and then needs to recompute derived structures.

## Sheet To Model Link

- `Types` defines valid labels.
- `Activities` and `Technologies` define the main model entities.
- `EnergyBalance` connects technologies to activities.
- `HourlyProfiles` and `PriceProfiles` supply temporal signals.
- `NodeParameters` supplies policy limits.
- `Infrastructure`, `Feedstocks`, `EffLearning`, and `Retrofitting` extend the technology and accounting logic.

Back to [Input Database](index.md).