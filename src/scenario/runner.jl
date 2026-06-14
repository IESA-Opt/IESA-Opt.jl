# =============================================================================
# scenario/runner.jl — Per-variant runner (serial + Distributed.jl)
#
# Phase 3 of scenario-space exploration. Takes a base `ModelData` that has
# already been derived + clustered, a list of `LeafChange` lists (one per
# variant), and returns a `Vector{VariantResult}` with objective, status, and
# timing for each variant.
#
# Two execution modes (chosen via `n_workers`):
#   * `n_workers <= 1` → serial path. Builds the LP once in this process,
#     applies each variant via `apply_variant!`, solves, captures result.
#     This is the path used by the unit tests and by small / debug campaigns.
#   * `n_workers >= 2` → distributed path. `addprocs(n_workers)`, `@everywhere
#     using IESAOpt`, each worker holds its own model + ModelData copy and
#     runs a long-lived loop pulling variants from a `RemoteChannel`. Master
#     collects results on a bounded result channel for backpressure. After
#     the last variant, master sends N "poison pill" sentinels then
#     `rmprocs(workers)` to fully release Gurobi.Env + JuMP memory.
#
# Solver lifecycle (single-machine, unlimited Gurobi seats assumed):
#   * One JuMP model per worker (or in master for serial), built ONCE with
#     `apply_lp_generation_speedups!(m; keep_names=true)` so `constraint_by_name`
#     can find the emission-cap base names.
#   * `apply_variant!` mutates RHS/coef in place; warm-start basis is retained.
#   * No `JuMP.empty!` between variants.
# =============================================================================

using Distributed
using Dates

"""
    VariantResult(; variant_id, leaf_values, objective, term_status,
                    primal_status, build_seconds, apply_seconds,
                    solve_seconds, error)

Outcome of one variant solve. `leaf_values` is the vector of *effective* leaf
parameter values used for this variant (post-`:multiply`), aligned with the
`LeafChange` list the caller passed in. `error === nothing` for successful
solves; on failure it carries a short stringified message.
"""
Base.@kwdef struct VariantResult
    variant_id::Int
    leaf_values::Vector{Float64}     = Float64[]
    objective::Float64               = NaN
    term_status::String              = ""
    primal_status::String            = ""
    build_seconds::Float64           = 0.0
    apply_seconds::Float64           = 0.0
    solve_seconds::Float64           = 0.0
    error::Union{String,Nothing}     = nothing
end

# Default no-op callbacks used by `run_campaign`. Defined before
# `run_campaign` so default-arg expressions resolve at definition time.
_noop_progress(_x) = nothing
_noop_result(_x) = nothing

const _DEFAULT_HIGHS_ATTRS_CAMPAIGN = Dict{String,Any}(
    "presolve"          => "on",
    "solver"            => "simplex",
    "parallel"          => "off",
    "output_flag"       => false,
)

"""
    _campaign_optimizer(solver::Symbol, threads::Int) -> JuMP-optimizer-factory

Build a per-worker optimizer factory. `solver` is `:highs` (default,
license-free) or `:gurobi` (requires Gurobi.jl + GUROBI_HOME). `threads` is
the per-instance thread cap; for parallel campaigns set this low (e.g. 1)
so workers do not oversubscribe the CPU.
"""
function _campaign_optimizer(solver::Symbol, threads::Int)
    if solver === :highs
        attrs = copy(_DEFAULT_HIGHS_ATTRS_CAMPAIGN)
        # HiGHS uses "threads" if positive; ignored otherwise.
        threads > 0 && (attrs["threads"] = threads)
        return highs_optimizer(; attrs = attrs)
    elseif solver === :gurobi
        attrs = default_gurobi_attributes(; threads = max(0, threads))
        attrs["OutputFlag"] = 0
        return gurobi_optimizer(; attrs = attrs)
    else
        throw(ArgumentError("Unknown solver `$solver`; expected :highs or :gurobi."))
    end
end

