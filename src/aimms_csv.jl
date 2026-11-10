# ============================================================================
# AIMMS-compatible CSV result export
# ============================================================================
#
# Writes the CSV files produced by the IESA-Opt 1.0 (AIMMS) single-solve
# procedure, using the same file names, headers, quoting, row order and
# sparse/dense conventions so existing post-processing scripts can read them.
# Definitions follow IESA-Opt.ams (Ptech_useNet, Ptech_useHourlyNet,
# Ptech_useDailyNet, shadow_energyPrices, CO2_price_single) and the
# Mappings/SingleSolve_*.xml files.
#
# Representative-day (TS) results are expanded to calendar time steps through
# the `dayMix_weight` blend of representative days, and TS duals are divided by
# the representative weight so prices are per calendar step, like the
# full-hourly prices.
#
# Deliberate difference from AIMMS: `commodity_prices.CSV` holds the true
# average price. AIMMS sums `shadow_energyPrices` over all nodes and therefore
# multiplies every value by the number of nodes.

const AIMMS_CSV_FILES = (
    "totalCosts.CSV", "tech_UseNet.CSV", "tech_Stock.CSV", "cap_investments.CSV",
    "eco_decommisioning.CSV", "Salvage_value.CSV", "commodity_prices.CSV",
    "CO2_price.CSV", "deltaS_Shed.CSV", "deltaU_CHP.CSV", "tech_Use_h.CSV",
    "tech_Use_d.CSV", "prices_h.CSV", "prices_d.CSV",
)

_aimms_q(x) = "\"" * replace(string(x), "\"" => "\"\"") * "\""

function _aimms_num(x::Real)
    v = Float64(x)
    isfinite(v) || return "0"
    iszero(v) && return "0"
    if isinteger(v) && abs(v) < 1e15
        return string(Int64(v))
    end
    return replace(string(v), ".0e" => "e")
end

function _aimms_write_csv(rows_writer::Function, path::AbstractString, header::Vector{String})
    open(path, "w") do io
        println(io, join(_aimms_q.(header), ","))
        rows_writer(io)
    end
    return path
end

_aimms_row(io, labels, value) = (print(io, join(_aimms_q.(labels), ","), ",", _aimms_num(value), "\n"))

_aimms_values(x) = x === nothing ? nothing : JuMP.value.(x)

function _aimms_dual(model, name::AbstractString)
    con = try
        constraint_by_name(model, name)
    catch
        nothing
    end
    con === nothing && return nothing
    v = try
        JuMP.dual(con)
    catch
        NaN
    end
    return isfinite(v) ? Float64(v) : nothing
end

"""
    _aimms_calendar(md, mode) -> NamedTuple

Calendar time axis used by the hourly/daily AIMMS files. `hmix[h]` lists the
model time indices (with weights) that make up calendar step `h`, and
`dmix[d]` does the same for calendar day `d`. In FH mode these are identity
maps. In TS mode a calendar day is the `dayMix_weight` blend of representative
days (falling back to `mapDay_repDay`), so calendar sums equal the weighted
annual totals the model optimises.
"""
function _aimms_calendar(md::ModelData, mode::Symbol)
    s, p = md.sets, md.params
    days = collect(s.days)
    hmix = Dict{Int,Vector{Tuple{Int,Float64}}}()
    dmix = Dict{Int,Vector{Tuple{Int,Float64}}}()
    steps = Int[]
    step_day = Dict{Int,Int}()
    if mode == :ts
        slots = max(1, length(s.hours_inDay_cluster))
        for ((d, rd), w) in p.dayMix_weight
            w > 0 && push!(get!(dmix, d, Tuple{Int,Float64}[]), (rd, w))
        end
        for d in days
            haskey(dmix, d) && continue
            rd = get(p.mapDay_repDay, d, 0)
            rd > 0 && (dmix[d] = [(rd, 1.0)])
        end
        for d in days
            mix = get(dmix, d, nothing)
            mix === nothing && continue
            sort!(mix)
            for slot in 1:slots
                h = (d - 1) * slots + slot
                push!(steps, h)
                step_day[h] = d
                hmix[h] = [((rd - 1) * slots + slot, w) for (rd, w) in mix]
            end
        end
        return (; steps, days, step_day, hmix, dmix, slots)
    end
    for h in s.hours
        push!(steps, h)
        step_day[h] = get(p.dayPer_hour, h, 0)
        hmix[h] = [(h, 1.0)]
    end
    for d in days
        dmix[d] = [(d, 1.0)]
    end
    return (; steps, days, step_day, hmix, dmix, slots = max(1, p.hoursPer_day))
