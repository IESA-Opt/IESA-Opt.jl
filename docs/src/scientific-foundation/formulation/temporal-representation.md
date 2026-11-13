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

Annual quantities are approximated by weighted sums:

```math
\sum_{\color{#1d4ed8}{hc}} \color{#166534}{clusterHourWeight}(\color{#1d4ed8}{hc}) \; \color{#7f1d1d}{f}(\color{#1d4ed8}{hc}) \approx \sum_{\color{#1d4ed8}{h}} \color{#7f1d1d}{f}(\color{#1d4ed8}{h}).
```

Symbols and indices: `hc` is a cluster hour and `h` is a chronological hour. `clusterHourWeight` is the parameter that maps a representative-hour value `f(hc)` to its annual equivalent.

Hourly balances and objective terms use the same structure as full-hourly mode, but with `h` replaced by `hc` and with weights in annual or cost aggregations.

## Representative-Day Storage Anchor

Battery losses follow the supplied AIMMS `flex_losses` convention: one round-trip loss `L`. With nonpositive charging variable `UP`, nonnegative discharge `DW`, and nonpositive stored-energy state `S`, the chronological state balance is `S(h) = S(h-1) + (1-L)*UP(h) + DW(h)`. Each applicable flexibility window closes with `sum(UP + DW/(1-L)) = 0`. These are equivalent energy balances, not separate charging and discharge losses.

Representative days are not a chronological sequence. Storage and long-duration flexibility therefore need a calendar-day anchor. IESA-Opt.jl uses representative-day start/end variables and calendar-day levels:

```math
\color{#7f1d1d}{dayEnd}(\color{#1d4ed8}{rd},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) = (1-\color{#166534}{\lambda})^{24}\color{#7f1d1d}{dayStart}(\color{#1d4ed8}{rd},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) + \color{#7f1d1d}{netStateChange}(\color{#1d4ed8}{rd},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}),
```

Symbols and indices: `rd` is a representative day, `t` is a storage or flexibility technology, and `ps` is a solve period. `dayStart`, `dayEnd`, and `netStateChange` are variables or compact state-change expressions for the representative day.

```math
\color{#7f1d1d}{calLevel}(\color{#1d4ed8}{d},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) = (1-\color{#166534}{\lambda})^{24} \color{#7f1d1d}{calLevel}(\color{#1d4ed8}{d}-1,\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) + \sum_{\color{#1d4ed8}{rd}} \color{#166534}{dayMixWeight}(\color{#1d4ed8}{d},\color{#1d4ed8}{rd}) \left(\color{#7f1d1d}{dayEnd}(\color{#1d4ed8}{rd},\color{#1d4ed8}{t},\color{#1d4ed8}{ps})-(1-\color{#166534}{\lambda})^{24}\color{#7f1d1d}{dayStart}(\color{#1d4ed8}{rd},\color{#1d4ed8}{t},\color{#1d4ed8}{ps})\right).
```

Symbols and indices: `d` is a calendar day and `rd` is a representative day. `lambda` is the hourly standing-loss fraction (zero for the supplied AIMMS convention), `dayMixWeight` maps calendar days to representative days, and `calLevel`, `dayEnd`, and `dayStart` are state variables.

Battery start levels are anchored to the weighted preceding calendar-day levels. The reconstructed battery state is constrained between zero and installed energy capacity at every calendar-day intraday slot, not only at day ends; EV availability limits are also applied. An identity day map reproduces chronological battery cycling instead of resetting storage to zero at midnight. This calendar construction is a Julia representative-day adaptation, not a representative-day feature of the supplied AIMMS source.

Results generated before the storage-loss and calendar-link corrections must be rerun before comparing temporal methods. In particular, the previous zero-battery full-hour result is not a valid reference for evaluating storage investment.

EV flexibility follows the supplied AIMMS driving-availability and future-journey terms. The default adds neither a separate 20% SOC reserve nor an 80% V2G power multiplier; those parameters remain available for explicit custom studies. In time-slice mode, future-journey requirements are reconstructed on the weighted calendar and projected back to representative days. Demand shifting uses the AIMMS cumulative and time-window bounds without the additional Julia backlog-state variables and closures.

## Selecting Representative Days

Representative days are selected with [TulipaClustering.jl](https://github.com/TulipaEnergy/TulipaClustering.jl), following the approach used by TulipaEnergyModel.jl:

- Split the 8760-hour year into 365 daily periods. Include all hourly profiles and interconnector price series, normalizing each series by its maximum absolute value before clustering and restoring its original units afterwards.
- Select `clustering_approach`: `:k_medoids` (default) or `:k_means`. Select `clustering_distance`: `:cosine` (default), `:euclidean`, or `:sqeuclidean`.
- Fit `dayMix_weightType`: `:convex` (default via `:auto`), `:conical`, `:conical_bounded`, or `:dirac` (one representative per calendar day). `clustering_seed` controls reproducibility of k-means and k-medoids.

The fitted weights populate `dayMix_weight[(d, rd)]`. `dayWeight[rd]` is their sum over calendar days; `clusterHourWeight[hc] = dayWeight[rd] * 24 / hoursPer_day_cluster`. Convex weights sum to one per calendar day, giving 365 represented days and 8760 represented hours. Conical weights need not have these totals. Calendar-range, week, month, season, and semester storage balances use the same fitted weights, not just the dominant representative-day assignment.

Each representative day uses one profile for energy and capacity constraints; the old medoid/envelope/capacity-profile variants are no longer generated. For coarser intraday resolution, `hoursPer_day_cluster` must divide 24 and adjacent hourly values are averaged. Full-hourly and annual modes are unchanged.

Representative days and fitted weights do not reproduce annual totals on their own; the shortfall can be about 1%. Each clustered hourly profile is therefore multiplied by one constant factor so that `Σ_hc clusterHourWeight(hc) · profile(hc)` equals the 8760-hour total. Without this, the exact annual-hourly balance equalities can make fixed hourly demands or supplies infeasible. The factor preserves each representative day's shape but can change its peak by the same percentage. Interconnector prices are not rescaled.

There is no separate forced extreme-day step. A small representative set does not guarantee inclusion of every peak-load or low-renewable event. Benchmark important scenarios against higher temporal resolution.

The UI defaults to k-medoids clustering in Single Run, Scenario Space, and MGA. Scenario Space carries the selected day count and method through preparation and resume. Hull methods (`:convex_hull`, `:convex_hull_with_null`, `:conical_hull`) and legacy names such as `:kmeans_avg` are rejected. `ts_extremePeriods=true` emits a warning and has no effect. Existing input caches are invalidated automatically for the new parameter layout.

Run configurations record `clusteringDistance` (cosine by default); the API can override it.

`external_clusterMap_path` remains available for validation against an IESA-Opt 1.0 day map. It bypasses Tulipa selection, uses hard assignments, and averages the mapped member-day profiles.

## Mode Selection

| Mode | Use when | Trade-off |
| --- | --- | --- |
| Annual | Screening or debugging annual structure. | No hourly dispatch detail. |
| Full-hourly | Benchmarking or studies requiring chronological detail. | Largest model. |
| Time-slice | Scenario sweeps and production runs where representative days are acceptable. | Requires careful interpretation of weighted outputs and storage anchors. |

Back to [Formulation](index.md).