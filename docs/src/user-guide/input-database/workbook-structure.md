# Workbook Structure

The current Julia reader expects the active sheets below. The names are exact workbook sheet names.

| Sheet | Role |
| --- | --- |
| `IESA-Opt database` | Scenario metadata and description. |
| `Parameters` | Global scalar settings such as transmission loss, discounting, thresholds, and active constraint set. |
| `Types` | Enumerations for dispatch types, activity types, process types, flexibility types, ranges, sectors, nodes, and energy labels. |
| `NodeParameters` | Node-level emission targets, cumulative CO2 budget, and cumulative CO2 storage limits. |
| `Activities` | Activity identifiers, units, activity volumes by period, dispatch type, activity type, node, and emission-target flags. |
| `HourlyProfiles` | Hour index, month mapping, and normalized profile shapes used by hourly and time-slice dispatch. |
| `Technologies` | Main technology table: identity, costs, lifetime, operation type, profile type, flexibility settings, stock limits, investment limits, and decommissioning. |
| `EnergyBalance` | Technology-activity coefficients used to build activity balances and emission accounting. |
| `Infrastructure` | Network and infrastructure technologies; these are merged into the technology parameter dictionaries. |
| `PriceProfiles` | Hourly market price trajectories for interconnected commodities. |
| `ActGrouping` | Optional grouped activity definitions for reduced or aggregated workflows. |
| `EffLearning` | Technology-activity efficiency-improvement factors by period. |
| `Feedstocks` | Feedstock use factors for material and carbon accounting. |
| `Retrofitting` | Allowed retrofit relations and retrofit costs between technologies. |

## Editing Rules

- Keep sheet names unchanged.
- Keep column order unchanged.
- Copy formulas when adding rows.
- Use stable identifiers for technologies, activities, nodes, profile types, and flexibility types.
- Check that identifiers used in one sheet exist in the sheet that defines them.
- Keep private or study-specific workbooks outside Git unless they are intentionally prepared as public examples.

## Period Columns

Many sheets contain period-indexed blocks, typically for 2022, 2025, 2030, 2035, 2040, 2045, and 2050. The Julia call

```julia
read_data("Input/default_data.xlsx"; periods = [2022, 2025, 2030, 2035, 2040, 2045, 2050])
```

sets the period universe used by the reader. `periods_solve` can then select a subset of periods for solving.

Back to [Input Database](index.md).