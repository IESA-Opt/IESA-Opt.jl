# Balances And Policy

Activity balances are the central accounting equations in IESA-Opt.jl. They connect technology use, hourly dispatch, flexibility deviations, CHP deviations, shedding, reservoir operation, and policy accounting through the `activity_balances` coefficients derived from the workbook.

## Annual Activity Balance

For balance activities `ab`, the annual `balance_activities` constraint is a lower bound:

```math
\sum_{\color{#1d4ed8}{tb}} \color{#166534}{activity\_balances}(\color{#1d4ed8}{tb},\color{#1d4ed8}{ab},\color{#1d4ed8}{ps}) \cdot \color{#7f1d1d}{tech\_use}(\color{#1d4ed8}{tb},\color{#1d4ed8}{ps}) + \color{#7f1d1d}{deviationTerms}(\color{#1d4ed8}{ab},\color{#1d4ed8}{ps}) \ge \color{#166534}{activities\_netVolumes}(\color{#1d4ed8}{ab},\color{#1d4ed8}{ps})
```

Symbols and indices: `tb` is a balancing technology, `ab` is a balance activity, and `ps` is a solve period. `activity_balances` and `activities_netVolumes` are parameters; `tech_use` and `deviationTerms` are variables.

Meaning: available technology activity must meet or exceed the required net activity volume.

For fixed-energy and material-conversion activities, equality is used:

```math
\sum_{\color{#1d4ed8}{tb}} \color{#166534}{activity\_balances}(\color{#1d4ed8}{tb},\color{#1d4ed8}{a},\color{#1d4ed8}{ps}) \cdot \color{#7f1d1d}{tech\_use}(\color{#1d4ed8}{tb},\color{#1d4ed8}{ps}) + \color{#7f1d1d}{deviationTerms}(\color{#1d4ed8}{a},\color{#1d4ed8}{ps}) = \color{#166534}{activities\_netVolumes}(\color{#1d4ed8}{a},\color{#1d4ed8}{ps})
```

Symbols and indices: `a` is a fixed-energy or material-conversion activity; the other symbols have the same meaning as in `balance_activities`. Equality means the activity volume must be matched exactly.

The equation type is determined by the activity classification in the workbook.

## Deviation Terms

In annual-only mode, `deviationTerms` is zero. In full-hourly and time-slice modes, it can include:

- flexible up/down shifts through `deltaQ_UP` and `deltaQ_DW`;
- CHP heat and power deviations through `deltaU_CHP` and `deltaP_CHP`;
- shedding through `deltaS_shed`;
- reservoir pump-up terms through `deltaW_UP`.

In time-slice mode, deviation terms are weighted by `clusterHourWeight(hc)`.

## Hourly Activity Balance

For hourly activities, the full-hourly equation has the form:

```math
0 = \sum_{\color{#1d4ed8}{th}} \color{#166534}{bal}(\color{#1d4ed8}{th},\color{#1d4ed8}{a},\color{#1d4ed8}{ps}) \cdot \color{#7f1d1d}{tech\_useHourly}(\color{#1d4ed8}{h},\color{#1d4ed8}{th},\color{#1d4ed8}{ps})
  + \sum_{\color{#1d4ed8}{td}} \frac{\color{#166534}{bal}(\color{#1d4ed8}{td},\color{#1d4ed8}{a},\color{#1d4ed8}{ps})}{\color{#166534}{hoursPerDay}(\color{#1d4ed8}{h})} \color{#7f1d1d}{tech\_useDaily}(\color{#1d4ed8}{d},\color{#1d4ed8}{td},\color{#1d4ed8}{ps})
  + \sum_{\color{#1d4ed8}{tp}} \color{#166534}{bal}(\color{#1d4ed8}{tp},\color{#1d4ed8}{a},\color{#1d4ed8}{ps}) \cdot \color{#166534}{profile}(\color{#1d4ed8}{h},\color{#1d4ed8}{tp}) \cdot \color{#7f1d1d}{tech\_use}(\color{#1d4ed8}{tp},\color{#1d4ed8}{ps})
  + \color{#7f1d1d}{flexTerms}(\color{#1d4ed8}{h},\color{#1d4ed8}{a},\color{#1d4ed8}{ps})
  + \color{#7f1d1d}{chpTerms}(\color{#1d4ed8}{h},\color{#1d4ed8}{a},\color{#1d4ed8}{ps})
  + \color{#7f1d1d}{shedTerms}(\color{#1d4ed8}{h},\color{#1d4ed8}{a},\color{#1d4ed8}{ps})
  + \color{#7f1d1d}{reservoirTerms}(\color{#1d4ed8}{h},\color{#1d4ed8}{a},\color{#1d4ed8}{ps})
```