end

"""
    write_aimms_csv_results(model, vars, md, out_dir; mode, hourly_reports = true,
                            total_costs = nothing, progress = (args...) -> nothing)
        -> Dict{Symbol,String}

Write the 14 AIMMS-style result CSV files (`AIMMS_CSV_FILES`) into `out_dir`. The hourly files (`tech_Use_h`, `tech_Use_d`, `prices_h`,
`prices_d`) are only written when `hourly_reports` is true, as in AIMMS
(`HourlyReportValue = 'yes'`). Price files need duals; they are skipped with a
warning when the solver returned none.
"""
function write_aimms_csv_results(model::JuMP.Model, vars::AnnualVars, md::ModelData, out_dir::AbstractString;
                                 mode::Symbol, hourly_reports::Bool = true,
                                 total_costs::Union{Nothing,Real} = nothing,
                                 progress::Function = (args...) -> nothing)
    mkpath(out_dir)
    s, p = md.sets, md.params
    pss = s.periods_solve
    is_ts = mode == :ts
    written = Dict{Symbol,String}()
    cal = _aimms_calendar(md, mode)
    sdf(ps) = get(p.social_discount_factor, ps, 1.0)

    tech_use = _aimms_values(vars.tech_use)
    stock = _aimms_values(vars.techStock)
    invest = _aimms_values(vars.cap_investments)
    decom = _aimms_values(vars.eco_decommisioning)
    use_h = _aimms_values(is_ts ? vars.tech_useHourly_TS : vars.tech_useHourly)
    use_d = _aimms_values(is_ts ? vars.tech_useDaily_TS : vars.tech_useDaily)
    chp = _aimms_values(is_ts ? vars.deltaU_CHP_TS : vars.deltaU_CHP)
    shed = _aimms_values(is_ts ? vars.deltaS_shed_TS : vars.deltaS_shed)

    set_h = Set(s.tech_hourlyDispatch)
    set_d = Set(s.tech_dailyDispatch)
    set_b = Set(s.tech_balancers)
    set_chp = Set(s.tech_hourlyCHPflex)
    set_shed = Set(s.tech_shedding)

    # `i` below is a model time index: h in FH, hc in TS.
    model_day(i) = is_ts ? p.repDay_of_clusterHour[i] : get(p.dayPer_hour, i, 0)
    profiles = is_ts ? p.hourly_profiles_cluster : p.hourly_profiles
    daily_share(i) = is_ts ? Float64(cal.slots) : get(p.hoursPerDayEffective, i, Float64(p.hoursPer_day))

    function model_net(i, t, ps)
        v = 0.0
        if t in set_h
            use_h === nothing || (v += use_h[i, t, ps])
        elseif t in set_d
            use_d === nothing || (v += use_d[model_day(i), t, ps] / daily_share(i))
        elseif t in set_b && tech_use !== nothing
            v += tech_use[t, ps] * get(profiles, (i, get(p.profileType_tech, t, :Flat)), 0.0)
        end
        (chp !== nothing && t in set_chp) && (v += chp[i, t, ps])
        (shed !== nothing && t in set_shed) && (v += shed[i, t, ps])
        return v
    end
    hourly_net(h, t, ps) = sum(w * model_net(i, t, ps) for (i, w) in cal.hmix[h]; init = 0.0)
    calendar_value(arr, h, t, ps) = sum(w * arr[i, t, ps] for (i, w) in cal.hmix[h]; init = 0.0)

    # Number of calendar steps each model time index stands for.
    step_weight = Dict{Int,Float64}()
    for h in cal.steps, (i, w) in cal.hmix[h]
        step_weight[i] = get(step_weight, i, 0.0) + w
    end
    function annual_delta(arr, members, t, ps)
        (arr === nothing || !(t in members)) && return 0.0
        return sum(w * arr[i, t, ps] for (i, w) in step_weight; init = 0.0)
    end

    function emit(name::Symbol, file::String, header::Vector{String}, body::Function)
        path = joinpath(out_dir, file)
        _write_result_with_progress!(written, name, path, progress) do
            _aimms_write_csv(body, path, header)
        end
    end

    obj = total_costs === nothing ? JuMP.objective_value(model) : total_costs
    emit(:aimms_totalCosts, "totalCosts.CSV", ["totalCosts"], io -> print(io, _aimms_num(obj), "\n"))

    emit(:aimms_tech_UseNet, "tech_UseNet.CSV", ["technology", "period", "techUseNet"], io -> begin
        for t in s.technologies, ps in pss
            v = (tech_use !== nothing && t in set_b) ? tech_use[t, ps] : 0.0
            v += annual_delta(chp, set_chp, t, ps) + annual_delta(shed, set_shed, t, ps)
            iszero(v) || _aimms_row(io, (t, ps), v)
        end
    end)

    emit(:aimms_tech_Stock, "tech_Stock.CSV", ["technology", "period", "techStocks"], io -> begin
        for t in s.technologies, ps in pss
            v = stock[t, ps]
            iszero(v) || _aimms_row(io, (t, ps), v)
        end
    end)

    emit(:aimms_cap_investments, "cap_investments.CSV", ["technology", "period", "cap_investments"], io -> begin
        for t in s.technologies, ps in pss
            v = invest[t, ps]
            iszero(v) || _aimms_row(io, (t, ps), v)
        end
    end)

    emit(:aimms_eco_decommisioning, "eco_decommisioning.CSV", vcat(["tech_id"], string.(pss)), io -> begin
        for t in s.technologies
            print(io, _aimms_q(t))
            for ps in pss
                print(io, ",", _aimms_num(decom[t, ps]))
            end
            print(io, "\n")
        end
    end)

    emit(:aimms_Salvage_value, "Salvage_value.CSV", ["tech_id", "salvage"], io -> begin
        for t in s.technologies
            print(io, _aimms_q(t), ",", _aimms_num(get(p.Salvage_value, t, 0.0)), "\n")
        end
    end)

    emit(:aimms_deltaS_Shed, "deltaS_Shed.CSV", ["hour", "technology", "period", "deltaS_Shed"], io -> begin
        shed === nothing && return
        for h in cal.steps, t in s.tech_shedding, ps in pss
            v = calendar_value(shed, h, t, ps)
            iszero(v) || _aimms_row(io, (h, t, ps), v)
        end
    end)

    emit(:aimms_deltaU_CHP, "deltaU_CHP.CSV", ["hour", "technology", "period", "deltaU_CHP"], io -> begin
        chp === nothing && return
        for h in cal.steps, t in s.tech_hourlyCHPflex, ps in pss
            v = calendar_value(chp, h, t, ps)
            iszero(v) || _aimms_row(io, (h, t, ps), v)
        end
    end)

    if hourly_reports
        steps_of_day = Dict{Int,Vector{Int}}()
        for h in cal.steps
            push!(get!(steps_of_day, cal.step_day[h], Int[]), h)
        end
        emit(:aimms_tech_Use_h, "tech_Use_h.CSV", ["hour", "technology", "period", "techUseNet_h"], io -> begin
            for h in cal.steps, t in s.technologies, ps in pss
                v = hourly_net(h, t, ps)
                iszero(v) || _aimms_row(io, (h, t, ps), v)
            end
        end)
        emit(:aimms_tech_Use_d, "tech_Use_d.CSV", ["day", "technology", "period", "techUseNet_d"], io -> begin
            for d in cal.days
                hs = get(steps_of_day, d, Int[])
                isempty(hs) && continue
                for t in s.technologies, ps in pss
                    v = sum(hourly_net(h, t, ps) for h in hs; init = 0.0)
                    iszero(v) || _aimms_row(io, (d, t, ps), v)
                end
            end
        end)
    end

    if !JuMP.has_duals(model)
        @warn "No duals available; commodity_prices, CO2_price, prices_h and prices_d CSV files were not written."
        return written
    end

    # Hourly/daily prices per model time index, converted to calendar-step prices.
    hourly_prices = Dict{Tuple{Symbol,Int,Int},Float64}()
    for ps in pss, a in s.activities_hour
        for t in (is_ts ? s.hours_cluster : cal.steps)
            dv = _aimms_dual(model, is_ts ? "balH_TS[$(a),$(t),$(ps)]" : "balH[$(a),$(t),$(ps)]")
            dv === nothing && continue
            w = is_ts ? get(p.clusterHourWeight, t, 0.0) : 1.0
            w > 0 || continue
            hourly_prices[(a, t, ps)] = dv / w / sdf(ps)
        end
    end
    daily_prices = Dict{Tuple{Symbol,Int,Int},Float64}()
    for ps in pss, a in s.activities_day
        for d in (is_ts ? s.repDays : cal.days)
            dv = _aimms_dual(model, is_ts ? "balD_TS[$(a),$(d),$(ps)]" : "balD[$(a),$(d),$(ps)]")
            dv === nothing && continue
            w = is_ts ? get(p.dayWeight, d, 0.0) : 1.0
            w > 0 || continue
            daily_prices[(a, d, ps)] = dv / w / sdf(ps)
        end
    end
    # Calendar prices are weight-normalised blends of the model-index prices.
    function blend(prices, mix, a, ps)
        wsum = sum(last, mix; init = 0.0)
        wsum > 0 || return 0.0
        return sum(w * get(prices, (a, i, ps), 0.0) for (i, w) in mix) / wsum
    end
    hprice(a, h, ps) = blend(hourly_prices, cal.hmix[h], a, ps)
    dprice(a, d, ps) = blend(daily_prices, get(cal.dmix, d, Tuple{Int,Float64}[]), a, ps)

    set_year = Set(s.activities_year)
    set_day = Set(s.activities_day)
    set_hour = Set(s.activities_hour)
    n_steps = length(cal.steps)
    n_days = length(cal.days)
    function commodity_price(a, ps)
        if a in set_year
            dv = _aimms_dual(model, "balance[$(a),$(ps)]")
            return dv === nothing ? 0.0 : dv / sdf(ps)
        elseif a in set_day
            n_days == 0 && return 0.0
            return sum(dprice(a, d, ps) for d in cal.days) / n_days
        elseif a in set_hour
            n_steps == 0 && return 0.0
            return sum(hprice(a, h, ps) for h in cal.steps) / n_steps
        end
        return 0.0
    end

    emit(:aimms_commodity_prices, "commodity_prices.CSV", ["Node", "commodity", "period", "YearlyShadowPrices"], io -> begin
        node_names = Symbol[]
        for n in s.nodes
            name = get(p.namePer_node, n, Symbol(""))
            (name == Symbol("") || name in node_names) || push!(node_names, name)
        end
        for nn in node_names, a in s.activities_energy
            get(p.namePer_node, get(p.nodePer_act, a, Symbol("")), Symbol("")) == nn || continue
            for ps in pss
                v = commodity_price(a, ps)
                iszero(v) || _aimms_row(io, (nn, a, ps), v)
            end
        end
    end)

    emit(:aimms_CO2_price, "CO2_price.CSV", ["Node", "period", "CO2_Price"], io -> begin
        for n in s.nodes, ps in pss
            duals = Float64[]
            for base in ("emTargetAir", "emTargetBunker", "emTargetFS")
                dv = _aimms_dual(model, "$(base)[$(n),$(ps)]")
                dv === nothing || push!(duals, dv)
            end
            isempty(duals) && continue
            v = round(-minimum(duals) / sdf(ps); digits = 6)
            iszero(v) || _aimms_row(io, (n, ps), v)
        end
    end)

    if hourly_reports
        emit(:aimms_prices_h, "prices_h.CSV", ["Hour", "Activity", "Period", "HourlyShadowPrices"], io -> begin
            for h in cal.steps, a in s.activities_hour, ps in pss
                _aimms_row(io, (h, a, ps), hprice(a, h, ps))
            end
        end)
        emit(:aimms_prices_d, "prices_d.CSV", ["Day", "Activity", "Period", "DailyShadowPrices"], io -> begin
            for d in cal.days, a in s.activities_day, ps in pss
                _aimms_row(io, (d, a, ps), dprice(a, d, ps))
            end
        end)
    end
    return written
end
