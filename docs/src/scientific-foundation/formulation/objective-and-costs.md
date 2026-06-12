# Objective And Costs

IESA-Opt.jl minimizes discounted system cost over the selected solve periods. In compact form:

```math
\min \color{#7f1d1d}{totalCosts} = \sum_{\color{#1d4ed8}{ps}} \color{#166534}{DF}(\color{#1d4ed8}{ps}) \left(\color{#7f1d1d}{C^{capex}_{ps}} + \color{#7f1d1d}{C^{retrofit}_{ps}} + \color{#7f1d1d}{C^{salvage}_{ps}} + \color{#7f1d1d}{C^{fom}_{ps}} + \color{#7f1d1d}{C^{vom}_{ps}} + \color{#7f1d1d}{C^{trade}_{ps}} + \color{#7f1d1d}{C^{shed}_{ps}} + \color{#7f1d1d}{C^{eps}_{ps}}\right).
```

Symbols and indices: `ps` is a solve period. `DF` is the discount factor; `totalCosts` and each `C` term are objective variables or cost expressions for investment, retrofit, salvage, fixed O&M, variable O&M, trade, shedding, and epsilon tie-breaking.

## Investment Cost

Investment cost is charged over active lifetime years through `InvMat_lifeTime`:

```math
\color{#7f1d1d}{C^{capex}_{ps}} = \sum_{\color{#1d4ed8}{t},\color{#1d4ed8}{jp}} \color{#166534}{InvMat\_lifeTime}(\color{#1d4ed8}{t},\color{#1d4ed8}{jp},\color{#1d4ed8}{ps}) \; \color{#7f1d1d}{cap\_investments}(\color{#1d4ed8}{t},\color{#1d4ed8}{jp}) \; \color{#166534}{inv\_cost}(\color{#1d4ed8}{t},\color{#1d4ed8}{jp}) \; \color{#166534}{CRF}(\color{#1d4ed8}{t}).
```

Symbols and indices: `t` is a technology, `jp` is the investment period, and `ps` is the period being costed. `InvMat_lifeTime`, `inv_cost`, and `CRF` are parameters; `cap_investments` is the investment variable.

Meaning: a capacity investment made in period `jp` contributes to cost in period `ps` while it is active.

## Retrofit Cost

Retrofit decisions convert stock from one technology to another:

```math
\color{#7f1d1d}{C^{retrofit}_{ps}} = \sum_{\color{#1d4ed8}{it},\color{#1d4ed8}{t}} \color{#7f1d1d}{retrofitting}(\color{#1d4ed8}{it},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{retrofit\_cost}(\color{#1d4ed8}{it},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{CRF}(\color{#1d4ed8}{t}) \; \color{#166534}{W^{life}}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}).
```

Symbols and indices: `it` is the source technology, `t` is the destination technology, and `ps` is the retrofit period. `retrofit_cost`, `CRF`, and `W^life` are parameters; `retrofitting` is the retrofit variable.

`W^life` represents the lifetime weighting induced by `InvMat_lifeTime`.

## Salvage Value

Salvage is a negative cost associated with economic decommissioning:

```math
\color{#7f1d1d}{C^{salvage}_{ps}} = -\sum_{\color{#1d4ed8}{t}} \Delta \color{#7f1d1d}{eco\_decommisioning}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{Salvage\_value}(\color{#1d4ed8}{t}) \; \color{#166534}{inv\_cost}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{CRF}(\color{#1d4ed8}{t}).
```

Symbols and indices: `t` is a technology and `ps` is a solve period. `Delta eco_decommisioning` is newly economic-decommissioned stock; `Salvage_value`, `inv_cost`, and `CRF` are parameters. The negative sign makes salvage reduce total cost.

## Fixed And Variable Costs

```math
\color{#7f1d1d}{C^{fom}_{ps}} = \sum_{\color{#1d4ed8}{t}} \color{#7f1d1d}{techStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{fom\_cost}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}),
```

Symbols and indices: `techStock` is installed stock for technology `t` in period `ps`; `fom_cost` is the fixed O&M cost parameter.

```math
\color{#7f1d1d}{C^{vom}_{ps}} = \sum_{\color{#1d4ed8}{t}} \color{#7f1d1d}{tech\_use}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{vom\_cost}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}).
```

Symbols and indices: `tech_use` is annual technology activity for technology `t` in period `ps`; `vom_cost` is the variable O&M cost parameter.

In hourly and time-slice modes, additional variable-cost terms are added for hourly dispatch, CHP deviations, trade, shedding, and flexibility variables.

## Shedding Penalty

Shedding variables are nonpositive in the model. Their magnitude is penalized:

```math
\color{#7f1d1d}{C^{shed}_{ps}} = \sum_{\color{#1d4ed8}{h},\color{#1d4ed8}{t}} -\color{#7f1d1d}{deltaS\_shed}(\color{#1d4ed8}{h},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{shed\_penalty}(\color{#1d4ed8}{t}).
```

Symbols and indices: `h` is a chronological hour, `t` is a shedding technology, and `ps` is a solve period. `deltaS_shed` is nonpositive, so `-deltaS_shed` is the shed quantity; `shed_penalty` is the penalty parameter.

In time-slice mode, hourly terms are multiplied by the cluster-hour weight:

```math
\color{#7f1d1d}{C^{shed,TS}_{ps}} = \sum_{\color{#1d4ed8}{hc},\color{#1d4ed8}{t}} -\color{#166534}{clusterHourWeight}(\color{#1d4ed8}{hc}) \; \color{#7f1d1d}{deltaS\_shed\_TS}(\color{#1d4ed8}{hc},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{shed\_penalty}(\color{#1d4ed8}{t}).
```

Symbols and indices: `hc` is a representative cluster hour. `clusterHourWeight` converts the cluster-hour shedding variable `deltaS_shed_TS` to its annual weighted contribution.

## Epsilon Tie-Breaker

Small `p_epsilon` terms discourage artificial cycling and help select stable solutions among degenerate optima:

```math
\color{#7f1d1d}{C^{eps}_{ps}} = \color{#166534}{p_\epsilon} \sum_{\color{#1d4ed8}{h},\color{#1d4ed8}{t}} \left(\color{#7f1d1d}{deltaQ\_DW}(\color{#1d4ed8}{h},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) - \color{#7f1d1d}{deltaQ\_UP}(\color{#1d4ed8}{h},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) - \color{#7f1d1d}{deltaS\_shed}(\color{#1d4ed8}{h},\color{#1d4ed8}{t},\color{#1d4ed8}{ps})\right).
```

Symbols and indices: `p_epsilon` is a small parameter. `deltaQ_DW`, `deltaQ_UP`, and `deltaS_shed` are flexibility and shedding variables indexed by hour `h`, technology `t`, and solve period `ps`.

These terms are intentionally small relative to real system costs.

Back to [Formulation](index.md).