# =============================================================================
# clustering.jl - representative-day clustering (TS mode) with TulipaClustering.jl
# =============================================================================

using Distances: CosineDist, Euclidean, SqEuclidean
using Statistics: mean
using Parquet2
using DataFrames: DataFrame, eachrow
import TulipaClustering

const _HOURS_PER_DAY = 24
const _N_DAYS = 365
const _TULIPA_METHODS = (:k_medoids, :k_means)
const _TULIPA_WEIGHT_TYPES = (:convex, :conical, :conical_bounded, :dirac)

"""
    build_temporal_clusters!(md::ModelData) -> Nothing

Select representative days and their blending weights with TulipaClustering.jl
and populate all `*_cluster` parameters. Clears prior cluster state first.
"""
function build_temporal_clusters!(md::ModelData)
    params = md.params
    n_rep_days = params.n_repDays
    slots_per_day = params.hoursPer_day_cluster
    n_rep_days > 0 || error("n_repDays must be > 0")
    (slots_per_day > 0 && _HOURS_PER_DAY % slots_per_day == 0) ||
        error("hoursPer_day_cluster must divide $_HOURS_PER_DAY (got $slots_per_day)")
    params.ts_extremePeriods &&
        @warn "ts_extremePeriods is ignored: Tulipa clustering has no separate extreme-day step"

    _reset_cluster_state!(md)
    targets, names, series = _clustering_series(params)

    if isempty(params.external_clusterMap_path)
        weights, profiles = _run_tulipa_clustering(params, names, series, n_rep_days)
        method = params.clustering_approach
    else
        assignments, effective_rep_days = _load_external_cluster_map(params.external_clusterMap_path, _N_DAYS)
        if effective_rep_days != n_rep_days
            @info "build_temporal_clusters!: external_clusterMap overrides n_repDays" requested = n_rep_days loaded = effective_rep_days
            params.n_repDays = n_rep_days = effective_rep_days
        end
        weights = zeros(Float64, _N_DAYS, n_rep_days)
        for (day, representative) in enumerate(assignments)
            weights[day, representative] = 1.0
        end
        profiles = _weighted_mean_rep_profiles(series, weights)
        method = :external_map
    end

    _set_cluster_index_sets!(md, n_rep_days, slots_per_day)
    _set_day_weights!(md, weights, slots_per_day)
    _write_cluster_profiles!(params, targets, profiles, slots_per_day)
    _preserve_annual_profile_energy!(md)
    _resolve_indirect_cluster_profiles!(md)
    compute_flex_TS_helpers!(md)

    @info "build_temporal_clusters! complete" method n_repDays = length(md.sets.repDays) hours_cluster = length(md.sets.hours_cluster)
    return nothing
end

function _reset_cluster_state!(md::ModelData)
    sets, params = md.sets, md.params
    empty!(sets.hours_cluster)
    empty!(sets.repDays)
    empty!(sets.hours_inDay_cluster)
    empty!(params.mapDay_repDay)
    empty!(params.dayWeight)
    empty!(params.clusterHourWeight)
    empty!(params.repDay_of_clusterHour)
    empty!(params.intradaySlot_of_clusterHour)
    empty!(params.dayMix_weight)
    empty!(params.hourly_profiles_cluster)
    empty!(params.hourly_profiles_clusterMedoid)
    empty!(params.hourly_profiles_clusterMin)
    empty!(params.hourly_profiles_clusterMean)
    empty!(params.hourly_profiles_clusterStd)
    empty!(params.hourly_profiles_clusterPercentile)
    empty!(params.hourly_profiles_clusterRankPct)
    empty!(params.hourly_profiles_clusterAutoBlend)
    empty!(params.hourly_profiles_clusterCapBound)
    empty!(params.interconnectedHourly_prices_cluster)
end

function _profile_types_in_profiles(profiles::Dict{Tuple{Int,Symbol},Float64})
    profile_types = Set{Symbol}()
    for ((_, profile_type), _) in profiles
        push!(profile_types, profile_type)
    end
    return sort!(collect(profile_types); by = String)
end

function _clustering_series(params::ModelParams)
    profile_types = _profile_types_in_profiles(params.hourly_profilesReadOrig)
    prices = sort!(collect(Set((activity, period) for ((_, activity, period), _) in params.interconnectedHourly_pricesOrig)))
    targets = Union{Symbol,Tuple{Symbol,Int}}[profile_types; prices]
    isempty(targets) && error("No hourly profiles to cluster")
    names = [target isa Symbol ? String(target) : "price|$(target[1])|$(target[2])" for target in targets]
    columns = Dict(target => index for (index, target) in enumerate(targets))
    n_hours = _N_DAYS * _HOURS_PER_DAY
    series = zeros(Float64, n_hours, length(targets))
    for ((hour, profile_type), value) in params.hourly_profilesReadOrig
        1 <= hour <= n_hours && (series[hour, columns[profile_type]] = value)
    end
    for ((hour, activity, period), value) in params.interconnectedHourly_pricesOrig
        1 <= hour <= n_hours && (series[hour, columns[(activity, period)]] = value)
    end
    return targets, names, series
