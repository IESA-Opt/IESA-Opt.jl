# Sheet-by-Sheet Guide

This page describes each workbook sheet in terms of the Julia data structures it fills. It is intentionally written from the public Julia model perspective rather than from the older AIMMS implementation language.

## `IESA-Opt database`

Stores scenario metadata. The reader currently extracts the scenario description into `scenario_description`. Use it to record the purpose and provenance of a workbook.

## `Parameters`

Stores global scalar settings. The current reader uses values such as:

- `XC_TransmissionLoss_global`
- `baseload_treshold`
- `shedding_inLoad`
- `social_discount_rate`
- `base_year`
- `ActiveConstraintSet`

These values influence derived parameters, objective discounting, and selected constraints.

## `Types`

Defines controlled vocabularies used throughout the workbook:

- dispatch types
- activity types
- process types
- flexibility types
- range types
- sectors
- nodes and node names
- energy labels

Technology and activity sheets should use these labels consistently. In Julia, they become ordered index sets and lookup dictionaries.

## `NodeParameters`

Defines node-level policy and storage limits. It includes period-indexed emission target tables and cumulative quantities such as CO2 budgets and CO2 storage limits. These values feed policy constraints and emission target aggregation.

## `Activities`

Defines demand, driver, emission, material, and other activities. Important fields include:

- activity identifier
- unit
- period-indexed net volume
- maximum activity change
- dispatch type
- activity type
- node
- emission-target flag
- display label

Activities are the right-hand side and accounting backbone of many balance constraints.

## `HourlyProfiles`

Defines the hour index and profile shapes. Profiles are normalized time series used to distribute annual activity, demand, renewable availability, prices, flexibility availability, or other time-dependent signals across hours or representative-day cluster hours.

## `Technologies`

Defines the main technology universe. It includes:

- identity, sector, category, subsector, name, and units
- investment, fixed, variable, and salvage costs
- WACC, construction time, economic lifetime, and technical lifetime
- capacity-to-activity factor `cap2act`
- process type and profile type
- CHP parameters
- shedding parameters
- storage and reservoir parameters
- flexibility type, capacity, storage, range, losses, and mobility parameters
- buffer parameters
- stock, investment, use, and decommissioning bounds

Technology identifiers are reused by `EnergyBalance`, `Infrastructure`, `Retrofitting`, output tables, and model variables.

## `EnergyBalance`

Defines the coefficients linking technologies to activities. The reader stores these as `activity_balancesRef`; derived parameters then apply efficiency-learning adjustments to form `activity_balances`.

Positive and negative signs are meaningful. They determine whether a technology produces, consumes, removes, emits, or otherwise contributes to an activity.

## `Infrastructure`

Defines infrastructure assets such as network elements. The Julia reader merges infrastructure rows into the same technology dictionaries used for other technologies, while also keeping an infrastructure subset `tech_infra`. This allows infrastructure to share cost, lifetime, stock, and investment logic with technologies while using infrastructure-specific constraints.

## `PriceProfiles`

Defines hourly price trajectories for interconnected commodities. These prices are used in trade and hourly objective terms when corresponding technologies and activities are present.

## `ActGrouping`

Defines optional activity aggregation. When present, it maps original activities to grouped activities for reduced or aggregated workflows. When not used, workflows can rely directly on `Activities`.

## `EffLearning`

Defines technology-activity efficiency improvement by period. It is applied as:

```math
\color{#166534}{activity\_balances}(\color{#1d4ed8}{t},\color{#1d4ed8}{a},\color{#1d4ed8}{ps}) = \color{#166534}{activity\_balancesRef}(\color{#1d4ed8}{t},\color{#1d4ed8}{a},\color{#1d4ed8}{ps}) \times (1 - \color{#166534}{EffImprov}(\color{#1d4ed8}{t},\color{#1d4ed8}{a},\color{#1d4ed8}{ps})).
```

Symbols and indices: `t` is a technology, `a` is an activity, and `ps` is a solve period. `activity_balancesRef` is the workbook coefficient; `EffImprov` is the period-specific efficiency-improvement parameter.

## `Feedstocks`

Defines feedstock use factors by technology and feedstock. These values support material and carbon accounting where feedstock relations are active.

## `Retrofitting`

Defines allowed retrofit paths and retrofit costs from one technology to another. The Julia reader stores allowed relations by technology pair and broadcasts the input retrofit cost across configured periods.

Back to [Input Database](index.md).