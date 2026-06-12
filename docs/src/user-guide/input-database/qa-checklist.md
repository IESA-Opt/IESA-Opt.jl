# Input Data QA Checklist

Run these checks before starting long solves.

## Workbook Structure

- Sheet names match the expected names in [Workbook Structure](workbook-structure.md).
- Columns have not been reordered or deleted.
- Formula-driven cells were copied when rows were added.
- Period columns match the periods passed to `read_data`.

## Identifiers

- Technology IDs used in `EnergyBalance`, `Retrofitting`, `Feedstocks`, and `Infrastructure` exist in the relevant technology tables.
- Activity IDs used in `EnergyBalance`, `Activities`, `ActGrouping`, and `EffLearning` are consistent.
- Node IDs used by activities and node parameters exist in `Types`.
- Profile type labels in `Technologies` exist in `HourlyProfiles`.
- Flexibility type and range labels in `Technologies` exist in `Types`.

## Numerical Checks

- Costs are in consistent units across investment, fixed O&M, variable O&M, retrofit, and salvage inputs.
- Capacity-to-activity factors `cap2act` are nonzero for technologies that need stock-to-activity conversion.
- Stock minimum and maximum bounds are feasible for the activity volumes they support.
- Emission targets and cumulative budgets are not contradictory for the selected periods.
- Hourly profiles are complete for the full modeled year.

## First Commands

From the repository root:

```powershell
julia --project=. scripts/load_only.jl data/default_data.xlsx
julia --project=. test/runtests.jl
```

For a private workbook, replace the path in the load-only command and inspect the printed summary before solving.

Back to [Input Database](index.md).