Symbols and indices: `h` is a chronological hour, `d` is the calendar day containing `h`, `a` is the hourly activity, and `ps` is a solve period. `th`, `td`, and `tp` are technology subsets for hourly, daily, and profiled technologies. `bal`, `hoursPerDay`, and `profile` are parameters; `tech_useHourly`, `tech_useDaily`, `tech_use`, `flexTerms`, `chpTerms`, `shedTerms`, and `reservoirTerms` are variables or compact sums of variables.

The exact active terms depend on technology process type and flexibility type. Time-slice mode uses the same structure with `h` replaced by `hc`.

## Capacity Technology Constraint

Annual technology use is bounded by installed stock:

```math
\color{#7f1d1d}{tech\_use}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \le \color{#166534}{cap2act}(\color{#1d4ed8}{t}) \cdot \color{#7f1d1d}{techStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) + \color{#7f1d1d}{reservoirAdder}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps})
```

Symbols and indices: `t` is a technology and `ps` is a solve period. `cap2act` is a capacity-to-activity parameter; `tech_use`, `techStock`, and `reservoirAdder` are variables.

The reservoir adder appears only for reservoir technologies in temporal modes that have reservoir variables.

Technology use bounds from the workbook are also applied:

```math
\color{#166534}{techUse\_min}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \le \color{#7f1d1d}{tech\_use}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \le \color{#166534}{techUse\_max}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps})
```

Symbols and indices: `techUse_min` and `techUse_max` are optional workbook bounds for technology `t` in solve period `ps`; `tech_use` is the bounded activity variable.

## Emission Target Constraints

Emission targets are activity-balance sums over target activity subsets and nodes. A typical node-period cap is:

```math
\sum_{\color{#1d4ed8}{tb} \in \color{#1d4ed8}{node(n)}} \sum_{\color{#1d4ed8}{a} \in \color{#1d4ed8}{targetSet}} \color{#166534}{activity\_balances}(\color{#1d4ed8}{tb},\color{#1d4ed8}{a},\color{#1d4ed8}{ps}) \cdot \color{#7f1d1d}{tech\_use}(\color{#1d4ed8}{tb},\color{#1d4ed8}{ps})
 + \color{#7f1d1d}{targetDeviationTerms}(\color{#1d4ed8}{n},\color{#1d4ed8}{targetSet},\color{#1d4ed8}{ps})
 \le \color{#166534}{emissionTarget}(\color{#1d4ed8}{n},\color{#1d4ed8}{ps})
```

Symbols and indices: `n` is a node, `targetSet` is an emission-target activity subset, `tb` is a technology linked to node `n`, and `ps` is a solve period. `activity_balances` and `emissionTarget` are parameters; `tech_use` and `targetDeviationTerms` are variables or compact sums of variables.

The current baseline includes the air, bunker, and feedstock target families represented by the input workbook. The model also contains opt-in total, Scope 3, cumulative emission, and cumulative CO2 storage constraints controlled by environment switches.

## Cumulative Emission Cap

When enabled, cumulative emission accounting weights period emissions by period weight and the transition interval:

```math
\sum_{\color{#1d4ed8}{ps}} \sum_{\color{#1d4ed8}{tb},\color{#1d4ed8}{a}} \color{#166534}{activity\_balances}(\color{#1d4ed8}{tb},\color{#1d4ed8}{a},\color{#1d4ed8}{ps}) \cdot \color{#7f1d1d}{tech\_use}(\color{#1d4ed8}{tb},\color{#1d4ed8}{ps}) \cdot \color{#166534}{period\_weight}(\color{#1d4ed8}{ps}) \cdot \color{#166534}{transition\_interval} \le \color{#166534}{cumulativeBudget}
```

Symbols and indices: `ps` is a solve period, `tb` is a technology, and `a` is an emission-accounting activity. `period_weight`, `transition_interval`, and `cumulativeBudget` are parameters that turn period emissions into a transition-wide cap.

## Regulatory Policy Constraints

Additional policy constraints are implemented as opt-in constraints. They include bunker navigation and aviation targets, refinery production caps, CO2 and H2 credit accounting, ReFuelEU Aviation shares, FuelEU Maritime sector targets, and nuclear minimum-load constraints.

These constraints are not activated by default. They can be enabled with environment variables following the `IESA_POLICY_ENABLE_*` pattern used in `src/model/policy.jl`.

Back to [Formulation](index.md).