# Scenario-Space Exploration

The scenario-space subsystem lets you take one base [`ModelData`](@ref) and
sweep, sample, or grid-search over many variants of it in a single
campaign. Each variant solves a slightly different LP; the runner returns a
table of objectives + leaf values + solver diagnostics that you can save to
DuckDB or CSV and post-process with the bundled analysis helpers.

The local UI adds an **Analysis** sheet to Scenario Space campaigns. It reads
completed campaign results and provides two first-pass diagnostics:

- **Scenario Discovery (PRIM-style).** The UI treats the lowest-cost quartile
    as the outcome of interest, then reports parameter boxes with density,
    coverage, mass, and mean system cost. These boxes are intended to identify
    compact regions of the sampled parameter space that repeatedly produce low
    system cost.
- **Global sensitivity analysis.** The UI ranks sampled inputs by Spearman
    rank correlation against system cost and CO2 price. This is sampling-method
    agnostic and works with LHS, Sobol, Morris, and factorial campaigns; later
    method-specific indices can be linked to the sampler metadata.

For analysis to work, run a new campaign after the Analysis feature is
available so each result row includes both objective outputs and sampled
parameter values.

This page is a tour from "I want to vary one parameter" all the way through
"I want to do a 1 000-point Sobol scan over five profile assumptions on a
24-core machine". Read the sections in order on a first pass; come back to
individual ones as reference.

## Why this exists

