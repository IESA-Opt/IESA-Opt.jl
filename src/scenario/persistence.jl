# =============================================================================
# scenario/persistence.jl -- Phase 4: save/load ScenarioResult to disk
#
# Persistence layout (CSV is the default; DuckDB is a single-file alternative):
#
#   <dir>/
#       spec.json        — human-readable spec dump
#       samples.csv      — variant_id + one column per LeafTarget
#       results.csv      — variant_id, objective, term_status, primal_status,
#                          worker_pid, build_seconds, apply_seconds, solve_seconds, error
#       combined.csv     — INNER JOIN of samples + results on variant_id
#                          (convenience for one-click DataFrame loading)
#
# DuckDB alternative (single file, fast columnar queries):
#
#   <dir>/scenario_results.duckdb
#       table spec        (key, value)
#       table targets     (id, field, indices_str, type, min, max, step, label)
#       table samples     (variant_id, target_id, value)
#       table results     (variant_id, objective, term_status, primal_status,
#                          worker_pid, build_seconds, apply_seconds, solve_seconds, error)
#
# The CSV format is the default because it is human-readable, version-control-
# friendly, and trivially loaded by Python/R/Excel for downstream analysis.
# DuckDB is offered when you have many variants (N > ~1e4) where CSV starts
# to slow down.
# =============================================================================

using CSV
using DataFrames
using DuckDB
using JSON3

# -----------------------------------------------------------------------------
# Public entry points
# -----------------------------------------------------------------------------

"""
    save_scenario_results(dir, result::ScenarioResult; format=:csv, overwrite=false)

Persist a [`ScenarioResult`](@ref) to `dir`. The directory is created if it
does not exist.

* `format=:csv`     writes `spec.json` + `samples.csv` + `results.csv` +
                    `combined.csv` (see file docstring for layout).
* `format=:duckdb`  writes a single `scenario_results.duckdb` file with the
                    same data normalised into 4 tables.
* `overwrite=true`  silently overwrites existing files; default `false`
                    throws if any of the target files exist.

Returns the absolute path to `dir`.
"""
function save_scenario_results(dir::AbstractString, result::ScenarioResult;
                               format::Symbol = :csv,
                               overwrite::Bool = false)
    isdir(dir) || mkpath(dir)
    if format === :csv
        return _save_csv(dir, result; overwrite = overwrite)
    elseif format === :duckdb
        return _save_duckdb(dir, result; overwrite = overwrite)
    else
        throw(ArgumentError("Unknown format $(repr(format)). Use :csv or :duckdb."))
    end
end

"""
    load_scenario_results(dir; format=:csv) -> ScenarioResult

Inverse of [`save_scenario_results`](@ref). Reads back the spec, samples, and
variant results from `dir`.

Note that the reconstructed `ScenarioSpec` only captures the data that was
persisted (label, bounds, step, type, field, indices). It is sufficient to
re-run / re-sample the campaign but is not byte-identical to the in-memory
spec if the original had auxiliary metadata that the persistence layer did
not preserve.
"""
function load_scenario_results(dir::AbstractString; format::Symbol = :csv)
    if format === :csv
        return _load_csv(dir)
    elseif format === :duckdb
        return _load_duckdb(dir)
    else
        throw(ArgumentError("Unknown format $(repr(format)). Use :csv or :duckdb."))
    end
end

# -----------------------------------------------------------------------------
# CSV implementation
# -----------------------------------------------------------------------------

function _csv_paths(dir::AbstractString)
    return (spec     = joinpath(dir, "spec.json"),
            samples  = joinpath(dir, "samples.csv"),
            results  = joinpath(dir, "results.csv"),
            combined = joinpath(dir, "combined.csv"))
end

function _save_csv(dir::AbstractString, result::ScenarioResult; overwrite::Bool)
    p = _csv_paths(dir)
    if !overwrite
        for f in (p.spec, p.samples, p.results, p.combined)
            isfile(f) && throw(ArgumentError("File already exists: $f. Use overwrite=true."))
        end
    end
    # spec.json — combine the spec dict with the campaign runtime so a single
    # file describes the campaign + how long it took.
    spec_dict = _spec_to_dict(result.spec)
    spec_dict["runtime_seconds"] = result.runtime_seconds
    open(p.spec, "w") do io
        JSON3.pretty(io, spec_dict)
    end
    # samples.csv
    CSV.write(p.samples, _samples_dataframe(result))
    # results.csv
    CSV.write(p.results, _results_dataframe(result))
    # combined.csv (samples joined with results on variant_id)
    CSV.write(p.combined, _combined_dataframe(result))
    return abspath(dir)
