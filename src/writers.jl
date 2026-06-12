# =============================================================================
# writers.jl — Phase 7: parquet + CSV result writers
#
# Mirrors IESA-Opt 1.0 Mapping XML files in `Mappings/`:
#   BatchSolve_<varname>_Parquet.xml  → write_<varname>_parquet
#   BatchSolve_<varname>_CSV.xml      → write_<varname>_csv
#
# Output schema convention (long format, one row per indexed value):
#   - Columns: index names + "value" (Float64)
#   - File names match IESA-Opt 1.0 for direct diff
#
# Top-level entry point: `write_parquet_results(rr, vars, md, out_dir;
#                                                 only=nothing, mode=:fh|:ts)`
#
# Parquet2 writes real parquet files for IESA-Opt 1.0-compatible comparisons. CSV
# sidecars are still written for quick inspection and diffing.
# =============================================================================

using Printf
using Parquet2

# ============================================================================
# Generic dispatcher
# ============================================================================

"""
    write_parquet_results(rr, vars, md, out_dir; only=nothing, mode=:fh)

Write all IESA-Opt 1.0-compatible result tables for a single solve to `out_dir`.

Arguments:
  - `rr`     : `RunResult` (provides solve metadata + objective)
  - `vars`   : `AnnualVars` (provides JuMP variable handles)
  - `md`     : `ModelData`
  - `out_dir`: target directory (created if missing)
  - `only`   : optional `Vector{Symbol}` of writer names to run (subset)
  - `mode`   : `:fh` (write `*` files) or `:ts` (write `*_TS` files)

Returns a `Dict{Symbol,String}` mapping writer name → full output path.
"""
function write_parquet_results(rr::RunResult, vars::AnnualVars, md::ModelData,
                                out_dir::AbstractString;
                                only::Union{Nothing,Vector{Symbol}} = nothing,
                                mode::Symbol = :fh)
    mkpath(out_dir)
    written = Dict{Symbol,String}()

    # Annual writers (always)
    annual_writers = Dict{Symbol,Function}(
        :tech_use         => write_tech_use_parquet,
        :techStock        => write_techStock_parquet,
        :totalCosts       => write_totalCosts_parquet,
        :CO2_price        => write_CO2_price_parquet,
        :cost_breakdown   => write_cost_breakdown_parquet,
        :cluster_map      => write_cluster_map_parquet,
    )
    for (name, fn) in annual_writers
        only === nothing || name in only || continue
        path = joinpath(out_dir, string(name) * ".parquet")
        try
            if name == :totalCosts
                written[name] = fn(vars, md, path, rr.objective_value)
            else
                written[name] = fn(vars, md, path)
            end
        catch err
            @warn "Writer $name failed" err = err
        end
    end

    # Hourly / TS writers (only if vars have hourly fields populated)
    if mode == :fh && vars.tech_useHourly !== nothing
        path = joinpath(out_dir, "tech_use_h.parquet")
        written[:tech_use_h] = write_tech_useHourly_parquet(vars, md, path; mode = :fh)
    elseif mode == :ts && vars.tech_useHourly_TS !== nothing
        path = joinpath(out_dir, "tech_use_TS.parquet")
        written[:tech_use_TS] = write_tech_useHourly_parquet(vars, md, path; mode = :ts)
    end

    # Run statistics (always)
    rs_path = joinpath(out_dir, "run_statistics.parquet")
    try
        written[:run_statistics] = write_run_statistics_parquet(rr, rs_path)
    catch err
        @warn "Writer run_statistics failed" err = err
    end

    return written
end

# ============================================================================
# Low-level table writer
# ============================================================================

"""
    _write_table(df::DataFrame, path::AbstractString)

Write `df` to `path`. Uses Parquet2 for `.parquet` files and also writes a
CSV sidecar with the same base name. Symbol columns are written as strings so
the parquet schema is directly comparable with IESA-Opt 1.0 output.
"""
function _write_table(df::DataFrames.DataFrame, path::AbstractString)
    ext = lowercase(splitext(path)[2])
    if ext == ".parquet"
        parquet_df = _parquet_compatible_table(df)
        csv_path = splitext(path)[1] * ".csv"
        try
            Parquet2.writefile(path, parquet_df)
            CSV.write(csv_path, parquet_df)
            return path
        catch err
            @warn "Parquet2.writefile failed — falling back to CSV only" path = path err = err
            CSV.write(csv_path, parquet_df)
            return csv_path
        end
    else
        CSV.write(path, df)
        return path
    end
