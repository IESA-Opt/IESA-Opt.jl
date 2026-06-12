# Notation

IESA-Opt.jl documentation uses a consistent color convention for mathematical symbols.

| Symbol class | Color | Examples |
| --- | --- | --- |
| Decision variables and state variables | dark red | `techStock`, `tech_use`, `deltaQ_UP` |
| Input and derived parameters | dark green | `cap2act`, `inv_cost`, `clusterHourWeight` |
| Constraint family names | black | `balance_activities`, `capacity_technologies` |
| Sets, subsets, and indices | blue | `t`, `ps`, `h`, `technologies` |

The same convention is used inside equations:

```math
\color{#7f1d1d}{techStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps})
\le
\color{#166534}{techStock\_max}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}).
```

Symbols and indices: `techStock` is a variable, `techStock_max` is a parameter, `t` is a technology index, and `ps` is a solve-period index.

## Symbol Classes

| Class | Color | Examples |
| --- | --- | --- |
| Variable | dark red | `tech_use`, `techStock`, `deltaQ_UP`, `deltaS_shed` |
| Parameter | dark green | `activity_balances`, `inv_cost`, `clusterHourWeight`, `emissionTarget` |
| Constraint | black | `balance_activities`, `capacity_technologies`, `emTargetAir` |
| Set or index | blue | `technologies`, `activities`, `periods_solve`, `h` |

Back to [Formulation](index.md).