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

## Known infeasibility fixes

- `TRD01_02` (`Electric Battery Vehicle - Motorcycle`) is the only technology serving `Motorcycles`. Its 2022 and 2025 `techStock_max` values must be high enough for `cap2act * techStock` to meet `activities_netVolumes`; otherwise standalone 2022/2025 solves are infeasible.
- Driver activity stock constraints must be lower bounds, not exact equalities. Fixed energy and material-conversion balances still enforce exact quantities where needed, but `actStock` for driver activities represents available stock/service capacity and must allow legacy capacity overhang in multi-period solves. In the Julia formulation, `actStock` is therefore `>= activities_netVolumes` rather than `== activities_netVolumes`.

Additional default workbook data fixes applied during the same infeasibility review:

- `neE01_01` through `neE01_14` are exogenous non-energy GHG pathway technologies with declining driver-activity volumes, no retrofit relations, and no other technologies serving their activities. Their `techStock_exist` values must represent the baseline legacy stock; in `default_data.xlsx`, they are set to their 2022 `techStock_max` values so multi-period solves can decommission the declining trajectory.
- `ICH01_01` (`Existing naphtha steam cracker - Petrochemical industry`) has a planned retirement trajectory that interacts with hourly shedding for `ICH01_05` in chained solves. The 2035 planned decommissioning value in `default_data.xlsx` is reduced from `1.3` to `0.81`, allowing the model to retire excess Ethylene stock earlier in 2030 while preserving nonnegative stock through 2040.

Back to [Input Database](index.md).