end

function _load_csv(dir::AbstractString)
    p = _csv_paths(dir)
    isfile(p.spec)    || throw(ArgumentError("Missing $(p.spec)"))
    isfile(p.samples) || throw(ArgumentError("Missing $(p.samples)"))
    isfile(p.results) || throw(ArgumentError("Missing $(p.results)"))
    spec_dict = JSON3.read(read(p.spec, String), Dict{String,Any})
    spec = _dict_to_spec(spec_dict)
    samples_df = CSV.read(p.samples, DataFrame)
    results_df = CSV.read(p.results, DataFrame)
    samples = _dataframe_to_samples(spec, samples_df)
    variants = _dataframe_to_variants(spec, results_df, samples)
    runtime = get(spec_dict, "runtime_seconds", NaN)
    runtime = runtime isa Real ? Float64(runtime) : NaN
    return ScenarioResult(spec, samples, variants, runtime)
end

# -----------------------------------------------------------------------------
# DuckDB implementation
# -----------------------------------------------------------------------------

_duckdb_path(dir::AbstractString) = joinpath(dir, "scenario_results.duckdb")

function _save_duckdb(dir::AbstractString, result::ScenarioResult; overwrite::Bool)
    path = _duckdb_path(dir)
    if isfile(path) && !overwrite
        throw(ArgumentError("File already exists: $path. Use overwrite=true."))
    end
    # On Windows, rm-then-open races with antivirus/indexer locks. Open in
    # place and use CREATE OR REPLACE TABLE so re-saves are deterministic.
    db = DuckDB.DB(path)
    try
        DBInterface.execute(db, "CREATE OR REPLACE TABLE spec (key VARCHAR, value VARCHAR);")
        DBInterface.execute(db, """
            CREATE OR REPLACE TABLE targets (
                id INTEGER, field VARCHAR, indices_str VARCHAR, type VARCHAR,
                min DOUBLE, max DOUBLE, step DOUBLE, label VARCHAR);
        """)
        DBInterface.execute(db, """
            CREATE OR REPLACE TABLE samples (
                variant_id INTEGER, target_id INTEGER, value DOUBLE);
        """)
        DBInterface.execute(db, """
            CREATE OR REPLACE TABLE results (
                variant_id INTEGER, objective DOUBLE, term_status VARCHAR,
                primal_status VARCHAR, worker_pid INTEGER, build_seconds DOUBLE,
                apply_seconds DOUBLE, solve_seconds DOUBLE, error VARCHAR);
        """)
        spec_dict = _spec_to_dict(result.spec)
        for (k, v) in spec_dict
            k == "targets" && continue
            DBInterface.execute(db, "INSERT INTO spec VALUES (?, ?)", [string(k), string(v)])
        end
        DBInterface.execute(db, "INSERT INTO spec VALUES (?, ?)",
                            ["runtime_seconds", string(result.runtime_seconds)])
        for (i, t) in enumerate(result.spec.targets)
            DBInterface.execute(db, "INSERT INTO targets VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                                [i, String(t.field), _indices_to_str(t.indices),
                                 String(t.type), t.min, t.max,
                                 t.step === nothing ? missing : t.step, t.label])
        end
        n, k = size(result.samples)
        for i in 1:n, j in 1:k
            DBInterface.execute(db, "INSERT INTO samples VALUES (?, ?, ?)",
                                [i, j, result.samples[i, j]])
        end
        for v in result.variants
            DBInterface.execute(db,
                "INSERT INTO results VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [v.variant_id, v.objective, v.term_status, v.primal_status,
                 v.worker_pid, v.build_seconds, v.apply_seconds, v.solve_seconds,
                 v.error === nothing ? missing : v.error])
        end
        # Force WAL flush so the next open() of this file works on Windows.
        try
            DBInterface.execute(db, "CHECKPOINT;")
        catch
        end
    finally
        DBInterface.close!(db)
        finalize(db)
        # On Windows, prepared statements + query results hold file handles
        # until GC finalises them. Force a full collection so the next
        # open() of this path won't see "file is already open".
        GC.gc(true)
    end
    return abspath(dir)
