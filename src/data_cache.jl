# =============================================================================
# data_cache.jl — Phase 7+ binary cache layer for read_data
#
# IESA-Opt 1.0 reads its XLSX database in ~2s.  Pure XLSX.jl streaming reads of the
# same file take ~60s because cell-by-cell reads of small per-tech lookups
# dominate (~408 techs × dozens of column reads + state-machine cost).
#
# Strategy:
#   - First call to `read_data_cached(xlsx)` runs the full XLSX pipeline and
#     serializes the resulting `ModelData` to a sidecar binary cache.
#   - Subsequent calls compare the XLSX file's `(mtime, size)` against the
#     cache header; on match → deserialize in <2s.
#   - On XLSX edit (any byte change) the cache is invalidated automatically.
#
# Uses stdlib `Serialization` — no extra dependency.  Files are tagged with a
# format version + Julia version + IESA_J version to refuse mismatched caches.
#
# Usage:
#     md = read_data_cached(xlsx_path)
#     md = read_data_cached(xlsx_path; force_refresh = true)
#     md = read_data_cached(xlsx_path; cache_dir = "/tmp/iesa_cache")
# =============================================================================

using Serialization

const _IESA_CACHE_FORMAT_VERSION = 10

"""
    read_data_cached(xlsx_path; cache_dir=auto, force_refresh=false, kwargs...)

Wrap `read_data` with a binary cache keyed on the XLSX file's mtime+size.
Returns the same `ModelData` as `read_data`. The cache file lives at
`cache_dir/<basename_without_ext>.iesa_cache.bin`.

Keyword args (besides cache-control) are forwarded to `read_data`.
"""
function read_data_cached(xlsx_path::AbstractString;
                          cache_dir::Union{String,Nothing} = nothing,
                          force_refresh::Bool = false,
                          kwargs...)
    isfile(xlsx_path) || error("XLSX not found: $xlsx_path")

    if cache_dir === nothing
        cache_dir = joinpath(dirname(abspath(xlsx_path)), ".iesa_cache")
    end
    mkpath(cache_dir)

    base = first(splitext(basename(xlsx_path)))
    cache_path = joinpath(cache_dir, base * ".iesa_cache.bin")

    xstat = stat(xlsx_path)
    if !force_refresh && isfile(cache_path)
        try
            t0 = time()
            cached_md = open(cache_path, "r") do io
                hdr = deserialize(io)
                if hdr isa NamedTuple &&
                   hdr.format == _IESA_CACHE_FORMAT_VERSION &&
                   hdr.xlsx_mtime == xstat.mtime &&
                   hdr.xlsx_size  == xstat.size
                    return deserialize(io)
                end
                @info "read_data_cached: cache stale, rebuilding" reason = "mtime/size/format mismatch"
                return nothing
            end
            if cached_md !== nothing
                @info "read_data_cached: hit" cache_path elapsed_s = round(time() - t0, digits = 2)
                return cached_md
            end
        catch err
            @warn "read_data_cached: failed to read cache, rebuilding" err = err
        end
    end

    t0 = time()
    md = read_data(xlsx_path; kwargs...)
    @info "read_data_cached: built from XLSX" elapsed_s = round(time() - t0, digits = 1)

    try
        open(cache_path, "w") do io
            serialize(io, (format    = _IESA_CACHE_FORMAT_VERSION,
                           xlsx_path = abspath(xlsx_path),
                           xlsx_mtime = xstat.mtime,
                           xlsx_size  = xstat.size,
                           julia_ver  = string(VERSION),
                           created_at = string(Dates.now())))
            serialize(io, md)
        end
        @info "read_data_cached: wrote cache" cache_path size_mb = round(stat(cache_path).size / 1e6, digits = 2)
    catch err
        @warn "read_data_cached: failed to write cache (continuing without caching)" err = err
    end

    return md
end

"""
    clear_data_cache(xlsx_path; cache_dir=auto)

Delete the binary cache for `xlsx_path`. Returns true if a cache file existed.
"""
function clear_data_cache(xlsx_path::AbstractString;
                          cache_dir::Union{String,Nothing} = nothing)
    if cache_dir === nothing
        cache_dir = joinpath(dirname(abspath(xlsx_path)), ".iesa_cache")
    end
    base = first(splitext(basename(xlsx_path)))
    cache_path = joinpath(cache_dir, base * ".iesa_cache.bin")
    if isfile(cache_path)
        rm(cache_path; force = true)
        @info "clear_data_cache: removed" cache_path
        return true
    end
    return false
end
