# HANDOFF — `scenariospace` branch · scenario-space exploration

> **This file is a temporary diagnostic note.** It exists so a second
> machine (and the AI assistant running on it) can pick up where the
> development laptop left off, validate the distributed runner at higher
> worker counts, and finalise the scenario-space subsystem. Delete this
> file together with `scripts/scenario_benchmark.jl` once the scaling
> measurements are in and the design is settled.

## What is on this branch

A 5-phase scenario-space exploration subsystem built on top of `IESAOpt`.
All Julia code, tests, and helper scripts live under
[src/scenario/](src/scenario/),
[test/test_scenario*.jl](test/),
and [scripts/scenario_*.jl](scripts/).

| Phase | Theme | Key files | Status |
|------:|-------|-----------|--------|
| 1 | Parameter-space spec + samplers (xlsx-coordinate `CampaignSpec`, LHS/Sobol/Morris/Factorial) | [src/scenario/types.jl](src/scenario/types.jl), [src/scenario/sampling.jl](src/scenario/sampling.jl), [test/test_scenario.jl](test/test_scenario.jl) | committed `67ddc60` |
| 2 | In-place LP mutation (mutation manifest + per-variant `apply_variant!`) | [src/scenario/manifest.jl](src/scenario/manifest.jl), [src/scenario/variant.jl](src/scenario/variant.jl), [test/test_scenario_mutation.jl](test/test_scenario_mutation.jl) | committed `96775ef` |
| 3 | Campaign runner (serial + Distributed.jl worker pool) | [src/scenario/runner.jl](src/scenario/runner.jl), [test/test_scenario_runner.jl](test/test_scenario_runner.jl), [scripts/scenario_run_campaign.jl](scripts/scenario_run_campaign.jl) | committed `2578038`, polished `4121fc0` |
| 4 | High-level orchestrator (`run_scenario_space`) + result persistence (CSV + DuckDB) | [src/scenario/orchestrator.jl](src/scenario/orchestrator.jl), [src/scenario/persistence.jl](src/scenario/persistence.jl), [test/test_scenario_orchestrator.jl](test/test_scenario_orchestrator.jl) | **uncommitted, fully tested** |
| 5 | Analysis helpers (`objective_table`, `sensitivity_scan`, `pareto_front`) | [src/scenario/analysis.jl](src/scenario/analysis.jl), [test/test_scenario_analysis.jl](test/test_scenario_analysis.jl) | **uncommitted, fully tested** |
| diag | Cross-machine benchmark script + this file | [scripts/scenario_benchmark.jl](scripts/scenario_benchmark.jl), `HANDOFF.md` | **uncommitted; remove after diagnostics** |

## The open question

The Phase 3 polish commit (`4121fc0`) verified that the distributed path
produces identical objectives to the serial path on a 4-variant /
10-rep-day / Gurobi BarrierCrossover campaign, but **it was slower** on the
dev laptop:

| path | wall time | speedup |
|------|----------:|--------:|
| serial (1 model held warm) | 48.7 s | 1.00× |
| distributed (2 workers)    | 63.6 s | 0.77× |

Bootstrap accounts for **~13.6 s** (addprocs 3.9 + `using IESAOpt` 5.9 +
ship `ModelData` 3.3 + rmprocs 0.5) on every campaign call. On top of that
each worker pays a per-process JIT tax of ~12 s on its first solve, because
the serial pass that ran first warmed the master's caches but not the
workers'. So at N=4 the bootstrap is half the campaign.

This is **expected**. The runner is correct; what we don't yet know is
where the cross-over point sits on bigger hardware. The hypothesis is:

* break-even at 2 workers requires N ≈ 8;
* meaningful (>1.3×) speedup needs N ≥ 10;
* scaling to 4–8 workers should be near-linear minus the constant
  bootstrap, on a machine with enough cores and RAM headroom.

## What the second machine should run