end

function _load_duckdb(dir::AbstractString)
    path = _duckdb_path(dir)
    isfile(path) || throw(ArgumentError("Missing $path"))
    db = DuckDB.DB(path)
    try
        spec_rows = DBInterface.execute(db, "SELECT key, value FROM spec") |> DataFrame
        spec_pairs = Dict{String,Any}(string(r.key) => string(r.value) for r in eachrow(spec_rows))
        targets_df = DBInterface.execute(db,
            "SELECT id, field, indices_str, type, min, max, step, label FROM targets ORDER BY id") |> DataFrame
        targets = LeafTarget[]
        for r in eachrow(targets_df)
            push!(targets, LeafTarget(
                Symbol(r.field),
                _str_to_indices(String(r.indices_str));
                type  = Symbol(r.type),
                min   = Float64(r.min),
                max   = Float64(r.max),
                step  = ismissing(r.step) ? nothing : Float64(r.step),
                label = String(r.label)))
        end
        spec = ScenarioSpec(
            name       = get(spec_pairs, "name", "campaign"),
            method     = Symbol(get(spec_pairs, "method", "lhs")),
            n_variants = parse(Int, get(spec_pairs, "n_variants", "0")),
            seed       = parse(Int, get(spec_pairs, "seed", "0")),
            targets    = targets)
        n_variants = spec.n_variants
        k = length(targets)
        samples = Matrix{Float64}(undef, n_variants, k)
        for r in eachrow(DBInterface.execute(db,
                "SELECT variant_id, target_id, value FROM samples") |> DataFrame)
            samples[r.variant_id, r.target_id] = Float64(r.value)
        end
        results_df = DBInterface.execute(db, """
            SELECT variant_id, objective, term_status, primal_status, worker_pid,
                   build_seconds, apply_seconds, solve_seconds, error
            FROM results ORDER BY variant_id
        """) |> DataFrame
        variants = VariantResult[]
        for r in eachrow(results_df)
            leaf_vals = samples[Int(r.variant_id), :]
            push!(variants, VariantResult(
                variant_id    = r.variant_id,
                leaf_values   = leaf_vals,
                objective     = Float64(r.objective),
                term_status   = String(r.term_status),
                primal_status = String(r.primal_status),
                worker_pid    = r.worker_pid,
                build_seconds = Float64(r.build_seconds),
                apply_seconds = Float64(r.apply_seconds),
                solve_seconds = Float64(r.solve_seconds),
                error         = ismissing(r.error) ? nothing : String(r.error)))
        end
        runtime = parse(Float64, get(spec_pairs, "runtime_seconds", "NaN"))
        return ScenarioResult(spec, samples, variants, runtime)
    finally
        DBInterface.close!(db)
        finalize(db)
        # See _save_duckdb: free file handles eagerly on Windows.
        GC.gc(true)
    end
end

# -----------------------------------------------------------------------------
# Spec ↔ Dict
# -----------------------------------------------------------------------------

function _spec_to_dict(spec::ScenarioSpec)
    return Dict{String,Any}(
        "name"       => spec.name,
        "method"     => String(spec.method),
        "n_variants" => spec.n_variants,
        "seed"       => spec.seed,
        "targets"    => [_target_to_dict(t) for t in spec.targets])
end

function _target_to_dict(t::LeafTarget)
    return Dict{String,Any}(
        "field"   => String(t.field),
        # JSON3 has no Symbol type — we encode Symbol indices as strings
        # prefixed with `:` so the round-trip preserves the type.
        "indices" => [_format_index(x) for x in t.indices],
        "type"    => String(t.type),
        "min"     => t.min,
        "max"     => t.max,
        "step"    => t.step,
        "label"   => t.label)
end

function _dict_to_spec(d::AbstractDict)
    targets = LeafTarget[]
    for td in get(d, "targets", [])
        push!(targets, _dict_to_target(Dict(string(k) => v for (k, v) in td)))
    end
    return ScenarioSpec(
        name       = String(d["name"]),
        method     = Symbol(d["method"]),
        n_variants = Int(d["n_variants"]),
        seed       = Int(d["seed"]),
        targets    = targets)
end