end

function _parquet_compatible_table(df::DataFrames.DataFrame)
    out = copy(df)
    for colname in names(out)
        col = out[!, colname]
        Base.nonmissingtype(eltype(col)) <: Symbol || continue
        converted = Vector{Union{Missing,String}}(undef, length(col))
        for i in eachindex(col)
            value_i = col[i]
            converted[i] = ismissing(value_i) ? missing : String(value_i)
        end
        out[!, colname] = converted
    end
    return out
end

# ============================================================================
# Annual writers
# ============================================================================

# Iterate values of a DenseAxisArray defensively (handles missing fields)
function _collect_axis_array(arr, axes_names::Tuple, period_filter = nothing)
    rows = Tuple[]
    if arr === nothing
        return rows
    end
    for idx in Iterators.product(JuMP.axes(arr)...)
        if period_filter !== nothing
            ps_idx = findfirst(==(:period), axes_names)
            ps_idx !== nothing && !(idx[ps_idx] in period_filter) && continue
        end
        try
            v = value(arr[idx...])
            push!(rows, (idx..., v))
        catch
            # variable might not exist for this combination
        end
    end
    return rows
end

function write_tech_use_parquet(vars::AnnualVars, md::ModelData, path::AbstractString)
    df = DataFrames.DataFrame(tech = Symbol[], period = Int[], value = Float64[])
    for t in md.sets.tech_balancers, ps in md.sets.periods_solve
        v = value(vars.tech_use[t, ps])
        push!(df, (t, ps, v))
    end
    return _write_table(df, path)
end

function write_techStock_parquet(vars::AnnualVars, md::ModelData, path::AbstractString)
    df = DataFrames.DataFrame(tech = Symbol[], period = Int[], value = Float64[])
    for t in md.sets.technologies, ps in md.sets.periods_solve
        v = value(vars.techStock[t, ps])
        push!(df, (t, ps, v))
    end
    return _write_table(df, path)
end

function write_totalCosts_parquet(vars::AnnualVars, md::ModelData, path::AbstractString, objective_value::Real)
    df = DataFrames.DataFrame(period = Int[], value = Float64[])
    ps = length(md.sets.periods_solve) == 1 ? only(md.sets.periods_solve) : 0
    push!(df, (ps, Float64(objective_value)))
    return _write_table(df, path)
end

function write_CO2_price_parquet(vars::AnnualVars, md::ModelData, path::AbstractString)
    # IESA-Opt 1.0 emits dual of the emission cap constraint per period.  We expose an
    # empty placeholder DataFrame — downstream code can populate from
    # `shadow_price(constraint_by_name(...))` once we tag the emission cap constraints.
    df = DataFrames.DataFrame(period = Int[], value = Float64[])
    return _write_table(df, path)
end

function write_cluster_map_parquet(vars::AnnualVars, md::ModelData, path::AbstractString)
    df = DataFrames.DataFrame(calendar_day = String[], rep_day = Float64[])
    for d in sort(collect(keys(md.params.mapDay_repDay)))
        push!(df, (string(d), Float64(md.params.mapDay_repDay[d])))
    end
    return _write_table(df, path)
end

function _solvalue(var)
    try
        return Float64(value(var))
    catch
        return 0.0
    end
end

function _push_cost!(df::DataFrames.DataFrame, tech::Symbol, period::Int, component::String, cost::Float64)
    abs(cost) <= 1e-9 && return nothing
    push!(df, (tech, period, component, cost))
    return nothing
end