"""
    _build_campaign_model(md; solver, threads, mode) -> JuMP.Model

Build the LP for `md` with constraint names preserved so the manifest can
look them up. Caller must have already run `derive_sets!`, `compute_derived_params!`,
and (for `mode === :ts`) `build_temporal_clusters!`.
"""
function _build_campaign_model(md::ModelData; solver::Symbol, threads::Int,
                               mode::Symbol)
    m = Model(_campaign_optimizer(solver, threads))
    # Scenario-space MUST keep names so constraint_by_name works.
    apply_lp_generation_speedups!(m; keep_names = true)
    if mode === :ts
        build_ts_lp!(m, md)
    elseif mode === :fh
        build_fh_lp!(m, md)
    elseif mode === :annual
        build_annual_lp!(m, md)
    else
        throw(ArgumentError("Unknown mode `$mode`; expected :ts, :fh, or :annual."))
    end
    return m
end

"""
    _run_one_variant!(model, md, changes, variant_id) -> VariantResult

Apply one variant's `LeafChange` list to a pre-built model + ModelData and
solve. Caller is responsible for `deepcopy(md)` if multiple workers share the
base.
"""
function _run_one_variant!(model::JuMP.Model, md::ModelData,
                           changes::AbstractVector{LeafChange},
                           variant_id::Int)
    try
        out = nothing
        t_apply = @elapsed begin
            out = apply_variant!(model, md, changes; rederive = true)
        end
        t_solve = @elapsed optimize!(model)
        term = string(termination_status(model))
        prim = string(primal_status(model))
        obj  = (term == "OPTIMAL") ? objective_value(model) : NaN
        return VariantResult(
            variant_id     = variant_id,
            leaf_values    = collect(out.values),
            objective      = obj,
            term_status    = term,
            primal_status  = prim,
            apply_seconds  = t_apply,
            solve_seconds  = t_solve,
        )
    catch err
        return VariantResult(
            variant_id  = variant_id,
            error       = sprint(showerror, err),
            term_status = "ERROR",
        )
    end
end

# -----------------------------------------------------------------------------
# Serial path
# -----------------------------------------------------------------------------
"""
    _run_campaign_serial(base_md, changes_per_variant; solver, threads, mode,
                         on_progress, on_result, cancel) -> Vector{VariantResult}

Single-process loop: build model once, mutate + solve per variant. Used by
tests and by `run_campaign` when `n_workers <= 1`.
"""
function _run_campaign_serial(base_md::ModelData,
                              changes_per_variant::AbstractVector;
                              solver::Symbol, threads::Int, mode::Symbol,
                              on_progress::Function, on_result::Function,
                              cancel::Ref{Bool})
    n = length(changes_per_variant)
    md_work = deepcopy(base_md)
    t_build = @elapsed begin
        model = _build_campaign_model(md_work; solver = solver,
                                      threads = threads, mode = mode)
    end
    results = Vector{VariantResult}(undef, n)
    @inbounds for i in 1:n
        if cancel[]
            results[i] = VariantResult(
                variant_id  = i,
                term_status = "CANCELLED",
                error       = "Campaign cancelled before variant $i.",
            )
            continue
        end
        on_progress((variant_id = i, total = n, stage = "start"))
        r = _run_one_variant!(model, md_work, changes_per_variant[i], i)
        # Record build time on the first variant for cost accounting.
        i == 1 && (r = VariantResult(
            variant_id = r.variant_id, leaf_values = r.leaf_values,
            objective = r.objective, term_status = r.term_status,
            primal_status = r.primal_status, build_seconds = t_build,
            apply_seconds = r.apply_seconds, solve_seconds = r.solve_seconds,
            error = r.error))
        results[i] = r
        on_result(r)
        on_progress((variant_id = i, total = n, stage = "done", result = r))
    end
    return results
end