function _dict_to_target(d::AbstractDict)
    raw_indices = d["indices"]
    parsed = Tuple(_parse_index(x) for x in raw_indices)
    step = haskey(d, "step") ? d["step"] : nothing
    return LeafTarget(
        Symbol(d["field"]),
        parsed;
        type  = Symbol(d["type"]),
        min   = Float64(d["min"]),
        max   = Float64(d["max"]),
        step  = step === nothing ? nothing : Float64(step),
        label = String(get(d, "label", "")))
end

# JSON has no Symbol type, so we encode Symbol indices as strings starting
# with ":" — round-trip preserves the type. Plain integer/float strings are
# parsed back to their numeric types so that e.g. `(:NL, 2050)` round-trips
# through both JSON and the DuckDB `(:NL|2050)` encoding.
function _parse_index(s::AbstractString)
    startswith(s, ":") && return Symbol(SubString(s, 2))
    iv = tryparse(Int, s)
    iv === nothing || return iv
    fv = tryparse(Float64, s)
    fv === nothing || return fv
    return String(s)
end
_parse_index(x::Integer) = Int(x)
_parse_index(x::Real) = Float64(x)
_parse_index(x::Symbol) = x
_parse_index(x) = x

_format_index(x::Symbol) = ":" * String(x)
_format_index(x) = x

# -----------------------------------------------------------------------------
# DataFrame views
# -----------------------------------------------------------------------------

function _samples_dataframe(result::ScenarioResult)
    n, k = size(result.samples)
    df = DataFrame(variant_id = 1:n)
    for j in 1:k
        col = Symbol(result.spec.targets[j].label)
        df[!, col] = result.samples[:, j]
    end
    return df
end

function _results_dataframe(result::ScenarioResult)
    return DataFrame(
        variant_id    = [v.variant_id for v in result.variants],
        objective     = [v.objective for v in result.variants],
        term_status   = [v.term_status for v in result.variants],
        primal_status = [v.primal_status for v in result.variants],
        worker_pid    = [v.worker_pid for v in result.variants],
        build_seconds = [v.build_seconds for v in result.variants],
        apply_seconds = [v.apply_seconds for v in result.variants],
        solve_seconds = [v.solve_seconds for v in result.variants],
        error         = [v.error === nothing ? "" : v.error for v in result.variants])
end

function _combined_dataframe(result::ScenarioResult)
    samples_df = _samples_dataframe(result)
    results_df = _results_dataframe(result)
    return innerjoin(samples_df, results_df, on = :variant_id)
end

function _dataframe_to_samples(spec::ScenarioSpec, df::DataFrame)
    n = nrow(df); k = length(spec.targets)
    samples = Matrix{Float64}(undef, n, k)
    for j in 1:k
        col = Symbol(spec.targets[j].label)
        hasproperty(df, col) || throw(ArgumentError("samples.csv missing column $col"))
        samples[:, j] = Float64.(df[!, col])
    end
    return samples
end

function _dataframe_to_variants(spec::ScenarioSpec, df::DataFrame, samples::Matrix{Float64})
    variants = VariantResult[]
    for r in eachrow(df)
        # Re-attach the leaf values for this variant from the sample matrix
        # (samples.csv is the source of truth for what was perturbed).
        leaf_vals = samples[Int(r.variant_id), :]
        err_raw = r.error
        err = (err_raw === missing || (err_raw isa AbstractString && isempty(err_raw))) ?
              nothing : String(err_raw)
        push!(variants, VariantResult(
            variant_id    = Int(r.variant_id),
            leaf_values   = leaf_vals,
            objective     = Float64(r.objective),
            term_status   = String(r.term_status),
            primal_status = String(r.primal_status),
            worker_pid    = Int(r.worker_pid),
            build_seconds = Float64(r.build_seconds),
            apply_seconds = Float64(r.apply_seconds),
            solve_seconds = Float64(r.solve_seconds),
            error         = err))
    end
    return variants
end

# -----------------------------------------------------------------------------
# Index serialisation helpers (used by DuckDB)
# -----------------------------------------------------------------------------

_indices_to_str(idx::Tuple) = "(" * join(_format_index.(idx), "|") * ")"

function _str_to_indices(s::AbstractString)
    s == "()" && return ()
    stripped = strip(s, ['(', ')'])
    parts = split(stripped, '|')
    return Tuple(_parse_index(p) for p in parts)
end