function write_cost_breakdown_parquet(vars::AnnualVars, md::ModelData, path::AbstractString)
    s = md.sets
    p = md.params
    df = DataFrames.DataFrame(tech = Symbol[], period = Int[], component = String[], cost_MEUR = Float64[])
    lifetime_weight = Dict{Tuple{Symbol,Int},Float64}()
    for ((t_life, _jp, ps_life), w) in p.InvMat_lifeTime
        lifetime_weight[(t_life, ps_life)] = get(lifetime_weight, (t_life, ps_life), 0.0) + w
    end

    for ps in s.periods_solve
        sdf = get(p.social_discount_factor, ps, 1.0)
        sdf == 0.0 && continue
        prev_ps = _prev_period(s.periods_solve, ps)

        for t in s.technologies
            crf = get(p.CRF, t, 0.0)

            capex = 0.0
            for jp in s.periods_solve
                w = get(p.InvMat_lifeTime, (t, jp, ps), 0.0)
                w == 0.0 && continue
                cost = get(p.inv_cost, (t, jp), 0.0)
                (cost == 0.0 || crf == 0.0) && continue
                capex += sdf * w * _solvalue(vars.cap_investments[t, jp]) * cost * crf
            end
            _push_cost!(df, t, ps, "capex", capex)

            retrofit = 0.0
            w_lifetime = get(lifetime_weight, (t, ps), 0.0)
            if w_lifetime != 0.0 && crf != 0.0
                for it in s.technologies
                    rv = _solvalue(vars.retrofitting[it, t, ps])
                    rv == 0.0 && continue
                    retrofit += sdf * w_lifetime * rv * crf * get(p.retrofit_cost, (it, t, ps), 0.0)
                end
            end
            _push_cost!(df, t, ps, "retrofit", retrofit)

            salvage_value = get(p.Salvage_value, t, 0.0)
            inv_cost = get(p.inv_cost, (t, ps), 0.0)
            if salvage_value != 0.0 && inv_cost != 0.0 && crf != 0.0
                ed_delta = _solvalue(vars.eco_decommisioning[t, ps])
                if prev_ps !== nothing
                    ed_delta -= _solvalue(vars.eco_decommisioning[t, prev_ps])
                end
                salvage = -sdf * ed_delta * salvage_value * inv_cost * crf
                _push_cost!(df, t, ps, "salvage", salvage)
            end

            fom = sdf * _solvalue(vars.techStock[t, ps]) * get(p.fom_cost, (t, ps), 0.0)
            _push_cost!(df, t, ps, "fom", fom)
        end

        for t in s.tech_balancers
            use = _solvalue(vars.tech_use[t, ps])
            vom = sdf * use * get(p.vom_cost, (t, ps), 0.0)
            _push_cost!(df, t, ps, "vom", vom)
        end

        ainEU = :var"Electricity EU"
        if vars.tech_useHourly_TS !== nothing
            tuh = vars.tech_useHourly_TS
            for thh in s.tech_hourlyDispatch
                get(p.tech_category, thh, Symbol("")) == :var"XC Trade" || continue
                is_import = get(p.tech_subsector, thh, Symbol("")) == :var"Power EU"
                is_export = get(p.tech_sector, thh, Symbol("")) == :var"Power EU"
                (is_import || is_export) || continue
                cost = 0.0
                for hc in s.hours_cluster
                    w = get(p.clusterHourWeight, hc, 1.0)
                    price = get(p.interconnectedHourly_prices_cluster, (hc, ainEU, ps), 0.0)
                    cost += sdf * w * _solvalue(tuh[hc, thh, ps]) * price
                end
                is_import && _push_cost!(df, thh, ps, "import", cost)
                is_export && _push_cost!(df, thh, ps, "export", -cost)
            end
        elseif vars.tech_useHourly !== nothing
            tuh = vars.tech_useHourly
            for thh in s.tech_hourlyDispatch
                get(p.tech_category, thh, Symbol("")) == :var"XC Trade" || continue
                is_import = get(p.tech_subsector, thh, Symbol("")) == :var"Power EU"
                is_export = get(p.tech_sector, thh, Symbol("")) == :var"Power EU"
                (is_import || is_export) || continue
                cost = 0.0
                for h in s.hours
                    price = get(p.interconnectedHourly_prices, (h, ainEU, ps), 0.0)
                    cost += sdf * _solvalue(tuh[h, thh, ps]) * price
                end
                is_import && _push_cost!(df, thh, ps, "import", cost)
                is_export && _push_cost!(df, thh, ps, "export", -cost)
            end
        end

        if vars.deltaU_CHP_TS !== nothing
            du = vars.deltaU_CHP_TS
            for t in s.tech_hourlyCHPflex
                vc = get(p.vom_cost, (t, ps), 0.0)
                vc == 0.0 && continue
                cost = 0.0
                for hc in s.hours_cluster
                    cost += sdf * get(p.clusterHourWeight, hc, 1.0) * _solvalue(du[hc, t, ps]) * vc
                end
                _push_cost!(df, t, ps, "flex_vom", cost)
            end
        elseif vars.deltaU_CHP !== nothing
            du = vars.deltaU_CHP
            for t in s.tech_hourlyCHPflex
                vc = get(p.vom_cost, (t, ps), 0.0)
                vc == 0.0 && continue
                cost = sum(sdf * _solvalue(du[h, t, ps]) * vc for h in s.hours)
                _push_cost!(df, t, ps, "flex_vom", cost)
            end
        end

        if vars.deltaS_shed_TS !== nothing
            ds = vars.deltaS_shed_TS
            for t in s.tech_shedding
                vc = get(p.vom_cost, (t, ps), 0.0)
                pen = get(p.shed_penalty, t, 0.0)
                flex_vom = 0.0
                shed_penalty = 0.0
                for hc in s.hours_cluster
                    w = get(p.clusterHourWeight, hc, 1.0)
                    dv = _solvalue(ds[hc, t, ps])
                    flex_vom += sdf * w * dv * vc
                    shed_penalty += sdf * w * (-dv) * pen
                end
                _push_cost!(df, t, ps, "flex_vom", flex_vom)
                _push_cost!(df, t, ps, "shed_penalty", shed_penalty)
            end
        elseif vars.deltaS_shed !== nothing
            ds = vars.deltaS_shed
            for t in s.tech_shedding
                vc = get(p.vom_cost, (t, ps), 0.0)
                pen = get(p.shed_penalty, t, 0.0)
                flex_vom = sum(sdf * _solvalue(ds[h, t, ps]) * vc for h in s.hours)
                shed_penalty = sum(sdf * (-_solvalue(ds[h, t, ps])) * pen for h in s.hours)
                _push_cost!(df, t, ps, "flex_vom", flex_vom)
                _push_cost!(df, t, ps, "shed_penalty", shed_penalty)
            end
        end
    end

    return _write_table(df, path)