The model build itself (`build_ts_lp!` / `build_fh_lp!` / `build_annual_lp!`)
dominates wall-clock time for medium- and large-instance runs. Re-running it
from scratch for every variant of a sensitivity sweep wastes most of that
time on identical work. The scenario subsystem builds the LP **once** per
*cluster group* (see [Per-variant clustering](#per-variant-clustering)) and
then mutates only the bits of the model that the variant actually changed
— typically constraint right-hand sides or objective coefficients —
between solves. On HiGHS that gives you full warm-starts; on Gurobi with
the barrier-with-crossover preset, ditto.

A typical 50-variant scalar-only sweep on the medium 24-hour fixture runs
~10× faster through `run_campaign` than 50 cold `run_iesa_opt()` calls.

## Mental model

There are five layers, in order from highest to lowest abstraction:

| Layer | Type / function | What it does |
|---|---|---|
| 1. *Spec* | [`ScenarioSpec`](@ref) | "I want to vary these leaves, in these ranges, using this sampler." |
| 2. *Samples* | matrix returned by [`sample_scenario_space`](@ref) | Numeric values that come out of the sampler — one row per variant. |
| 3. *Changes* | `Vector{Vector{LeafChange}}` from [`samples_to_changes`](@ref) | Sample rows reshaped into per-variant `LeafChange` lists. |
| 4. *Campaign* | [`run_campaign`](@ref) | Group, build, mutate, solve, collect. Where all the speed is. |
| 5. *Results* | `ScenarioResult` ↔ DuckDB/CSV | Persist, reload, analyse with [`objective_table`](@ref), [`sensitivity_scan`](@ref), [`pareto_front`](@ref). |

`run_scenario_space` glues layers 1-5 together with one call.

## Quick start — vary two scalars

The simplest possible campaign: vary the CO2 price across NL,2050 and a
single bunker-fuels emission target.

```julia
using IESAOpt

# 1. Read base data
md = read_model_data("data/IESA_NL_24h_2050.xlsx")
derive_sets!(md)
compute_derived_params!(md)
build_temporal_clusters!(md)   # required for :ts mode

# 2. Declare what to vary
spec = ScenarioSpec(
    targets = [
        LeafTarget(field = :price_carbon,        indices = (:NL, 2050), lower = 50.0,  upper = 200.0),
        LeafTarget(field = :emissionTargetBunker, indices = (:NL, 2050), lower = 0.5,   upper = 1.2),
    ],
    n_variants = 16,
    sampler    = :lhs,        # :lhs | :sobol | :grid | :custom
    seed       = 42,          # only used by :lhs / :sobol
)

# 3. Run + persist
result = run_scenario_space(
    md, spec;
    mode      = :ts,
    solver    = :highs,
    n_workers = 0,            # 0 = serial; >=2 = Distributed
    threads_per_worker = 4,
)

save_scenario_results("Output/my_campaign.duckdb", result)   # DuckDB
# save_scenario_results("Output/my_campaign", result; format = :csv)  # CSV alt.

# 4. Analyse
df_obj = objective_table(result)         # variant_id | objective | term_status | …
df_sens = sensitivity_scan(result)       # one row per target with rank-corr
pareto  = pareto_front(result, :price_carbon, :objective; minimize = true)
```

That is the entire happy path. The remaining sections explain what each
knob does, when to reach for it, and where the not-obvious gotchas live.

## Core types

### `LeafTarget`

A *target* says "this single (`field`, `indices`) pair varies between
`lower` and `upper`". `field` is a `Symbol` matching a key in `md.params`
(e.g. `:price_carbon`, `:emissionTargetBunker`, `:hourly_profilesReadOrig`).
`indices` is the tuple that selects the specific entry — typically
`(:region, :year)` for scalars, `(:profile_name, :hour)` for profile
leaves.

```julia
LeafTarget(field = :price_carbon, indices = (:NL, 2050), lower = 50.0, upper = 200.0)
```

The sampler treats `(lower, upper)` as a uniform interval. To sample
log-uniformly, sample `:lhs` on `log(lower)..log(upper)` and apply
`exp()` in a post-processing step (or use `:custom` samples — see below).

### `ScenarioSpec`

Bundles targets + sample size + sampler choice + RNG seed. Validation
happens at construction time: targets cannot be empty, names must be
unique, `lower <= upper`.

### `LeafChange`

The struct the runner actually applies to the model. You usually don't
construct these by hand — `samples_to_changes` does it for you — but the
constructor is public:

```julia
LeafChange(field = :price_carbon, indices = (:NL, 2050), value = 137.5)             # default type = :set
LeafChange(field = :hourly_avail, indices = (:wind_nl, 1), value = 0.9, type = :multiply)
```

`:set` overwrites the param value; `:multiply` multiplies it by `value`.
**Note**: `:multiply` *compounds* if applied twice — the runner is careful
never to do that, but you should be too when writing custom builders.

### `VariantResult`

What a single solve returns. Important fields:

| Field | Meaning |
|---|---|
| `variant_id::Int` | 1-based index into the campaign |
| `objective::Float64` | `NaN` if not optimal |
| `term_status::String` | `"OPTIMAL"`, `"INFEASIBLE"`, `"ERROR"`, `"CANCELLED"`, … |
| `primal_status::String` | `"FEASIBLE_POINT"` etc. |
| `leaf_values::Vector{Float64}` | Effective values applied, in spec.targets order |
| `build_seconds` | Time spent in `_build_campaign_model` (>0 only on cache-miss variants) |
| `apply_seconds` | Time spent in `apply_variant!` |
| `solve_seconds` | Time spent in `optimize!` |
| `worker_pid::Int` | Distributed worker that ran this variant (1 = master / serial) |
| `error::Union{Nothing,String}` | Stringified exception if solve threw |

### `ScenarioResult`

What a campaign returns:

| Field | Meaning |
|---|---|
| `spec::ScenarioSpec` | The spec used to launch the campaign |
| `samples::Matrix{Float64}` | One row per variant, one column per target |
| `variants::Vector{VariantResult}` | Per-variant solver output |
| `runtime_seconds::Float64` | Wall-clock for the whole campaign |
| `created_at::DateTime` | UTC |

## Samplers

Set `spec.sampler` to one of:

| `sampler` | Notes | When to use |
|---|---|---|
| `:lhs` | Latin Hypercube. Good space-filling for small N. Uses `Random.MersenneTwister(seed)`. | Default for sensitivity / sweep. |
| `:sobol` | Quasi-random low-discrepancy via `Sobol.jl`. Better convergence for high N. | Convergence studies, surrogate model training. |
| `:grid` | Full Cartesian grid. `n_variants` is ignored — you get `∏ levels` variants. Currently 3 levels per axis. | 2-3 axis grid plots. |
| `:custom` | Bring-your-own samples matrix. Use `sample_scenario_space(spec; custom = mymatrix)` and then `samples_to_changes(spec, mymatrix)` and pass the result to `run_campaign` directly. | Reproducible scientific scans, log-uniform / mixed distributions, OAT (one-at-a-time). |

`sample_scenario_space(spec)` returns the matrix; `samples_to_changes(spec, samples)` turns each row into a `Vector{LeafChange}`.

## Running a campaign

`run_scenario_space` is the one-call wrapper. If you want more control,
call the pieces directly:

```julia
samples = sample_scenario_space(spec)
changes_per_variant = samples_to_changes(spec, samples)

variants = run_campaign(md, changes_per_variant;
    solver = :highs,                    # :highs | :gurobi
    solver_attrs = Dict{String,Any}(),  # e.g. Dict("Method"=>2, "Crossover"=>-1) for Gurobi barrier
    threads_per_worker = 4,
    n_workers = 0,
    mode = :ts,                         # :ts | :fh | :annual
    cancel = Ref(false),                # set to true from another task to halt early
    on_progress = noop_callback,
    on_result   = noop_callback,
)
```

When `solver = :gurobi` and `mode = :ts`, scenario-space uses the same
representative-day tuned Gurobi defaults as single runs. Those defaults are
selected from `md.params.n_repDays`; entries in `solver_attrs` still take
precedence for experiments that need explicit solver settings.

### Serial vs Distributed

| `n_workers` | Path | What happens |
|---|---|---|
| `0` or `1` | Serial | One LP build, in-process. Best for ≤ ~10 variants or when you want easy debugging. |
| `≥ 2` | Distributed | `addprocs(n_workers)` once, each worker loads the package + keeps a per-process cluster cache, master dispatches variants over a bounded `RemoteChannel`. |

Distributed mode pays a fixed cost (`addprocs` + `@everywhere using IESAOpt` ~10–20 s) and one LP build per worker per cluster group. Crossover happens when `n_variants × build_time_share` exceeds that startup cost — typically around 6–8 variants on the 24-hour fixture.

The benchmark script `scripts/scenario_benchmark.jl` runs WORKER_COUNTS ∈ {0, 2, 4} on a deterministic 12-variant LHS and writes `Output/scenario_benchmark.csv` so you can pick a sensible default for your hardware.

### Cancellation + progress callbacks

```julia
cancel = Ref(false)
@async (sleep(60); cancel[] = true)   # cap the campaign at 60 s
on_progress = ev -> ev.stage == "done" && println("done $(ev.variant_id)/$(ev.total)")
result = run_scenario_space(md, spec;
    cancel = cancel, on_progress = on_progress)
```

The runner checks `cancel[]` between variants (serial) or between channel
takes (Distributed). In-flight solves are NOT interrupted.

## Per-variant clustering

This is the Phase 3.5 feature and it is opt-in. Read this section before
you sweep over any *profile* leaf (`hourly_profilesReadOrig`, demand
profiles, weather slices, …).

### The problem

`build_temporal_clusters!` decides the representative days from the
**read** profiles in `md.params.hourly_profilesReadOrig`. Once the LP is
built from those cluster days, the time index, weights, and medoids are
baked in. If a variant mutates a profile leaf, the cluster assignment
becomes wrong for that variant — and worse, `apply_variant!` can't fix it,
because the *structure* of the LP would have to change (different rep days
→ different hour-index set).

Mutating a scalar leaf (price, cap, emission target) is fine: the LP's
constraint set is unchanged and only RHS / coefficient values move.
Mutating a profile leaf is not.

### The fix

Phase 3.5 introduces a *clustering-affecting registry*. You tag the
profile leaves that, when mutated, require a re-cluster + LP rebuild. The
runner then:

1. Computes a `cluster_cache_key` for each variant (a sorted tuple of the
   variant's clustering-affecting `(field, indices, value, type)` entries).
2. Partitions variants by that key. Variants with no profile mutation all
   hash to `()` and land in a single group — same as Phase 3.
3. Builds one `(md_template, model)` per *group* (one cluster step + one
   LP build per group), then warm-applies each variant's scalar remainder
   on the shared model.

If `N` variants draw from only `K` unique profile sets, you pay `K`
cluster + LP builds instead of `N`. The fast path is preserved bit-for-bit
when no leaves are tagged.

### The registry API

```julia
register_clustering_affecting!(:hourly_profilesReadOrig)   # opt in
is_clustering_affecting(:hourly_profilesReadOrig)          # → true
clustering_affecting_fields()                              # → [:hourly_profilesReadOrig]
unregister_clustering_affecting!(:hourly_profilesReadOrig) # opt out (returns true if was present)
variant_affects_clustering([ch1, ch2])                     # → true iff any ch.field is tagged
```

The registry is module-global and idempotent. Register once at campaign
setup time:

```julia
register_clustering_affecting!(:hourly_profilesReadOrig)

spec = ScenarioSpec(
    targets = [
        LeafTarget(field = :hourly_profilesReadOrig, indices = (:wind_nl, 1), lower = 0.4, upper = 1.0),
        LeafTarget(field = :price_carbon,            indices = (:NL, 2050),    lower = 50.0, upper = 200.0),
    ],
    n_variants = 24, sampler = :lhs, seed = 1,
)
result = run_scenario_space(md, spec; mode = :ts, solver = :highs, n_workers = 4)
```

In the example above the wind profile entry varies continuously, so each
LHS row produces a unique cluster key → 24 groups → 24 cluster builds.
That defeats the cache. The cache shines when you sample profile leaves
on a small **discrete** set:

```julia
# 5 wind years × 3 carbon prices = 15 variants, 5 cluster builds
custom = [
    [wind_year, price_co2]
    for wind_year in (2005.0, 2010.0, 2015.0, 2018.0, 2022.0)
    for price_co2  in (75.0, 125.0, 200.0)
]
samples = reduce(hcat, custom)'           # 15×2 matrix
changes = samples_to_changes(spec, samples)
result  = run_campaign(md, changes;
    solver = :gurobi, mode = :ts, n_workers = 4, threads_per_worker = 4)
```

### Custom mutation builders for profile leaves

Tagging only tells the runner "re-cluster + rebuild". It does NOT tell it
how to write the new value into `md.params`. For scalar leaves that work
is done automatically by `apply_leaf_change!` (a simple `dict[k] = v`).
For profile leaves the existing `apply_leaf_change!` *also* just writes
into the dict — that part is fine — but you should think carefully about
what "set a single hour of a profile" means semantically. If you instead
want to swap whole profile vectors per variant, write a small builder:

```julia
function _apply_wind_year(md, indices, year::Float64)
    yr = Int(year)
    src = md.params.hourly_profilesAllYears[(:wind_nl, yr)]
    md.params.hourly_profilesReadOrig[(:wind_nl, h)] = src for h in 1:8760
    return Mutation[]   # no direct LP mutation — clustering handles it
end
register_mutation!(:wind_year, _apply_wind_year)
register_clustering_affecting!(:wind_year)
```

Pattern: a profile leaf that ONLY affects clustering can return
`Mutation[]` from its builder — the cluster rebuild does all the work. A
profile leaf that also feeds the LP directly (rare) should return the
appropriate `Mutation` objects too.

## Custom mutation builders for scalar leaves

The defaults registered by `_register_default_mutations!` cover emission
caps + a handful of common scalar leaves. To add support for a new scalar
field, register a builder that returns `Vector{Mutation}` and tell the
runner which constraint name(s) to look up:

```julia
function _apply_demand_growth(md, indices, new_rhs::Float64)
    region, year = indices
    return [Mutation(:rhs, "demandBalance[$region,$year]", new_rhs)]
end
register_mutation!(:demand_growth, _apply_demand_growth)
```

The constraint *must* exist in the built model and must be name-resolvable
at runtime. This requires `apply_lp_generation_speedups!(m; keep_names = true)`
(the runner does this automatically — don't strip it). If you forget,
`apply_variant!` will throw with a `"could not find constraint by name"`
message.

`is_mutation_registered(:demand_growth)` is a quick check;
`registered_mutation_fields()` lists everything currently registered.

## Persistence

Two formats, same content. DuckDB is faster to query and round-trips
without quoting issues; CSV is git-friendly.

```julia
# DuckDB — one file, 4 tables (spec, targets, samples, variants)
save_scenario_results("Output/sweep.duckdb", result)
result2 = load_scenario_results("Output/sweep.duckdb")

# CSV — one directory with spec.json + samples.csv + variants.csv
save_scenario_results("Output/sweep_csv", result; format = :csv)
result3 = load_scenario_results("Output/sweep_csv"; format = :csv)
```

Round-trip is lossless. On Windows the writer explicitly `finalize`s and
`GC.gc(true)`s after `close!` to release the DuckDB file handle — without
this you can hit "file is locked by another process" if you reopen
immediately in the same Julia session.

## Analysis helpers

All three helpers live in `src/scenario/analysis.jl` and filter to
`term_status == "OPTIMAL"` first; rows with errors or infeasibility are
dropped silently. If `sensitivity_scan` has fewer than
`min_optimal` (default `3`) optimal rows it returns an empty DataFrame.

### `objective_table(result)`

```julia
df = objective_table(result)
# variant_id | objective | term_status | primal_status | build_seconds | apply_seconds | solve_seconds
```

A flat DataFrame ready for `CSV.write` or `Plots.plot(:variant_id, :objective)`.

### `sensitivity_scan(result; min_optimal = 3)`

Spearman rank correlation between each target's effective value and the
objective. One row per target:

```julia
sens = sensitivity_scan(result)
# field | indices | rho | abs_rho | p_value | n_optimal
sort!(sens, :abs_rho, rev = true)
```

`abs_rho` is the easy "which leaf matters most" sort key. `p_value` is
the two-tailed t-approximation for small samples — treat it as indicative
only, not as a publication-grade significance test.

### `pareto_front(result, x_field, y_field; minimize = false)`

Two-objective Pareto-frontier extraction. `x_field` and `y_field` may be
either `:objective` or any target-name `Symbol`. `minimize` flips the
dominance test for each axis (pass a tuple `(true, false)` to mix).

```julia
front = pareto_front(result, :price_carbon, :objective; minimize = (false, true))
# variant_id | x | y      # only Pareto-optimal points
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ArgumentError: No mutation builder registered for parameter X` | You added a `LeafTarget` for `:X` but never `register_mutation!`d it. | Write a builder (see above) and register. |
| `error("could not find constraint by name ...")` in `apply_variant!` | Constraint names stripped at build time. | Make sure your model build path calls `apply_lp_generation_speedups!(m; keep_names = true)`. The campaign runner does — custom build code may not. |
| All variants have `term_status = "ERROR"`, error is `"DimensionMismatch"` or `"KeyError"` after enabling Phase 3.5. | You tagged a leaf as clustering-affecting but the variant's value is **out of range** for the underlying read profile (e.g. asking for `(:wind_nl, 9999)` when years are 2000:2022). | Constrain the LHS bounds, or use `:custom` samples on a known discrete set. |
| Distributed campaign hangs at startup. | Worker can't precompile / find packages. | Run `julia -p N -e "@everywhere using IESAOpt"` once first to verify the environment is reachable on the worker side. Check `Manifest.toml` is committed. |
| `objective_table(result)` returns empty. | Every variant failed. | `filter(v -> v.term_status != "OPTIMAL", result.variants)` and inspect `.error` on a couple. |
| DuckDB file locked when reloading. | Previous writer didn't GC. | Already handled by `_save_duckdb`; if you wrote with custom code, call `DBInterface.close!(db); finalize(db); GC.gc(true)` explicitly. |

## Performance tips

1. **Strip JuMP variable bounds you don't need before campaign start.** They are part of the LP build cost. The default fixtures are already tuned.
2. **Group your profile mutations onto a small discrete grid** if you want Phase 3.5's cache to pay off. Continuous sampling of a profile leaf → one cluster build per variant.
3. **Use the barrier-no-crossover Gurobi preset** (`Dict("Method"=>2, "Crossover"=>0)`) for sensitivity scans where you don't need the basis. Cuts solve time on big LPs by ~30 %.
4. **Pick `n_workers` from the benchmark sweep**, not by gut feel. `scripts/scenario_benchmark.jl` writes `Output/scenario_benchmark.csv` with per-N timings.
5. **Skip precompile + warmup** when iterating in the REPL:
   ```powershell
   $env:IESA_OPT_SKIP_PRECOMPILE = '1'
   $env:IESA_OPT_SKIP_WARMUP     = '1'
   ```
   Production runs and CI should leave these unset.

## See also

- [API Reference](../reference/api.md) — full docstrings for every exported symbol.
- `src/scenario/runner.jl` — the campaign runner internals.
- `src/scenario/manifest.jl` — mutation + clustering registries.
- `src/scenario/orchestrator.jl` — high-level `run_scenario_space`.
- `src/scenario/persistence.jl` — DuckDB + CSV save/load.
- `src/scenario/analysis.jl` — `objective_table` / `sensitivity_scan` / `pareto_front`.
- `scripts/scenario_benchmark.jl` — sweep `n_workers ∈ {0,2,4}` for your hardware.
- `test/test_scenario_clustering.jl` — Phase 3.5 partition + cache key tests.