end

_default_clustering_distance(::Symbol) = :cosine

function _tulipa_distance(name::Symbol)
    name === :cosine      && return CosineDist()
    name === :euclidean   && return Euclidean()
    name === :sqeuclidean && return SqEuclidean()
    error("Unsupported clustering_distance :$name; use :cosine, :euclidean or :sqeuclidean")
end

function _run_tulipa_clustering(params::ModelParams, names::Vector{String}, series::Matrix{Float64}, n_rep_days::Int)
    method = params.clustering_approach
    method in _TULIPA_METHODS ||
        error("Unsupported clustering_approach :$method; use one of $(_TULIPA_METHODS)")
    weight_type = params.dayMix_weightType === :auto ? :convex : params.dayMix_weightType
    weight_type in _TULIPA_WEIGHT_TYPES ||
        error("Unsupported dayMix_weightType :$weight_type; use :auto or one of $(_TULIPA_WEIGHT_TYPES)")
    distance = _tulipa_distance(params.clustering_distance)
    n_rep_days <= _N_DAYS || error("n_repDays ($n_rep_days) exceeds the $_N_DAYS days in the year")

    n_hours, n_series = size(series)
    scale = [max_value > 0 ? max_value : 1.0 for max_value in (maximum(abs, view(series, :, column)) for column in 1:n_series)]
    data = DataFrame(
        period       = repeat(1:_N_DAYS; inner = _HOURS_PER_DAY, outer = n_series),
        timestep     = repeat(1:_HOURS_PER_DAY; outer = _N_DAYS * n_series),
        profile_name = repeat(names; inner = n_hours),
        value        = vec(series ./ scale'),
    )

    Random.seed!(params.clustering_seed)
    result = TulipaClustering.find_representative_periods(data, n_rep_days; method, distance)
    TulipaClustering.fit_rep_period_weights!(result; weight_type)

    columns = Dict(name => index for (index, name) in enumerate(names))
    profiles = zeros(Float64, _HOURS_PER_DAY, n_rep_days, n_series)
    for row in eachrow(result.profiles)
        column = columns[row.profile_name]
        profiles[row.timestep, row.rep_period, column] = row.value * scale[column]
    end
    return Matrix(result.weight_matrix), profiles
end

function _weighted_mean_rep_profiles(series::Matrix{Float64}, weights::Matrix{Float64})
    n_days, n_rep_days = size(weights)
    profiles = zeros(Float64, _HOURS_PER_DAY, n_rep_days, size(series, 2))
    for representative in 1:n_rep_days
        total = sum(view(weights, :, representative))
        total > 0 || continue
        for day in 1:n_days
            weight = weights[day, representative]
            weight > 0 || continue
            rows = ((day - 1) * _HOURS_PER_DAY + 1):(day * _HOURS_PER_DAY)
            profiles[:, representative, :] .+= (weight / total) .* view(series, rows, :)
        end
    end
    return profiles
end

function _set_cluster_index_sets!(md::ModelData, n_rep_days::Int, slots_per_day::Int)
    sets, params = md.sets, md.params
    sets.hours_inDay_cluster = collect(1:slots_per_day)
    sets.repDays             = collect(1:n_rep_days)
    sets.hours_cluster       = collect(1:(n_rep_days * slots_per_day))
    for cluster_hour in sets.hours_cluster
        params.repDay_of_clusterHour[cluster_hour]       = div(cluster_hour - 1, slots_per_day) + 1
        params.intradaySlot_of_clusterHour[cluster_hour] = mod(cluster_hour - 1, slots_per_day) + 1
    end

    hours_per_quarter = max(params.hoursPer_quarter_cluster, 1)
    sets.q_hourWindow_cluster = collect(1:max(1, Int(floor(n_rep_days * slots_per_day / hours_per_quarter))))
    empty!(params.quarterPer_clusterHour)
    for cluster_hour in sets.hours_cluster
        params.quarterPer_clusterHour[cluster_hour] = ceil(Int, cluster_hour / hours_per_quarter)
    end
    return nothing
end

function _set_day_weights!(md::ModelData, weights::Matrix{Float64}, slots_per_day::Int)
    params = md.params
    for day in axes(weights, 1)
        best_representative, best_weight = 0, 0.0
        for representative in axes(weights, 2)
            weight = weights[day, representative]
            weight > 0 || continue
            params.dayMix_weight[(day, representative)] = weight
            params.dayWeight[representative] = get(params.dayWeight, representative, 0.0) + weight
            weight > best_weight && ((best_representative, best_weight) = (representative, weight))
        end
        best_representative > 0 && (params.mapDay_repDay[day] = best_representative)
    end
    hours_per_slot = _HOURS_PER_DAY / slots_per_day
    for cluster_hour in md.sets.hours_cluster
        params.clusterHourWeight[cluster_hour] = get(params.dayWeight, params.repDay_of_clusterHour[cluster_hour], 0.0) * hours_per_slot
    end
    return nothing
end

function _write_cluster_profiles!(params::ModelParams, targets, profiles::Array{Float64,3}, slots_per_day::Int)
    hours_per_slot = _HOURS_PER_DAY ÷ slots_per_day
    for (column, target) in enumerate(targets), representative in axes(profiles, 2), slot in 1:slots_per_day
        cluster_hour = (representative - 1) * slots_per_day + slot
        value = mean(view(profiles, ((slot - 1) * hours_per_slot + 1):(slot * hours_per_slot), representative, column))
        if target isa Symbol
            params.hourly_profiles_cluster[(cluster_hour, target)] = value
        else
            params.interconnectedHourly_prices_cluster[(cluster_hour, target[1], target[2])] = value
        end
    end
    return nothing
end

# Annual-hourly links are equalities, so even small energy errors make the TS model infeasible.
function _preserve_annual_profile_energy!(md::ModelData)
    params = md.params
    annual = Dict{Symbol,Float64}()
    for ((hour, profile_type), value) in params.hourly_profilesReadOrig
        1 <= hour <= _N_DAYS * _HOURS_PER_DAY || continue
        annual[profile_type] = get(annual, profile_type, 0.0) + value
    end
    represented = Dict{Symbol,Float64}()
    for ((cluster_hour, profile_type), value) in params.hourly_profiles_cluster
        represented[profile_type] = get(represented, profile_type, 0.0) +
            get(params.clusterHourWeight, cluster_hour, 0.0) * value
    end
    for (profile_type, target) in annual
        current = get(represented, profile_type, 0.0)
        target == current && continue
        if abs(current) <= eps(Float64) * max(1.0, abs(target))
            @warn "Clustered profile has no representative energy to rescale" profile_type target
            continue
        end
        factor = target / current
        for cluster_hour in md.sets.hours_cluster
            key = (cluster_hour, profile_type)
            haskey(params.hourly_profiles_cluster, key) && (params.hourly_profiles_cluster[key] *= factor)
        end
    end
    return nothing
end

function _resolve_indirect_cluster_profiles!(md::ModelData)
    sets, params = md.sets, md.params
    isempty(sets.activities_indirect) && return nothing
    isempty(sets.hours_cluster)       && return nothing
    base_year = params.base_year

    consumers_of = Dict(activity => Tuple{Symbol,Float64}[] for activity in sets.activities_indirect)
    for ((technology, activity, period), coefficient) in params.activity_balances
        (period == base_year && coefficient < 0 && haskey(consumers_of, activity)) || continue
        profile_type = get(params.profileType_techRead, technology, Symbol(""))
        profile_type == Symbol("") && continue
        push!(consumers_of[activity], (profile_type, coefficient))
    end

    for activity in sets.activities_indirect
        consumers = consumers_of[activity]
        denominator = sum(last, consumers; init = 0.0)
        denominator == 0.0 && continue
        for cluster_hour in sets.hours_cluster
            numerator = sum(coefficient * get(params.hourly_profiles_cluster, (cluster_hour, profile_type), 0.0) for (profile_type, coefficient) in consumers)
            params.hourly_profiles_cluster[(cluster_hour, activity)] = numerator / denominator
        end
    end
    return nothing
end

"""
    _load_external_cluster_map(parquet_path::AbstractString, n_days::Int)
        -> (Vector{Int}, Int)

Read an IESA-Opt 1.0 cluster map with `calendar_day` and `rep_day` columns.
Require complete calendar coverage and renumber representatives to contiguous IDs.
This validation path uses hard assignments and averaged member-day profiles.
"""
function _load_external_cluster_map(parquet_path::AbstractString, n_days::Int)
    isfile(parquet_path) || error("external_clusterMap_path not found: $parquet_path")
    data = DataFrame(Parquet2.Dataset(parquet_path))
    "calendar_day" in names(data) || error("cluster_map parquet missing 'calendar_day' column ($parquet_path)")
    "rep_day"      in names(data) || error("cluster_map parquet missing 'rep_day' column ($parquet_path)")

    raw_assignments = Dict{Int,Int}()
    for row in eachrow(data)
        day_raw = row.calendar_day
        representative_raw = row.rep_day
        (day_raw === missing || representative_raw === missing) && continue
        day = day_raw isa AbstractString ? parse(Int, day_raw) : Int(day_raw)
        representative = representative_raw isa AbstractString ? parse(Int, representative_raw) : Int(round(Float64(representative_raw)))
        raw_assignments[day] = representative
    end
    length(raw_assignments) == n_days || error("cluster_map parquet has $(length(raw_assignments)) rows; expected $n_days")

    used = sort!(collect(Set(values(raw_assignments))))
    representative_remap = Dict(representative => index for (index, representative) in enumerate(used))
    assignments = Vector{Int}(undef, n_days)
    for day in 1:n_days
        haskey(raw_assignments, day) || error("cluster_map parquet missing calendar_day=$day")
        assignments[day] = representative_remap[raw_assignments[day]]
    end
    return assignments, length(used)
end