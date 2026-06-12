# Capacity And Stock

Capacity evolution connects existing stock, new investments, retrofits, planned decommissioning, and economic decommissioning.

## Decommissioning Stock

For each technology `t` and period `ps`:

```math
\color{#7f1d1d}{decomStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) = \color{#7f1d1d}{decomStock}(\color{#1d4ed8}{t},\color{#166534}{prev}(\color{#1d4ed8}{ps})) + \color{#166534}{decom\_plannedSel}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) + \sum_{\color{#1d4ed8}{pa}} \color{#166534}{decomMat\_NewInv}(\color{#1d4ed8}{t},\color{#1d4ed8}{pa},\color{#1d4ed8}{ps}) \left(\color{#7f1d1d}{cap\_investments}(\color{#1d4ed8}{t},\color{#1d4ed8}{pa}) + \sum_{\color{#1d4ed8}{it}} \color{#7f1d1d}{retrofitting}(\color{#1d4ed8}{it},\color{#1d4ed8}{t},\color{#1d4ed8}{pa})\right) + \color{#7f1d1d}{eco\_decommisioning}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}).
```

Symbols and indices: `t` is a technology, `ps` is the current solve period, `prev(ps)` is the preceding solve period, `pa` is a past investment period, and `it` is a retrofit source technology. `decom_plannedSel` and `decomMat_NewInv` are parameters; `decomStock`, `cap_investments`, `retrofitting`, and `eco_decommisioning` are variables.

Meaning: total decommissioned stock accumulates from planned retirements, lifetime-triggered retirement of new investments, retrofitted-in stock that later retires, and economic decommissioning.

## Technology Stock

For the first solve period:

```math
\color{#7f1d1d}{techStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps_1}) = \color{#166534}{techStock\_exist}(\color{#1d4ed8}{t}) + \color{#7f1d1d}{cap\_investments}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps_1}) + \sum_{\color{#1d4ed8}{it}} \color{#7f1d1d}{retrofitting}(\color{#1d4ed8}{it},\color{#1d4ed8}{t},\color{#1d4ed8}{ps_1}) - \sum_{\color{#1d4ed8}{jt}} \color{#7f1d1d}{retrofitting}(\color{#1d4ed8}{t},\color{#1d4ed8}{jt},\color{#1d4ed8}{ps_1}) - \color{#7f1d1d}{decomStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps_1}).
```

Symbols and indices: `ps_1` is the first solve period, `it` is a technology retrofitted into `t`, and `jt` is a technology receiving stock retrofitted out of `t`. `techStock_exist` is initial stock; all remaining terms are stock, investment, retrofit, or decommissioning variables.

For later periods:

```math
\color{#7f1d1d}{techStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) = \color{#7f1d1d}{techStock}(\color{#1d4ed8}{t},\color{#166534}{prev}(\color{#1d4ed8}{ps})) + \color{#7f1d1d}{cap\_investments}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) + \sum_{\color{#1d4ed8}{it}} \color{#7f1d1d}{retrofitting}(\color{#1d4ed8}{it},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) - \sum_{\color{#1d4ed8}{jt}} \color{#7f1d1d}{retrofitting}(\color{#1d4ed8}{t},\color{#1d4ed8}{jt},\color{#1d4ed8}{ps}) - \left(\color{#7f1d1d}{decomStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps})-\color{#7f1d1d}{decomStock}(\color{#1d4ed8}{t},\color{#166534}{prev}(\color{#1d4ed8}{ps}))\right).
```

Symbols and indices: `prev(ps)` is the preceding solve period. The difference in `decomStock` is newly decommissioned stock during `ps`; investment and retrofit variables update installed `techStock`.

Meaning: installed stock carries forward, adds new capacity and retrofits into the technology, removes retrofits out of the technology, and subtracts newly decommissioned capacity.

## Activity Stock Requirement

For driver activities, installed stock must provide the required activity volume:

```math
\sum_{\color{#1d4ed8}{t} \in \color{#1d4ed8}{T(a)}} \color{#166534}{cap2act}(\color{#1d4ed8}{t}) \; \color{#7f1d1d}{techStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) + \color{#7f1d1d}{shedSlack}(\color{#1d4ed8}{a},\color{#1d4ed8}{ps}) = \color{#166534}{activities\_netVolumes}(\color{#1d4ed8}{a},\color{#1d4ed8}{ps}).
```

Symbols and indices: `a` is a driver activity, `T(a)` is the technology subset that can satisfy it, and `ps` is a solve period. `cap2act` and `activities_netVolumes` are parameters; `techStock` and `shedSlack` are variables.

`shedSlack` is present only for technologies and workflows where shedding is allowed.

## Stock And Investment Bounds

Technology stock bounds:

```math
\color{#166534}{techStock\_min}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \le \color{#7f1d1d}{techStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \le \color{#166534}{techStock\_max}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}).
```

Symbols and indices: `techStock_min` and `techStock_max` are optional workbook bounds for technology `t` in period `ps`; `techStock` is the installed stock variable.

Investment ramp bounds:

```math
\color{#7f1d1d}{cap\_investments}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \le \color{#166534}{techChange\_max}(\color{#1d4ed8}{t}) \; \color{#166534}{period\_span}(\color{#1d4ed8}{ps}).
```

Symbols and indices: `cap_investments` is new capacity for technology `t` in period `ps`. `techChange_max` limits the annual change rate, and `period_span` converts it to the solve-period length.

Retrofit feasibility:

```math
\color{#7f1d1d}{retrofitting}(\color{#1d4ed8}{it},\color{#1d4ed8}{jt},\color{#1d4ed8}{ps}) \le \color{#166534}{retrofit\_relations}(\color{#1d4ed8}{it},\color{#1d4ed8}{jt}) \; \color{#166534}{stockAvailable}(\color{#1d4ed8}{it},\color{#166534}{prev}(\color{#1d4ed8}{ps})).
```

Symbols and indices: `it` is the source technology, `jt` is the destination technology, and `ps` is the retrofit period. `retrofit_relations` encodes allowed pathways; `stockAvailable` is the stock that can be converted.

These equations keep investment pathways physically and policy feasible across periods.

Back to [Formulation](index.md).