**Goal**: produce a worker-count sweep so we can pick a default
heuristic for `n_workers` and document the trade-off in the docs.

1. **Clone + checkout the branch**
   ```powershell
   git checkout scenariospace
   git pull origin scenariospace
   ```

2. **Sanity-check the test suite** (≈ 60 s on a warm precompile cache)
   ```powershell
   $env:IESA_OPT_SKIP_PRECOMPILE = '1'
   $env:IESA_OPT_SKIP_WARMUP = '1'
   julia --project=. -e 'using Pkg; Pkg.test()'
   ```
   All scenario-space testsets (Phases 1–5) must be green. If you change
   anything in `src/scenario/persistence.jl` on Windows, see the
   "DuckDB lock" footnote at the bottom of this file.

3. **Run the benchmark sweep**

   Open [scripts/scenario_benchmark.jl](scripts/scenario_benchmark.jl) and
   edit the top-of-file constants for your hardware:

   ```julia
   const WORKER_COUNTS = [0, 2, 4, 8, 16]   # 0 = serial path
   const N_VARIANTS    = 12                  # divisible by 2, 4 — pick something larger if your hardware can afford it
   const N_REPDAYS     = 10                  # 10 → ~5 s per solve on this dev laptop
   const SOLVER        = :gurobi             # change to :highs if no Gurobi license
   ```

   then:
   ```powershell
   $env:IESA_OPT_SKIP_PRECOMPILE = '1'
   $env:IESA_OPT_SKIP_WARMUP = '1'
   julia --project=. scripts/scenario_benchmark.jl
   ```

   This will print a markdown table to stdout and persist raw measurements
   to `Output/scenario_benchmark.csv`. **Commit both the printed table
   (paste it back into this file under "Results") and the CSV.**

4. **Report back** by amending or appending to this file with:
   * machine class (CPU model, cores, RAM, OS, Julia version);
   * the markdown sweep table;
   * per-worker variant assignments (these are printed during the run);
   * any anomalies — failed solves, OOM, Distributed cluster errors.

## Results so far (dev laptop)

CPU ~14 cores, Windows 11, Julia 1.12.4, Gurobi 11.x, default workbook,
10 rep days, 2050 only, `Method=2, Crossover=-1`.

| n_workers | wall (s) | speedup | cold_builds | Σbuild (s) | Σsolve (s) | Σapply (s) |
|----------:|---------:|--------:|------------:|-----------:|-----------:|-----------:|
|         0 |    48.72 |  1.00×  |           1 |       7.40 |      40.05 |       0.27 |
|         2 |    63.60 |  0.77×  |           2 |      24.10 |      37.45 |       0.21 |

> **Action for the other PC**: re-run with `WORKER_COUNTS = [0, 2, 4, 8, 16]`
> and `N_VARIANTS = 12` (or higher), then replace this table.

## Architecture notes the other AI should know

### 1. `run_scenario_space(base_md, spec; ...)` — Phase 4 entry point

```julia
spec = ScenarioSpec(
    name       = "CO2_x_bunker",
    method     = :lhs,                       # :lhs | :sobol | :morris | :factorial
    n_variants = 24,
    seed       = 42,
    targets    = [
        LeafTarget(:price_co2,            (:NL,);     type=:set,     min=50.0, max=200.0,
                   label="co2_NL"),
        LeafTarget(:emissionTargetBunker, (:NL,2050); type=:multiply, min=0.5, max=1.5,
                   label="bunker_2050"),
    ],
)
result = run_scenario_space(base_md, spec;
    n_workers          = 4,
    threads_per_worker = 1,
    solver             = :gurobi,
    solver_attrs       = Dict("Method"=>2, "Crossover"=>-1),
    mode               = :ts,
)
save_scenario_results("Output/CO2_x_bunker", result; format=:duckdb, overwrite=true)
```