end

# ============================================================================
# Hourly / TS writer (combined; dispatch on mode)
# ============================================================================

function write_tech_useHourly_parquet(vars::AnnualVars, md::ModelData, path::AbstractString;
                                       mode::Symbol = :fh)
    if mode == :fh
        tuh = vars.tech_useHourly
        tuh === nothing && error("tech_useHourly is nothing — call build_fh_lp! and solve first")
        df = DataFrames.DataFrame(hour = Int[], tech = Symbol[], period = Int[], value = Float64[])
        for h in md.sets.hours, th in md.sets.tech_hourlyDispatch, ps in md.sets.periods_solve
            try
                v = value(tuh[h, th, ps])
                push!(df, (h, th, ps, v))
            catch; end
        end
        return _write_table(df, path)
    elseif mode == :ts
        tuh = vars.tech_useHourly_TS
        tuh === nothing && error("tech_useHourly_TS is nothing — call build_ts_lp! and solve first")
        df = DataFrames.DataFrame(hc = Int[], tech = Symbol[], period = Int[], value = Float64[])
        for hc in md.sets.hours_cluster, th in md.sets.tech_hourlyDispatch, ps in md.sets.periods_solve
            try
                v = value(tuh[hc, th, ps])
                push!(df, (hc, th, ps, v))
            catch; end
        end
        return _write_table(df, path)
    else
        error("Unknown mode: $mode")
    end
end

# ============================================================================
# Run statistics
# ============================================================================

function write_run_statistics_parquet(rr::RunResult, path::AbstractString)
    df = DataFrames.DataFrame(
        timestamp          = [string(rr.timestamp)],
        mode               = [string(rr.mode)],
        termination_status = [rr.termination_status],
        primal_status      = [rr.primal_status],
        program_status     = [rr.program_status],
        objective          = [rr.objective_value],
        solve_seconds      = [rr.solve_seconds],
        total_seconds      = [rr.total_seconds],
        n_rows             = [rr.n_rows],
        n_cols             = [rr.n_cols],
        n_repDays          = [rr.n_repDays],
        hoursPer_day       = [rr.hoursPer_day],
        clustering         = [string(rr.clustering_approach)],
    )
    return _write_table(df, path)
end
