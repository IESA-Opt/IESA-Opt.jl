# Temporal Representation

IESA-Opt.jl supports annual, full-hourly, and representative-day time-slice workflows. The same stock, balance, objective, and flexibility logic is used across modes, but the temporal index and weighting differ.

## Full-Hourly Mode

Full-hourly mode uses chronological hours `h` across the model year. A generic state evolves as:

```math
\color{#7f1d1d}{X}(\color{#1d4ed8}{h}) = \color{#7f1d1d}{X}(\color{#166534}{prev}(\color{#1d4ed8}{h})) + \color{#7f1d1d}{inflow}(\color{#1d4ed8}{h}) - \color{#7f1d1d}{outflow}(\color{#1d4ed8}{h}).
```

Symbols and indices: `h` is a chronological hour and `prev(h)` is the preceding hour. `X`, `inflow`, and `outflow` are generic state or flow variables used to describe storage and flexibility recursions.

Because `prev(h_1)` equals `h_last`, state equations can close cyclically over the year.

Hourly activity balances use hourly profiles directly:

```math
\sum_{\color{#1d4ed8}{t}} \color{#166534}{activity\_balances}(\color{#1d4ed8}{t},\color{#1d4ed8}{a},\color{#1d4ed8}{ps}) \; \color{#7f1d1d}{tech\_useHourly}(\color{#1d4ed8}{h},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) + \color{#7f1d1d}{flexTerms}(\color{#1d4ed8}{h},\color{#1d4ed8}{a},\color{#1d4ed8}{ps}) = \color{#166534}{demand}(\color{#1d4ed8}{h},\color{#1d4ed8}{a},\color{#1d4ed8}{ps}).
```

Symbols and indices: `h` is a chronological hour, `t` is a technology, `a` is an activity, and `ps` is a solve period. `activity_balances` and `demand` are parameters; `tech_useHourly` and `flexTerms` are variables or compact sums of variables.

## Representative-Day Time-Slice Mode

Time-slice mode replaces chronological hours with cluster hours `hc`. Each `hc` has a weight `clusterHourWeight(hc)` that represents how many real hours it stands for.

Annual consistency is preserved by weighted sums:

```math
\sum_{\color{#1d4ed8}{hc}} \color{#166534}{clusterHourWeight}(\color{#1d4ed8}{hc}) \; \color{#7f1d1d}{f}(\color{#1d4ed8}{hc}) \approx \sum_{\color{#1d4ed8}{h}} \color{#7f1d1d}{f}(\color{#1d4ed8}{h}).
```

Symbols and indices: `hc` is a cluster hour and `h` is a chronological hour. `clusterHourWeight` is the parameter that maps a representative-hour value `f(hc)` to its annual equivalent.

Hourly balances and objective terms use the same structure as full-hourly mode, but with `h` replaced by `hc` and with weights in annual or cost aggregations.

## Representative-Day Storage Anchor

Representative days are not a chronological sequence. Storage and long-duration flexibility therefore need a calendar-day anchor. IESA-Opt.jl uses representative-day start/end variables and calendar-day levels:

```math
\color{#7f1d1d}{dayEnd}(\color{#1d4ed8}{rd},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) = \color{#7f1d1d}{dayStart}(\color{#1d4ed8}{rd},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) + \color{#7f1d1d}{netStateChange}(\color{#1d4ed8}{rd},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}),
```

Symbols and indices: `rd` is a representative day, `t` is a storage or flexibility technology, and `ps` is a solve period. `dayStart`, `dayEnd`, and `netStateChange` are variables or compact state-change expressions for the representative day.

```math
\color{#7f1d1d}{calLevel}(\color{#1d4ed8}{d},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) = (1-\color{#166534}{\lambda})^{24} \color{#7f1d1d}{calLevel}(\color{#1d4ed8}{d}-1,\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) + \sum_{\color{#1d4ed8}{rd}} \color{#166534}{dayMixWeight}(\color{#1d4ed8}{d},\color{#1d4ed8}{rd}) \left(\color{#7f1d1d}{dayEnd}(\color{#1d4ed8}{rd},\color{#1d4ed8}{t},\color{#1d4ed8}{ps})-\color{#7f1d1d}{dayStart}(\color{#1d4ed8}{rd},\color{#1d4ed8}{t},\color{#1d4ed8}{ps})\right).
```

Symbols and indices: `d` is a calendar day and `rd` is a representative day. `lambda` is the daily standing-loss parameter, `dayMixWeight` maps calendar days to representative days, and `calLevel`, `dayEnd`, and `dayStart` are state variables.

Meaning: representative-day operations are embedded back into a 365-day calendar trajectory so seasonal storage and long-duration flexibility cannot create or lose energy through clustering.

## Extreme Days And Capacity Profiles

The older IESA-Opt time-slice documentation describes a medoid-envelope blend workflow. The principle is:

- energy balances use representative profiles that preserve annual energy;
- capacity and stress constraints can use a more conservative capacity-bound profile;
- extreme days can be forced into the representative-day set with weight 1;
- blended profiles balance runtime reduction with stress-condition coverage.

In Julia workflows, clustering outputs such as cluster maps, cluster weights, representative-day profiles, and capacity profiles are consumed by the time-slice model builder.

## Mode Selection

| Mode | Use when | Trade-off |
| --- | --- | --- |
| Annual | Screening or debugging annual structure. | No hourly dispatch detail. |
| Full-hourly | Benchmarking or studies requiring chronological detail. | Largest model. |
| Time-slice | Scenario sweeps and production runs where representative days are acceptable. | Requires careful interpretation of weighted outputs and storage anchors. |

Back to [Formulation](index.md).