# -----------------------------------------------------------------------------
# Distributed path
# -----------------------------------------------------------------------------
"""
    _worker_loop(task_ch, result_ch, base_md, solver, threads, mode)

Long-running per-worker loop. Pulls `(variant_id, changes)` tuples from
`task_ch`; pushes `VariantResult` to `result_ch`. Terminates when it
receives `nothing` (poison pill). Builds the JuMP model lazily on first
variant and reuses it for every subsequent variant (warm-start retained).
"""
function _worker_loop(task_ch::RemoteChannel, result_ch::RemoteChannel,
                      base_md::ModelData,
                      solver::Symbol, threads::Int, mode::Symbol)
    md = nothing
    model = nothing
    t_build = 0.0
    n_done = 0
    try
        while true
            item = take!(task_ch)
            item === nothing && break  # poison pill — clean shutdown
            variant_id, changes = item
            if model === nothing
                md = deepcopy(base_md)
                t_build = @elapsed begin
                    model = _build_campaign_model(md; solver = solver,
                                                  threads = threads, mode = mode)
                end
            end
            r = _run_one_variant!(model, md, changes, variant_id)
            if n_done == 0
                r = VariantResult(
                    variant_id = r.variant_id, leaf_values = r.leaf_values,
                    objective = r.objective, term_status = r.term_status,
                    primal_status = r.primal_status, build_seconds = t_build,
                    apply_seconds = r.apply_seconds, solve_seconds = r.solve_seconds,
                    error = r.error)
            end
            n_done += 1
            put!(result_ch, r)
        end
    catch err
        # Push a synthetic failure so the master knows this worker died.
        put!(result_ch, VariantResult(
            variant_id  = -1,
            term_status = "WORKER_ERROR",
            error       = sprint(showerror, err),
        ))
    end
    return n_done
end

"""
    _run_campaign_distributed(base_md, changes_per_variant; n_workers,
                              threads_per_worker, solver, mode,
                              on_progress, on_result, cancel) -> Vector{VariantResult}

Spawn `n_workers` Julia worker processes, ship `base_md` once, then dispatch
variants over a bounded `RemoteChannel`. Cleans up workers (`rmprocs`) before
returning, releasing all model memory + Gurobi.Env handles.
"""
function _run_campaign_distributed(base_md::ModelData,
                                   changes_per_variant::AbstractVector;
                                   n_workers::Int, threads_per_worker::Int,
                                   solver::Symbol, mode::Symbol,
                                   on_progress::Function, on_result::Function,
                                   cancel::Ref{Bool})
    n = length(changes_per_variant)
    # Reuse the env Julia process is already in (same Project.toml).
    project_path = Base.active_project()
    project_path === nothing && error("run_campaign: no active project; addprocs would not inherit IESAOpt.")
    project_dir = dirname(project_path)
    exeflags = ["--project=$project_dir", "--threads=$(max(1, threads_per_worker))"]
    @info "run_campaign: spawning $n_workers worker(s)" exeflags solver mode
    pids = addprocs(n_workers; exeflags = exeflags)
    try
        # Bootstrap workers with IESAOpt.  We cannot use `@everywhere using ...`
        # inside a function body (the macro expands to a top-level expression).
        # We also cannot send a closure that *references* IESAOpt before the
        # worker has loaded it (the closure deserializer needs the parent
        # module). Workaround: send a quoted Expr to `Main.eval` — `Main`
        # exists on every fresh worker.
        for p in pids
            remotecall_wait(Main.eval, p, :(using IESAOpt))
        end

        # Bounded result channel — caps memory pressure on master under
        # a slow downstream consumer.
        task_cap = max(n_workers * 4, 16)
        res_cap  = max(n_workers * 4, 16)
        task_ch  = RemoteChannel(() -> Channel{Any}(task_cap))
        result_ch = RemoteChannel(() -> Channel{VariantResult}(res_cap))

        # Start the worker loops.
        worker_futures = Future[]
        for p in pids
            push!(worker_futures,
                  remotecall(IESAOpt._worker_loop, p, task_ch, result_ch,
                             base_md, solver, threads_per_worker, mode))
        end

        # Producer: push variants then `nothing` x n_workers (poison pills).
        producer = @async begin
            try
                for i in 1:n
                    cancel[] && break
                    put!(task_ch, (i, changes_per_variant[i]))
                end
            finally
                for _ in 1:length(pids)
                    put!(task_ch, nothing)
                end
            end
        end

        # Collector: pull n results (or fewer if cancelled).
        results = Vector{VariantResult}(undef, n)
        for slot in 1:n
            r = take!(result_ch)
            if r.variant_id <= 0 || r.variant_id > n
                # Worker error sentinel — log and break to avoid hanging.
                @warn "Campaign worker error" error = r.error
                # Replace any unfilled slot with a synthetic error result.
                for j in 1:n
                    isassigned(results, j) ||
                        (results[j] = VariantResult(variant_id = j,
                                                    term_status = "WORKER_ERROR",
                                                    error = r.error))
                end
                break
            end
            results[r.variant_id] = r
            on_result(r)
            on_progress((variant_id = r.variant_id, total = n, stage = "done", result = r))
        end
        wait(producer)
        # Wait for worker loops to drain so rmprocs is clean.
        for f in worker_futures
            try; fetch(f); catch; end
        end
        # Fill any still-unassigned slot with a cancellation result.
        for j in 1:n
            isassigned(results, j) ||
                (results[j] = VariantResult(variant_id = j,
                                            term_status = "CANCELLED",
                                            error = "Variant $j not completed (cancelled or worker died)."))
        end
        return results
    finally
        try
            rmprocs(pids; waitfor = 60)
        catch err
            @warn "rmprocs failed; workers may linger" err
        end
    end
