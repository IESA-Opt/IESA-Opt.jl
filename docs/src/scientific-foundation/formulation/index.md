# Formulation

This section documents the main mathematical families used by IESA-Opt.jl. The notation follows the Julia implementation while preserving the meaning of the original IESA-Opt formulation.

## Symbol Colors

The formulation pages use the [notation color convention](notation.md):

| Symbol class | Color |
| --- | --- |
| Variables and state variables | dark red |
| Parameters and derived parameters | dark green |
| Constraint family names | black |
| Sets, subsets, and indices | blue |

## Index Sets

Common indices are:

| Symbol | Meaning |
| --- | --- |
| `t` | technology |
| `a` | activity |
| `ps` | solve period |
| `h` | chronological hour in full-hourly mode |
| `d` | calendar day |
| `rd` | representative day |
| `hc` | cluster hour in time-slice mode |

## Core State Pattern

Most flexibility formulations use a state equation:

```math
\color{#7f1d1d}{X_i} = \color{#7f1d1d}{X_{prev(i)}} + \color{#7f1d1d}{inflow_i} - \color{#7f1d1d}{outflow_i}.
```

Symbols and indices: `i` is the active temporal index. `X_i` is a generic state variable, while `inflow_i` and `outflow_i` are flow variables affecting that state.

When losses are present:

```math
\color{#7f1d1d}{X_i} = (1-\color{#166534}{\lambda})\color{#7f1d1d}{X_{prev(i)}} + \color{#166534}{\eta^{in}}\color{#7f1d1d}{inflow_i} - \frac{\color{#7f1d1d}{outflow_i}}{\color{#166534}{\eta^{out}}}.
```

Symbols and indices: `lambda` is a standing-loss parameter, and `eta^in` and `eta^out` are input and output efficiency parameters. The state and flow terms are variables indexed by `i`.

The state may close daily, over a flexibility range, annually, or through a representative-day calendar anchor. The closure prevents unresolved backlog, artificial energy creation, or unbounded temporal shifting.

## Pages

- [Objective and Costs](objective-and-costs.md)
- [Notation](notation.md)
- [Balances and Policy](balances-and-policy.md)
- [Capacity and Stock](capacity-and-stock.md)
- [Temporal Representation](temporal-representation.md)
- [Flexibility Archetypes](flexibility-archetypes.md)

Back to the [documentation home](../../index.md) or the [repository README](https://github.com/IESA-Opt/IESA-Opt.jl#readme).