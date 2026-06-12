# Flexibility Archetypes

Flexibility technologies alter the timing, level, or availability of activity while respecting capacity, state, and closure limits. This page summarizes the main archetypes documented in the original IESA-Opt formulation and implemented in the Julia port.

## Shared Shift Variables

Many archetypes use paired shift channels:

```math
\color{#7f1d1d}{deltaQ\_UP}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \le 0, \qquad \color{#7f1d1d}{deltaQ\_DW}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \ge 0.
```

Symbols and indices: `i` is the active temporal index, either chronological hour `h` or cluster hour `hc`; `t` is a flexible technology; `ps` is a solve period. `deltaQ_UP` and `deltaQ_DW` are paired shift variables.

The sign convention follows the model balance equations: `UP` and `DW` are not labels for positive and negative variable bounds; they describe how activity is shifted in the system balance.

## Shedding

Shedding is a controlled shortfall or curtailment variable:

```math
\color{#7f1d1d}{deltaS\_shed}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \le 0.
```

Symbols and indices: `deltaS_shed` is the shedding variable for temporal index `i`, technology `t`, and solve period `ps`; its nonpositive sign convention makes the magnitude equal to `-deltaS_shed`.

The curtailment magnitude is `-deltaS_shed`. Bounds limit how much can be shed:

```math
\color{#7f1d1d}{deltaS\_shed}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \ge -\color{#166534}{shed\_capacity}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}),
```

Symbols and indices: `shed_capacity` is the maximum allowed shedding capacity for technology `t` in solve period `ps`; `i` identifies the hour or cluster hour where the bound applies.

```math
\color{#7f1d1d}{deltaS\_shed}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \ge -\color{#7f1d1d}{tech\_use}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{shed\_volume}(\color{#1d4ed8}{t}) \; \color{#166534}{profile}(\color{#1d4ed8}{i},\color{#1d4ed8}{t}).
```

Symbols and indices: `tech_use` is the annual activity variable, while `shed_volume` and `profile` are parameters that distribute allowable shedding over temporal index `i`.

The objective penalizes the magnitude of shedding, so shedding is a feasibility and stress-relief mechanism rather than a free resource.

## Demand Response Shifting

Demand response tracks a backlog state:

```math
\color{#7f1d1d}{B^{DR}}(\color{#1d4ed8}{i}) = \color{#7f1d1d}{B^{DR}}(\color{#166534}{prev}(\color{#1d4ed8}{i})) + \frac{\color{#7f1d1d}{deltaQ\_DW}(\color{#1d4ed8}{i})}{1-\color{#166534}{loss^{dis}}} + \color{#7f1d1d}{deltaQ\_UP}(\color{#1d4ed8}{i})(1-\color{#166534}{loss^{ch}}).
```

Symbols and indices: `B^DR` is the demand-response backlog state, `prev(i)` is the previous temporal index, and `loss^dis` and `loss^ch` are discharge and charge loss parameters. `deltaQ_DW` and `deltaQ_UP` add to or repay the backlog according to the model sign convention.

The backlog is bounded by installed stock and flexibility parameters:

```math
\color{#7f1d1d}{B^{DR}}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \le \color{#7f1d1d}{techStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{flex\_storage}(\color{#1d4ed8}{t}) \; \color{#166534}{flex\_capacity\_pct}(\color{#1d4ed8}{t}).
```

Symbols and indices: `techStock` is installed stock for flexible technology `t` in period `ps`; `flex_storage` and `flex_capacity_pct` are workbook-derived parameters that bound the backlog state.

Closure over the configured `flex_range` ensures shifted demand is recovered within the allowed horizon.

## Building Energy Shifting

Building energy shifting follows the demand-response backlog pattern, but adds comfort and anti-spike restrictions. A cumulative restoration bound prevents all deferred energy from being restored in an unrealistically short window:

```math
\sum_{\color{#1d4ed8}{i} \in \color{#1d4ed8}{q}} \color{#7f1d1d}{deltaQ\_DW}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \le \color{#166534}{limit^{BE}}(\color{#1d4ed8}{q},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}).
```

Symbols and indices: `q` is a comfort or restoration window containing temporal indices `i`. `limit^BE` is a building-energy limit parameter; `deltaQ_DW` is the restored-demand shift variable.

In time-slice mode, day-start and day-end backlog variables carry the state between representative-day operations and the calendar-day anchor.

## Storage

Storage uses a state with standing loss and charge/discharge losses:

```math
\color{#7f1d1d}{S}(\color{#1d4ed8}{i}) = (1-\color{#166534}{loss^{stand}})\color{#7f1d1d}{S}(\color{#166534}{prev}(\color{#1d4ed8}{i})) + \color{#7f1d1d}{deltaQ\_UP}(\color{#1d4ed8}{i})(1-\color{#166534}{loss^{ch}}) + \color{#7f1d1d}{deltaQ\_DW}(\color{#1d4ed8}{i}).
```

Symbols and indices: `S` is the storage state variable, `prev(i)` is the previous temporal index, and `loss^stand` and `loss^ch` are standing and charging loss parameters. `deltaQ_UP` and `deltaQ_DW` are charge and discharge-related shift variables in the model sign convention.