end

# -----------------------------------------------------------------------------
# Public entry
# -----------------------------------------------------------------------------
"""
    run_campaign(base_md, changes_per_variant; kwargs...) -> Vector{VariantResult}

Top-level entry for Phase 3. `base_md::ModelData` must already have
`derive_sets!`, `compute_derived_params!`, and (for `mode === :ts`)
`build_temporal_clusters!` applied — `read_data_cached` returns a freshly
loaded ModelData; the campaign caller is responsible for the derivation pass.

`changes_per_variant::AbstractVector{<:AbstractVector{LeafChange}}` is one
list of `LeafChange` per variant. Index `i` of the input maps to
`VariantResult.variant_id == i` in the output (variant_id is 1-based).

Keyword arguments:
  * `n_workers::Int = 0` — `<= 1` runs in-process serial; `>= 2` spawns
    Julia worker processes via `Distributed.addprocs`. The serial path is
    much faster for tiny campaigns (no addprocs / `@everywhere using IESAOpt`
    bootstrap cost ~10-15 s on cold cache).
  * `threads_per_worker::Int = 1` — solver thread cap per process. With
    `n_workers * threads_per_worker > num_physical_cores` you will likely
    see oversubscription slowdowns. Default 1 keeps it conservative.
  * `solver::Symbol = :highs` — `:highs` (license-free, default) or `:gurobi`.
  * `mode::Symbol = :ts` — `:ts`, `:fh`, or `:annual`. Must match what
    `base_md` was prepared for (TS requires the cluster pass).
  * `cancel::Ref{Bool} = Ref(false)` — set to `true` from another task to
    request an orderly stop (master stops dispatching new variants).
  * `on_progress::Function = _noop_progress` — called as
    `on_progress((variant_id, total, stage, [result]))` after each variant.
  * `on_result::Function = _noop_result` — called as `on_result(r::VariantResult)`
    for every completed variant; useful for streaming to disk / DuckDB.
"""
function run_campaign(base_md::ModelData,
                      changes_per_variant::AbstractVector;
                      n_workers::Int                = 0,
                      threads_per_worker::Int       = 1,
                      solver::Symbol                = :highs,
                      mode::Symbol                  = :ts,
                      cancel::Ref{Bool}             = Ref(false),
                      on_progress::Function         = _noop_progress,
                      on_result::Function           = _noop_result)
    n = length(changes_per_variant)
    n == 0 && return VariantResult[]
    @info "run_campaign: starting" n_variants=n n_workers=n_workers solver=solver mode=mode
    if n_workers <= 1
        return _run_campaign_serial(base_md, changes_per_variant;
                                    solver = solver, threads = threads_per_worker,
                                    mode = mode, on_progress = on_progress,
                                    on_result = on_result, cancel = cancel)
    else
        return _run_campaign_distributed(base_md, changes_per_variant;
                                         n_workers = n_workers,
                                         threads_per_worker = threads_per_worker,
                                         solver = solver, mode = mode,
                                         on_progress = on_progress,
                                         on_result = on_result, cancel = cancel)
    end
end

# (default no-op callbacks are defined near the top of this file)
