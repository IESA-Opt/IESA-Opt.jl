# Derived Parameters

After the workbook is read, IESA-Opt.jl computes derived structures needed by the model. These formulas are implemented in `src/parameters.jl`.

## Temporal Helpers

For each hour `h`, the reader derives calendar mappings such as day, week, month, season, semester, previous hour, and next hour. The previous and next hour mappings are cyclic:

```math
\color{#166534}{prev}(\color{#1d4ed8}{h_1}) = \color{#1d4ed8}{h_{last}}, \qquad \color{#166534}{next}(\color{#1d4ed8}{h_{last}}) = \color{#1d4ed8}{h_1}.
```

Symbols and indices: `h_1` is the first hour of the model year and `h_last` is the last hour. `prev` and `next` are cyclic mapping parameters.

This cyclic topology is important for storage, flexibility, and closure constraints.

## Period Weights

For solve periods `ps`, the stair period weight is:

```math
\color{#166534}{period\_weight}(\color{#1d4ed8}{ps}) =
\begin{cases}
\dfrac{\color{#166534}{next}(\color{#1d4ed8}{ps})-\color{#1d4ed8}{ps}}{\color{#166534}{last}(\color{#1d4ed8}{pss})-\color{#166534}{first}(\color{#1d4ed8}{pss})+10}, & \color{#1d4ed8}{ps} \ne \color{#166534}{last}(\color{#1d4ed8}{pss}), \\
\dfrac{10}{\color{#166534}{last}(\color{#1d4ed8}{pss})-\color{#166534}{first}(\color{#1d4ed8}{pss})+10}, & \color{#1d4ed8}{ps} = \color{#166534}{last}(\color{#1d4ed8}{pss}).
\end{cases}
```

Symbols and indices: `ps` is a solve period and `pss` is the ordered solve-period set. `period_weight`, `next`, `first`, and `last` are derived temporal parameters.

The `+10` tail follows the IESA-Opt formulation for the final period.

## Discounting And Capital Recovery

The social discount factor is:

```math
\color{#166534}{DF}(\color{#1d4ed8}{ps}) = (1+\color{#166534}{r})^{\color{#166534}{base\_year}-\color{#1d4ed8}{ps}}.
```

Symbols and indices: `DF` is the social discount factor for solve period `ps`; `r` is the social discount rate and `base_year` is the reference year.

The capital recovery factor for technology `t` is:

```math
\color{#166534}{CRF}(\color{#1d4ed8}{t}) = \frac{1 - (1+\color{#166534}{WACC_t})^{-1}}{1 - (1+\color{#166534}{WACC_t})^{-\color{#166534}{L_t}}} (1+\color{#166534}{WACC_t})^{0.5},
```

Symbols and indices: `t` is a technology, `WACC_t` is its weighted average cost of capital, and `L_t` is its economic lifetime.

where `L_t` is the economic lifetime.

## Investment And Decommissioning Matrices

The investment lifetime matrix indicates whether an investment made in period `jp` is active in period `ps`:

```math
\color{#166534}{InvMat\_lifeTime}(\color{#1d4ed8}{t},\color{#1d4ed8}{jp},\color{#1d4ed8}{ps}) =
\begin{cases}
1, & \color{#1d4ed8}{jp} \le \color{#1d4ed8}{ps} < \color{#1d4ed8}{jp} + \color{#166534}{L_t}, \\
0, & \text{otherwise}.
\end{cases}
```

Symbols and indices: `t` is a technology, `jp` is the investment period, and `ps` is the period being evaluated. `L_t` is the technology lifetime.

The decommissioning matrix marks when new investments reach the end of their technical or economic lifetime, depending on the active formulation.

## Activity Balances

Technology-activity coefficients are adjusted with efficiency improvement:

```math
\color{#166534}{activity\_balances}(\color{#1d4ed8}{t},\color{#1d4ed8}{a},\color{#1d4ed8}{ps}) = \color{#166534}{activity\_balancesRef}(\color{#1d4ed8}{t},\color{#1d4ed8}{a},\color{#1d4ed8}{ps}) \times (1 - \color{#166534}{EffImprov}(\color{#1d4ed8}{t},\color{#1d4ed8}{a},\color{#1d4ed8}{ps})).
```

Symbols and indices: `t` is a technology, `a` is an activity, and `ps` is a solve period. `activity_balancesRef` is the workbook coefficient and `EffImprov` is the efficiency-improvement parameter.

These coefficients are then used in annual, hourly, and time-slice balance equations.

## Flexibility And Shedding Capacities

Flexible capacity is derived from installed technology stock and workbook flexibility settings:

```math
\color{#166534}{flex\_capacity}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) = \color{#7f1d1d}{techStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \times \color{#166534}{flex\_capacity\_pct}(\color{#1d4ed8}{t}).
```

Symbols and indices: `flex_capacity` is a derived parameter for technology `t` and period `ps`; `techStock` is the installed stock variable and `flex_capacity_pct` is a workbook parameter.

Shedding capacity follows the same pattern:

```math
\color{#166534}{shed\_capacity}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) = \color{#7f1d1d}{techStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \times \color{#166534}{shed\_capacity\_percentage}(\color{#1d4ed8}{t}).
```

Symbols and indices: `shed_capacity` is a derived parameter for technology `t` and period `ps`; `techStock` is installed stock and `shed_capacity_percentage` is the workbook shedding share.

The exact use of these quantities depends on the flexibility archetype; see [Flexibility Archetypes](../../scientific-foundation/formulation/flexibility-archetypes.md).

Back to [Input Database](index.md).