The state is bounded by stock, storage duration, and flexibility capacity:

```math
\color{#7f1d1d}{S}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \ge -\color{#7f1d1d}{techStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{flex\_storage}(\color{#1d4ed8}{t}) \; \color{#166534}{flex\_capacity\_pct}(\color{#1d4ed8}{t}).
```

Symbols and indices: `S` is bounded by installed `techStock` for storage technology `t`; `flex_storage` and `flex_capacity_pct` convert stock into usable storage depth.

In full-hourly mode, cyclic closure links the end of the year back to the beginning. In time-slice mode, representative-day start/end variables and calendar-day levels preserve a plausible annual storage trajectory.

## Electric Vehicles And V2G

Electric vehicles use storage logic with mobility constraints. Minimum state-of-charge reserves protect driving needs:

```math
\color{#7f1d1d}{S^{EV}}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \ge -(1-\color{#166534}{minSOC}(\color{#1d4ed8}{t})) \; \color{#7f1d1d}{techStock}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{flex\_storage}(\color{#1d4ed8}{t}) \; \color{#166534}{flex\_capacity\_pct}(\color{#1d4ed8}{t}).
```

Symbols and indices: `S^EV` is the electric-vehicle storage state. `minSOC` is the minimum state-of-charge parameter, and the remaining stock and flexibility parameters define the available storage depth.

Vehicle-to-grid export can be limited by availability and a V2G fraction:

```math
\color{#7f1d1d}{deltaQ\_DW}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \le \color{#166534}{v2gFraction}(\color{#1d4ed8}{t}) \; \color{#166534}{flex\_capacity}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{availability}(\color{#1d4ed8}{i},\color{#1d4ed8}{t}).
```

Symbols and indices: `v2gFraction`, `flex_capacity`, and `availability` are parameters limiting vehicle-to-grid discharge for technology `t` at temporal index `i` in solve period `ps`.

## CHP Flexibility

CHP flexibility links heat-use deviation and power deviation:

```math
\color{#7f1d1d}{deltaU\_CHP}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \; \color{#166534}{a^{heat}}(\color{#1d4ed8}{t}) = \color{#166534}{\eta^{CHP}}(\color{#1d4ed8}{t}) \; \frac{\color{#7f1d1d}{deltaP\_CHP}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps})}{\color{#166534}{\epsilon^{safe}}}.
```

Symbols and indices: `deltaU_CHP` and `deltaP_CHP` are CHP heat-use and power-deviation variables. `a^heat`, `eta^CHP`, and `epsilon^safe` are parameters that link the heat and power deviations for technology `t`.

Deviation and ramping are bounded:

```math
-\color{#166534}{\bar U}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \color{#166534}{\gamma^U}(\color{#1d4ed8}{t}) \le \color{#7f1d1d}{deltaU\_CHP}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \le \color{#166534}{\bar U}(\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \color{#166534}{\gamma^U}(\color{#1d4ed8}{t}),
```

Symbols and indices: `bar U` is the reference CHP use level and `gamma^U` is the allowed deviation share. The inequality bounds `deltaU_CHP` symmetrically for each temporal index `i`.

```math
\color{#7f1d1d}{deltaU\_CHP}(\color{#1d4ed8}{i},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) - \color{#7f1d1d}{deltaU\_CHP}(\color{#166534}{prev}(\color{#1d4ed8}{i}),\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) \le \color{#166534}{Ramp^{up}}(\color{#1d4ed8}{t}).
```

Symbols and indices: `prev(i)` is the previous temporal index, and `Ramp^up` is the maximum upward ramp parameter for CHP deviation variable `deltaU_CHP`.

Daily, weekly, or range constraints can enforce aggregate heat-power consistency over longer horizons.

## Network Buffers

Network buffers represent daily linepack or buffer behavior:

```math
\color{#7f1d1d}{B}(\color{#1d4ed8}{d},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) = \color{#7f1d1d}{B}(\color{#1d4ed8}{d}-1,\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) + \color{#7f1d1d}{deltaB\_UP}(\color{#1d4ed8}{d},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) + \color{#7f1d1d}{deltaB\_DW}(\color{#1d4ed8}{d},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}).
```

Symbols and indices: `d` is a calendar day, `t` is a buffer technology, and `ps` is a solve period. `B` is the buffer state; `deltaB_UP` and `deltaB_DW` are daily injection and withdrawal deviation variables.

Annual neutrality prevents the buffer from acting as net seasonal storage:

```math
\sum_{\color{#1d4ed8}{d}} \left(\color{#7f1d1d}{deltaB\_UP}(\color{#1d4ed8}{d},\color{#1d4ed8}{t},\color{#1d4ed8}{ps}) + \color{#7f1d1d}{deltaB\_DW}(\color{#1d4ed8}{d},\color{#1d4ed8}{t},\color{#1d4ed8}{ps})\right) = 0.
```

Symbols and indices: the sum runs over all calendar days `d` in solve period `ps`. Annual neutrality forces the daily buffer deviation variables to net to zero for technology `t`.

Injection, withdrawal, and storage-depth bounds are derived from installed infrastructure stock and buffer parameters.

Back to [Formulation](index.md).