`LeafTarget` references a leaf parameter by `(field, indices)`, so it is
*workbook-independent* (Phase 1's `ParameterRow` needed sheet+cell). This
means a spec written in Julia is round-trippable through DuckDB and stays
valid even if the workbook is re-saved. The bridge from xlsx `CampaignSpec`
to `ScenarioSpec` is intentionally NOT implemented yet — that's a future
concern (UI, not Julia).

### 2. Persistence (`save_scenario_results`)

* `format = :csv` (default) writes 4 files: `spec.json`, `samples.csv`,
  `results.csv`, `combined.csv` (samples + results joined on `variant_id`).
* `format = :duckdb` writes one `scenario_results.duckdb` with 4 tables:
  `spec`, `targets`, `samples`, `results`. Uses `CREATE OR REPLACE TABLE`
  so re-saves with `overwrite=true` are idempotent.
* Symbol indices like `(:NL, 2050)` are serialized as `":NL|2050"`
  (DuckDB) or as JSON arrays with `:NL` prefix (CSV side). `_parse_index`
  is the inverse: `":NL"` → `Symbol`, `"2050"` → `Int`, `"3.14"` → `Float64`,
  else `String`.

### 3. Analysis (`src/scenario/analysis.jl`)

Three small DataFrame helpers, no plotting deps:

```julia
df    = objective_table(result)                                  # wide table: targets + objective + solve metadata
sens  = sensitivity_scan(result; min_optimal = 5)                # Pearson cor of objective vs each target
front = pareto_front(result, :co2_NL, :objective;
                     minimize = (true, true))                     # non-dominated subset over 2 cols
```

All three filter to `term_status == "OPTIMAL"` first. For richer SA
(Sobol indices, Morris elementary effects) call out to
[GlobalSensitivity.jl](https://github.com/SciML/GlobalSensitivity.jl) with
`result.samples` and `[v.objective for v in result.variants]`.

### 4. Distributed runner gotchas (already fixed)

These are documented in `/memories/repo/editing-notes.md` but the most
important ones for hot-loop iteration:

* `Distributed` is a Julia stdlib but **must** appear in `Project.toml`
  `[deps]` (UUID `8ba89e20-285c-5b6f-9357-94700520ee1b`), else precompile
  fails with `ArgumentError: Package IESAOpt does not have Distributed`.
* Worker bootstrap **must** use
  `remotecall_wait(Main.eval, p, :(using IESAOpt))` — not
  `@everywhere using IESAOpt` (toplevel-only macro) and not a closure
  (chicken-and-egg: closure references `IESAOpt` which is not yet loaded
  on the worker).
* Each worker holds **one** JuMP model warm in a `_worker_loop` and pulls
  variants from a bounded `RemoteChannel`. The master never ships JuMP
  models — only `LeafChange` vectors.
* `VariantResult.worker_pid` (master = 1, workers ≥ 2) lets you verify
  the assignment after the fact.

### 5. DuckDB on Windows (lessons learned this session)

If you change `src/scenario/persistence.jl` or write any other DuckDB
round-trip code, three rules:

1. `DBInterface.execute(db, "CREATE TABLE a (); CREATE TABLE b ();")`
   throws `Invalid Input Error: Cannot prepare multiple statements at once!`.
   Execute one DDL per call.
2. `DBInterface.close!(db)` does **not** actually release the OS file
   handle on Windows until the GC runs. The workaround in
   `_save_duckdb` / `_load_duckdb` is
   `try ...; finally DBInterface.close!(db); finalize(db); GC.gc(true); end`.
   `GC.gc()` (incremental) is not enough — must be `GC.gc(true)` (full).
3. Use `CREATE OR REPLACE TABLE` for idempotent re-saves rather than
   rm-then-create, otherwise Windows file locks race with antivirus /
   Search indexer.

### 6. Dev fast-loop env vars

| variable | effect |
|----------|--------|
| `IESA_OPT_SKIP_PRECOMPILE=1` | skip `@compile_workload` during `Pkg.precompile` |
| `IESA_OPT_SKIP_WARMUP=1`     | skip UI warm-up cache (first run pays JIT on demand) |
| `IESA_OPT_KEEP_NAMES=1`      | keep JuMP constraint names (needed for IIS / slack reports) |

Always set the first two when iterating on tests; never set them in
production.

## Known limitations / TODOs (not blockers for benchmarking)

These are recorded so the design discussion can resume on the other PC.
None of them affects the scaling-validation work you're being asked to do
— the benchmark sweep perturbs only **scalar** parameters (`price_co2`,
`emissionTargetBunker`) and so is safe under the current implementation.

### A. Per-variant clustering when hourly profiles change

`build_temporal_clusters!(base_md)` is currently called **once** before the
campaign and every variant solves against the same representative days.
That is correct for variants that only perturb scalars (prices, caps,
emission targets…). It is **wrong** for variants that perturb hourly
profile inputs (`hourly_avail`, demand profiles, weather), because the
cluster assignment is computed from the base profile and stops being
representative of the perturbed one.

Planned fix (Phase 3.5 or Phase 6):

1. Tag each leaf in the mutation registry with an `affects_clustering::Bool`
   flag (default `false`; `true` for `hourly_avail`, `dem_profile`, etc.).
2. In the campaign runner, before each variant: if any of its `LeafChange`s
   has `affects_clustering == true`, re-run `build_temporal_clusters!` on
   the variant's mutated `md` AND rebuild the LP (because cluster days
   change → time index changes → `apply_variant!` can no longer warm-start).
3. **Optimisation**: hash the profile-defining subset of params for each
   variant. Variants with the same hash share the same clustering output,
   so N variants that draw from only K << N unique profile sets pay K
   clustering costs instead of N. Cache the clustered `md` (or just the
   cluster days + weights + medoids) keyed on that hash.

This was deliberately deferred so the runner could land first; opening it
up requires touching `manifest.jl` (add the flag), `runner.jl` (the
per-variant branch), and probably a small `cluster_cache.jl` helper.

### B. Worker-count heuristic in `run_campaign`

Currently the caller picks `n_workers` explicitly. After the scaling
sweep on the other PC produces real numbers, we should add a heuristic
default — something like
`n_workers = clamp(n_variants ÷ 4, 0, Sys.CPU_THREADS ÷ 2)` — and
document it in the runner docstring.

### C. CSV→Julia type round-trip for index columns

`load_scenario_results(..., format=:csv)` currently re-attaches
`leaf_values` from `samples.csv` but does not validate that the column
ordering matches `spec.targets` ordering. Add an assertion or persist
column→target_id mapping in `spec.json`. Low priority — same writer/reader
in the same Julia version always round-trips correctly.

## Files this branch touches (uncommitted as of writing)

```
src/IESAOpt.jl                         — includes + exports (Phase 4 & 5)
src/scenario/orchestrator.jl           — Phase 4: ScenarioSpec, run_scenario_space
src/scenario/persistence.jl            — Phase 4: CSV + DuckDB save/load
src/scenario/analysis.jl               — Phase 5: objective_table / sensitivity_scan / pareto_front
test/test_scenario_orchestrator.jl     — Phase 4 unit tests (13 testsets, all green)
test/test_scenario_analysis.jl         — Phase 5 unit tests (9 testsets, all green)
test/runtests.jl                       — wires the two new test files in
scripts/scenario_benchmark.jl          — DIAGNOSTIC; remove after we're done
HANDOFF.md                             — this file; remove after we're done
```

## After the second machine is done

1. Update the "Results so far" table with the new measurements.
2. Decide a default `n_workers` heuristic and document it in
   `src/scenario/runner.jl` and (briefly) in `docs/src/user-guide/`.
3. Remove `HANDOFF.md` and `scripts/scenario_benchmark.jl` from the branch.
4. Open a PR `scenariospace → main`.
