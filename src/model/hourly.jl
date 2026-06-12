# =============================================================================
# hourly.jl — Phase 3: full-hourly (FH) LP constraint families
#
# Adds all hourly + daily + flex + storage + CHP + shedding + backlog + reservoir
# + gas-buffer constraints from the IESA-Opt 1.0 source (FH branch, not _TS).
#
# Entry point: `add_hourly_constraints!(m, vars, md)`
#
# IESA-Opt 1.0 source lines covered (in `MainProject/IESA-Opt.ams`):
#   Hourly dispatch       3055-3104
#   Daily dispatch + GB   3139-3225
#   CHP                   3460-3590
#   Shedding              4080-4185, 4522 (nonPos_Shed)
#   Flex/storage          4084-4180, 4257-4310, 4406-4520
#   Backlog DR/BE         4468-4546
#   Reservoir             4128-4160, 4516
#   Cyclic closures       4549-4605
# =============================================================================

# Numerical FP-noise threshold — coefficients below this are dropped to avoid
# HiGHS "packed vector contains tiny values" warnings.
const _IJ_COEF_EPS = 1e-12

"""
    add_hourly_constraints!(m, vars, md) -> Nothing

Add all FH-mode hourly + daily constraints to `m`. Requires `vars` to have
been populated by both `add_annual_variables!` and `add_hourly_variables!`.
"""
function add_hourly_constraints!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    @info "  add_hourly_constraints! - hourly + daily balance + capacity"
    flush(stderr)
    _add_balance_hourly!(m, vars, md)
    _add_balance_daily!(m, vars, md)
    _add_capacity_hourly!(m, vars, md)
    _add_ramping_hourly!(m, vars, md)
    if get(ENV, "IESA_J_ENABLE_LINKED_XC", "0") == "1"
        _add_linked_hourly_XC!(m, vars, md)
    end

    @info "  add_hourly_constraints! - storage state + flex bounds"
    flush(stderr)
    _add_storage_state!(m, vars, md)
    _add_flex_bounds!(m, vars, md)
    _add_flex_closed_loop!(m, vars, md)

    @info "  add_hourly_constraints! - reservoir + gas buffer"
    flush(stderr)
    _add_reservoir!(m, vars, md)
    _add_gasbuffer!(m, vars, md)

    @info "  add_hourly_constraints! - shedding + backlog + CHP"
    flush(stderr)
    _add_shedding!(m, vars, md)
    _add_backlog!(m, vars, md)
    _add_chp!(m, vars, md)
    return nothing
end

# ============================================================================
# Section 1 — Hourly balance + annual-hourly link + hourly capacity + ramping
# ============================================================================

# IESA-Opt 1.0 lines 3059-3073 (balance_activitiesHourly).
# Sum-of-all-contributions = 0 per (h, ah, ps), ah in activities_hour.
#   + hourly dispatch     tech_useHourly(h,th,ps) × balances(th,ah,ps)
#   + reservoir           tech_useHourly(h,tw,ps) × balances(tw,ah,ps)
#                         − deltaW_UP(h,tw,ps) × dW_hourly(tw,ah)
#   + daily dispatch      tech_useDaily(d,td,ps) × balances(td,ah,ps) / hoursPerDayEffective(h)
#   + non-dispatch        tech_use(tp,ps) × profile(h,profType(tp)) × balances(tp,ah,ps)
#   + flex                (deltaQ_UP+deltaQ_DW)(h,tf,ps) × dQ_hourly(tf,ah)
#   + CHP                 (tech_use(tk,ps)×profile + deltaU_CHP(h,tk,ps)) × balances(tk,ah,ps)
#                         + deltaP_CHP(h,tk,ps) × dP_electricity(tk,ah)
#   + shedding            (tech_use(ts,ps)×profile + deltaS_shed(h,ts,ps)) × balances(ts,ah,ps)
function _add_balance_hourly!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    pss  = s.periods_solve
    tu   = vars.tech_use
    isempty(s.hours) && return
    isempty(s.activities_hour) && return
    tb_set = Set(s.tech_balancers)

    # Pre-build per-(activity) → list of (tech, coef) for each ps
    bal_idx = _build_balance_by_act(p, s.activities_hour, pss, tb_set)

    # Precompute set membership lookups for fast term gating
    hdisp_set = Set(s.tech_hourlyDispatch)
    ddisp_set = Set(s.tech_dailyDispatch)
    res_set   = Set(s.tech_reservoir)
    flex_set  = Set(s.tech_flexible)
    chp_set   = Set(s.tech_hourlyCHPflex)
    shed_set  = Set(s.tech_shedding)
    # IESA-Opt 1.0 line 2953 — tech_Operation (= passive `tp` index in balance_activitiesHourly).
    # NOT mutually exclusive with tech_flexible: process-type='Operation' techs that
    # are also flex contribute to both the passive base and the flex-delta sums.
    op_set    = _build_tech_Operation(s, p)

    tuh  = vars.tech_useHourly
    tud  = vars.tech_useDaily
    dwUP = vars.deltaW_UP
    dqUP = vars.deltaQ_UP
    dqDW = vars.deltaQ_DW
    duCHP = vars.deltaU_CHP
    dpCHP = vars.deltaP_CHP
    dShed = vars.deltaS_shed

    # Build `dQ_hourly` and `dW_hourly` indicator indices: ah => Vector{(tb, coef)}.
    # IESA-Opt 1.0 line 3052 sums the flex-delta term `(deltaQ_UP+deltaQ_DW)*dQ_hourly(tf,ah)`
    # over ALL tf (not filtered by activity_balances), and the reservoir-charge term
    # `-deltaW_UP*dW_hourly(tw,ah)` over ALL tw. A flex/reservoir tech can therefore
    # contribute to balH[ah,…] purely via dQ_hourly/dW_hourly even when its
    # `activity_balances(tb,ah,ps)` is zero (e.g. flex=Storage techs carrying only
    # round-trip charge losses into the balance via dQ_hourly=1).
    flex_overlay_idx = Dict{Symbol, Vector{Tuple{Symbol,Float64}}}()
    for ((tb, a), v) in p.dQ_hourly
        abs(v) < _IJ_COEF_EPS && continue
        tb in flex_set || continue
        push!(get!(() -> Tuple{Symbol,Float64}[], flex_overlay_idx, a), (tb, v))
    end
    res_overlay_idx = Dict{Symbol, Vector{Tuple{Symbol,Float64}}}()
    for ((tb, a), v) in p.dW_hourly
        abs(v) < _IJ_COEF_EPS && continue
        tb in res_set || continue
        push!(get!(() -> Tuple{Symbol,Float64}[], res_overlay_idx, a), (tb, v))
    end

    for ah in s.activities_hour, ps in pss
        terms       = get(bal_idx, (ah, ps), Tuple{Symbol,Float64}[])
        flex_extras = get(flex_overlay_idx, ah, Tuple{Symbol,Float64}[])
        res_extras  = get(res_overlay_idx,  ah, Tuple{Symbol,Float64}[])
        isempty(terms) && isempty(flex_extras) && isempty(res_extras) && continue
        # Pre-filter terms once per (ah, ps)
        for h in s.hours
            expr = AffExpr(0.0)
            d = get(p.dayPer_hour, h, 0)
            hpde = get(p.hoursPerDayEffective, h, Float64(p.hoursPer_day))
            for (tb, coef) in terms
                abs(coef) < _IJ_COEF_EPS && continue

                # Process-type contribution (mutually exclusive across th/td/tw/tk/ts/tp).
                # tg has no hourly-balance term in IESA-Opt 1.0.
                if tb in hdisp_set && tuh !== nothing
                    add_to_expression!(expr, coef, tuh[h, tb, ps])
                elseif tb in ddisp_set && tud !== nothing && d > 0 && hpde > 0
                    add_to_expression!(expr, coef / hpde, tud[d, tb, ps])
                elseif tb in res_set && tuh !== nothing
                    add_to_expression!(expr, coef, tuh[h, tb, ps])
                elseif tb in chp_set
                    prof = get(p.hourly_profiles, (h, get(p.profileType_tech, tb, :Flat)), 0.0)
                    if prof != 0.0
                        add_to_expression!(expr, coef * prof, tu[tb, ps])
                    end
                    if duCHP !== nothing
                        add_to_expression!(expr, coef, duCHP[h, tb, ps])
                    end
                    if dpCHP !== nothing
                        dPe = get(p.dP_electricity, (tb, ah), 0.0)
                        abs(dPe) > _IJ_COEF_EPS && add_to_expression!(expr, dPe, dpCHP[h, tb, ps])
                    end
                elseif tb in shed_set
                    prof = get(p.hourly_profiles, (h, get(p.profileType_tech, tb, :Flat)), 0.0)
                    if prof != 0.0
                        add_to_expression!(expr, coef * prof, tu[tb, ps])
                    end
                    if dShed !== nothing
                        add_to_expression!(expr, coef, dShed[h, tb, ps])
                    end
                elseif tb in op_set
                    # Passive base term: tech_use × profile × balances
                    prof = get(p.hourly_profiles, (h, get(p.profileType_tech, tb, :Flat)), 0.0)
                    if prof != 0.0
                        add_to_expression!(expr, coef * prof, tu[tb, ps])
                    end
                end
            end

            # Flex-delta overlay (IESA-Opt 1.0 sum[tf, (deltaQ_UP+deltaQ_DW)*dQ_hourly]).
            # Independent of activity_balances. Iterates over ALL flex techs with
            # non-zero dQ_hourly[(tb,ah)] — including techs with no activity_balances
            # entry for this activity.
            if dqUP !== nothing && dqDW !== nothing
                for (tb, dQh) in flex_extras
                    add_to_expression!(expr, dQh, dqUP[h, tb, ps])
                    add_to_expression!(expr, dQh, dqDW[h, tb, ps])
                end
            end

            # Reservoir pump-up term (IESA-Opt 1.0 sum[tw, -deltaW_UP*dW_hourly]).
            # Independent of activity_balances; mirrors flex overlay above.
            if dwUP !== nothing
                for (tb, dWh) in res_extras
                    add_to_expression!(expr, -dWh, dwUP[h, tb, ps])
                end
            end

            @constraint(m, expr == 0.0, base_name = "balH[$ah,$h,$ps]")
        end
    end
end

# Helper: pre-aggregate activity_balances by (activity, period) → [(tech_balancer, coef)]
function _build_balance_by_act(p::ModelParams, acts::Vector{Symbol},
                                pss::AbstractVector{Int}, tb_set::Set{Symbol})
    idx = Dict{Tuple{Symbol,Int}, Vector{Tuple{Symbol,Float64}}}()
    acts_set = Set(acts)
    for ((tb, a, per), coef) in p.activity_balances
        abs(coef) < _IJ_COEF_EPS && continue
        a in acts_set || continue
        per in pss   || continue
        tb in tb_set || continue
        push!(get!(() -> Tuple{Symbol,Float64}[], idx, (a, per)), (tb, coef))
    end
    return idx
end

# IESA-Opt 1.0 line 3074 — balance_yearlyhourly: tech_use(th,ps) = sum_h tech_useHourly(h,th,ps)
function _add_balance_yearlyhourly!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    vars.tech_useHourly === nothing && return
    pss = s.periods_solve
    tu  = vars.tech_use
    tuh = vars.tech_useHourly
    for th in s.tech_hourlyDispatch, ps in pss
        th in s.tech_balancers || continue
        @constraint(m, tu[th, ps] == sum(tuh[h, th, ps] for h in s.hours),
                    base_name = "balYH[$th,$ps]")
    end
end

# IESA-Opt 1.0 line 3078 — capacity_techHourly: tuh ≤ techStock × cap2act × profile(h, profType(th))
function _add_capacity_hourly!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    vars.tech_useHourly === nothing && return
    pss = s.periods_solve
    ts  = vars.techStock
    tuh = vars.tech_useHourly
    # Also wire balance_yearlyhourly here (cheaper to do them as one section).
    _add_balance_yearlyhourly!(m, vars, md)
    for th in s.tech_hourlyDispatch, ps in pss
        c2a = get(p.cap2act, th, 0.0)
        prof_t = get(p.profileType_tech, th, :Flat)
        for h in s.hours
            prof = get(p.hourly_profiles, (h, prof_t), 0.0)
            expr = AffExpr(0.0)
            add_to_expression!(expr, 1.0, tuh[h, th, ps])
            coef = prof * c2a
            coef == 0.0 || add_to_expression!(expr, -coef, ts[th, ps])
            @constraint(m, expr <= 0.0, base_name = "capH[$th,$h,$ps]")
        end
    end
end

# IESA-Opt 1.0 lines 3082-3094 — ramping UP/DW per hour, cyclic year-end wrap.
# Skipped when profile(h, profType(t)) == 0 (no capacity that hour).
function _add_ramping_hourly!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    vars.tech_useHourly === nothing && return
    pss = s.periods_solve
    ts  = vars.techStock
    tuh = vars.tech_useHourly
    hours = s.hours
    for thr in s.tech_hourlyDispatch, ps in pss
        ramp = get(p.ramping, thr, 0.0)
        ramp == 0.0 && continue
        c2a = get(p.cap2act, thr, 0.0)
        c2a == 0.0 && continue
        prof_t = get(p.profileType_tech, thr, :Flat)
        for (i, h) in enumerate(hours)
            prof = get(p.hourly_profiles, (h, prof_t), 0.0)
            prof == 0.0 && continue
            h_prev = i == 1 ? hours[end] : hours[i - 1]
            rhs = ramp * c2a * prof * ts[thr, ps]
            @constraint(m, tuh[h, thr, ps] - tuh[h_prev, thr, ps] <=  rhs, base_name = "rampUH[$thr,$h,$ps]")
            @constraint(m, tuh[h, thr, ps] - tuh[h_prev, thr, ps] >= -rhs, base_name = "rampDH[$thr,$h,$ps]")
        end
    end
end

# IESA-Opt 1.0 line 3096 — linked_hourly_XC. Bilateral XC trade: total throughput (import+export
# legs) limited by the single direction's max capacity.
#   For (thh, ithh): tech_category(thh)='XC Trade' AND sector(thh) == subsector(ithh)
#                    AND sector(ithh) == subsector(thh)
#     ⇒ tuh(h,thh,ps) + tuh(h,ithh,ps) <= profile(h, profType(thh)) * cap2act(thh) * techStock(thh,ps)
function _add_linked_hourly_XC!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    vars.tech_useHourly === nothing && return
    pss = s.periods_solve
    tuh = vars.tech_useHourly
    ts  = vars.techStock

    # Find all (thh, ithh) pairs that satisfy the XC Trade mirror predicate
    xc_pairs = Tuple{Symbol,Symbol}[]
    for thh in s.tech_hourlyDispatch
        get(p.tech_category, thh, Symbol("")) == :var"XC Trade" || continue
        sec_thh = get(p.tech_sector, thh, Symbol(""))
        sub_thh = get(p.tech_subsector, thh, Symbol(""))
        for ithh in s.tech_hourlyDispatch
            ithh == thh && continue
            get(p.tech_sector, ithh, Symbol("")) == sub_thh || continue
            get(p.tech_subsector, ithh, Symbol("")) == sec_thh || continue
            push!(xc_pairs, (thh, ithh))
        end
    end

    for (thh, ithh) in xc_pairs, ps in pss
        c2a = get(p.cap2act, thh, 0.0)
        c2a == 0.0 && continue
        prof_t = get(p.profileType_tech, thh, :Flat)
        for h in s.hours
            prof = get(p.hourly_profiles, (h, prof_t), 0.0)
            prof == 0.0 && continue
            @constraint(m, tuh[h, thh, ps] + tuh[h, ithh, ps] <= prof * c2a * ts[thh, ps],
                        base_name = "linkXC[$thh,$ithh,$h,$ps]")
        end
    end
end

# ============================================================================
# Section 2 — Daily balance + daily capacity + balance_yearlyDaily
# ============================================================================

# IESA-Opt 1.0 lines 3176-3196 — balance_activitiesDaily summed-over-day, == 0
function _add_balance_daily!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    pss = s.periods_solve
    tu  = vars.tech_use
    tuh = vars.tech_useHourly
    tud = vars.tech_useDaily
    duCHP = vars.deltaU_CHP
    dShed = vars.deltaS_shed
    dB_UP = vars.deltaB_UP
    dB_DW = vars.deltaB_DW

    isempty(s.activities_day) && return
    isempty(s.days) && return
    tb_set = Set(s.tech_balancers)
    hdisp_set = Set(s.tech_hourlyDispatch)
    ddisp_set = Set(s.tech_dailyDispatch)
    chp_set   = Set(s.tech_hourlyCHPflex)
    shed_set  = Set(s.tech_shedding)
    gb_set    = Set(s.tech_gasBuffer)
    # IESA-Opt 1.0 line 3176 (balance_activitiesDaily) — terms over th, td, tg, tp, tk, ts only.
    # NO tw and NO tf in the daily balance.
    op_set    = _build_tech_Operation(s, p)

    bal_idx = _build_balance_by_act(p, s.activities_day, pss, tb_set)
    # Pre-group hours by day for the IESA-Opt 1.0 `sum[ih | dayPer_hour(ih)=d, ...]` pattern
    hours_per_day = Dict{Int,Vector{Int}}()
    for h in s.hours
        d = get(p.dayPer_hour, h, 0)
        d == 0 && continue
        push!(get!(() -> Int[], hours_per_day, d), h)
    end

    # Build `dB_daily` indicator index: ad => Vector{(tb, coef)}.
    # IESA-Opt 1.0 line 3176 sums `(deltaB_UP+deltaB_DW)*dB_daily(tg,ad)` over ALL tg,
    # independent of activity_balances. Mirror the hourly fix for tf/tw overlays.
    gb_overlay_idx = Dict{Symbol, Vector{Tuple{Symbol,Float64}}}()
    for ((tb, a), v) in p.dB_daily
        abs(v) < _IJ_COEF_EPS && continue
        tb in gb_set || continue
        push!(get!(() -> Tuple{Symbol,Float64}[], gb_overlay_idx, a), (tb, v))
    end

    for ad in s.activities_day, ps in pss
        terms     = get(bal_idx, (ad, ps), Tuple{Symbol,Float64}[])
        gb_extras = get(gb_overlay_idx, ad, Tuple{Symbol,Float64}[])
        isempty(terms) && isempty(gb_extras) && continue
        for d in s.days
            hs_in_d = get(hours_per_day, d, Int[])
            isempty(hs_in_d) && continue
            expr = AffExpr(0.0)
            for (tb, coef) in terms
                abs(coef) < _IJ_COEF_EPS && continue
                if tb in hdisp_set && tuh !== nothing
                    for ih in hs_in_d
                        add_to_expression!(expr, coef, tuh[ih, tb, ps])
                    end
                elseif tb in ddisp_set && tud !== nothing
                    add_to_expression!(expr, coef, tud[d, tb, ps])
                elseif tb in gb_set
                    # Gas buffers do not have a tech_use*activity_balances term in
                    # the daily balance — IESA-Opt 1.0 line 3176 only has the dB_daily overlay
                    # below for tg. No-op.
                    nothing
                elseif tb in chp_set
                    prof_t = get(p.profileType_tech, tb, :Flat)
                    for ih in hs_in_d
                        prof = get(p.hourly_profiles, (ih, prof_t), 0.0)
                        prof != 0.0 && add_to_expression!(expr, coef * prof, tu[tb, ps])
                        duCHP !== nothing && add_to_expression!(expr, coef, duCHP[ih, tb, ps])
                    end
                elseif tb in shed_set
                    prof_t = get(p.profileType_tech, tb, :Flat)
                    for ih in hs_in_d
                        prof = get(p.hourly_profiles, (ih, prof_t), 0.0)
                        prof != 0.0 && add_to_expression!(expr, coef * prof, tu[tb, ps])
                        dShed !== nothing && add_to_expression!(expr, coef, dShed[ih, tb, ps])
                    end
                elseif tb in op_set
                    prof_t = get(p.profileType_tech, tb, :Flat)
                    for ih in hs_in_d
                        prof = get(p.hourly_profiles, (ih, prof_t), 0.0)
                        prof != 0.0 && add_to_expression!(expr, coef * prof, tu[tb, ps])
                    end
                end
            end

            # Gas buffer overlay (IESA-Opt 1.0 sum[tg, (deltaB_UP+deltaB_DW)*dB_daily]).
            # Independent of activity_balances; iterates over ALL gas buffers with
            # non-zero dB_daily[(tb,ad)].
            if dB_UP !== nothing && dB_DW !== nothing
                for (tb, dBd) in gb_extras
                    add_to_expression!(expr, dBd, dB_UP[d, tb, ps])
                    add_to_expression!(expr, dBd, dB_DW[d, tb, ps])
                end
            end

            @constraint(m, expr == 0.0, base_name = "balD[$ad,$d,$ps]")
        end
    end

    # IESA-Opt 1.0 line 3189 — balance_yearlyDaily: tech_use(td,ps) = sum_d tech_useDaily(d,td,ps)
    if tud !== nothing
        for td in s.tech_dailyDispatch, ps in pss
            td in s.tech_balancers || continue
            @constraint(m, tu[td, ps] == sum(tud[d, td, ps] for d in s.days),
                        base_name = "balYD[$td,$ps]")
        end
    end

    # IESA-Opt 1.0 line 3193 — capacity_techDaily: tud ≤ techStock × cap2act × Σ_{ih ∈ d} profile
    if tud !== nothing
        ts = vars.techStock
        for td in s.tech_dailyDispatch, ps in pss
            c2a = get(p.cap2act, td, 0.0)
            c2a == 0.0 && continue
            prof_t = get(p.profileType_tech, td, :Flat)
            for d in s.days
                hs_in_d = get(hours_per_day, d, Int[])
                isempty(hs_in_d) && continue
                prof_sum = sum(get(p.hourly_profiles, (ih, prof_t), 0.0) for ih in hs_in_d)
                prof_sum == 0.0 && continue
                @constraint(m, tud[d, td, ps] <= c2a * ts[td, ps] * prof_sum,
                            base_name = "capD[$td,$d,$ps]")
            end
        end
    end
end

# ============================================================================
# Section 3 — Gas buffer state recursion + capacity + cumulative
# ============================================================================

# IESA-Opt 1.0 lines 3158-3164: deltaB_S Variable Definition.
# As JuMP constraint: deltaB_S(d) − prev_S − deltaB_UP(d) − deltaB_DW(d) = 0,
# with prev_S(d=1) = deltaB_S(card(days)) (cyclic).
function _add_gasbuffer!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    vars.deltaB_S === nothing && return
    pss = s.periods_solve
    ts  = vars.techStock
    dB_UP = vars.deltaB_UP
    dB_DW = vars.deltaB_DW
    dB_S  = vars.deltaB_S
    days = s.days
    n_d  = length(days)

    for tg in s.tech_gasBuffer, ps in pss
        # State recursion
        for (i, d) in enumerate(days)
            d_prev = i == 1 ? days[end] : days[i - 1]
            @constraint(m, dB_S[d, tg, ps] - dB_S[d_prev, tg, ps]
                            - dB_UP[d, tg, ps] - dB_DW[d, tg, ps] == 0.0,
                        base_name = "dBSrec[$tg,$d,$ps]")
        end
        # Annual closure: Σ_d (deltaB_UP + deltaB_DW) = 0
        @constraint(m, sum(dB_UP[d, tg, ps] + dB_DW[d, tg, ps] for d in days) == 0.0,
                    base_name = "balY_dB[$tg,$ps]")
        # Daily capacity bounds
        bUP = get(p.bufferUP_capacity, tg, 0.0)
        bDW = get(p.bufferDW_capacity, tg, 0.0)
        bSt = get(p.buffer_storage, tg, 0.0)
        for d in days
            if bUP > 0.0
                @constraint(m, dB_UP[d, tg, ps] >= -bUP * ts[tg, ps],
                            base_name = "capUP_dB[$tg,$d,$ps]")
            end
            if bDW > 0.0
                @constraint(m, dB_DW[d, tg, ps] <=  bDW * ts[tg, ps],
                            base_name = "capDW_dB[$tg,$d,$ps]")
            end
            if bSt > 0.0 && bDW > 0.0
                @constraint(m, dB_S[d, tg, ps] >= -ts[tg, ps] * bSt * bDW,
                            base_name = "cumS_dB[$tg,$d,$ps]")
            end
        end
    end
end

# ============================================================================
# Section 4 — Storage state (deltaQ_S) — Variable Definition as equality
# ============================================================================

# IESA-Opt 1.0 lines 4096-4108: deltaQ_S(h, tfwb, ps) Variable Definition.
#   deltaQ_S(h) = prev_S × (1−standing_loss)^slice_width
#                + deltaQ_UP(h) × (1 − flex_loss_charge)
#                + deltaQ_DW(h)
# prev_S(h=1) = deltaQ_S(card(hours)).
#
# Also adds cumulativeS_dQtfb (battery floor) — IESA-Opt 1.0 line 4515.
function _add_storage_state!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    vars.deltaQ_S === nothing && return
    pss = s.periods_solve
    ts   = vars.techStock
    dq_S = vars.deltaQ_S
    dqUP = vars.deltaQ_UP
    dqDW = vars.deltaQ_DW
    hours = s.hours
    isempty(hours) && return

    for tfwb in s.tech_fWithBattery, ps in pss
        sl  = get(p.flex_standing_loss_effective, tfwb, 0.0)
        lch = get(p.flex_loss_charge, tfwb, 0.0)
        chg_factor = 1.0 - lch
        for (i, h) in enumerate(hours)
            sw   = get(p.slice_width_hours, h, 1.0)
            decay = (1.0 - sl)^sw
            h_prev = i == 1 ? hours[end] : hours[i - 1]
            # deltaQ_S(h) − decay × prev_S − chg_factor × deltaQ_UP(h) − deltaQ_DW(h) == 0
            expr = AffExpr(0.0)
            add_to_expression!(expr, 1.0, dq_S[h, tfwb, ps])
            add_to_expression!(expr, -decay, dq_S[h_prev, tfwb, ps])
            if dqUP !== nothing
                add_to_expression!(expr, -chg_factor, dqUP[h, tfwb, ps])
            end
            if dqDW !== nothing
                add_to_expression!(expr, -1.0, dqDW[h, tfwb, ps])
            end
            @constraint(m, expr == 0.0, base_name = "dQSrec[$tfwb,$h,$ps]")
        end
        # cumulativeS_dQtfb: deltaQ_S(h) >= −techStock × flex_storage × flex_capacity(t,ps)
        fS = get(p.flex_storage, tfwb, 0.0)
        fC = get(p.flex_capacity, (tfwb, ps), 0.0)
        if fS > 0.0 && fC > 0.0 && tfwb in s.tech_fStorage
            for h in hours
                @constraint(m, dq_S[h, tfwb, ps] >= -ts[tfwb, ps] * fS * fC,
                            base_name = "cumS_dQ[$tfwb,$h,$ps]")
            end
        end
    end
end

# ============================================================================
# Section 5 — Flex hourly capacity bounds + annual closed-loop balance
# ============================================================================

# IESA-Opt 1.0 lines 4257-4310 (capacityUP/DW_dQ*) + 4216-4253 (balanceQ/D/R/W/M/S/B/Y)
function _add_flex_bounds!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    vars.deltaQ_UP === nothing && return
    pss = s.periods_solve
    tu   = vars.tech_use
    ts   = vars.techStock
    dqUP = vars.deltaQ_UP
    dqDW = vars.deltaQ_DW
    hours = s.hours
    tb_set = Set(s.tech_balancers)

    fStorage_set = Set(s.tech_fStorage)
    fEV_set      = Set(s.tech_fEV)
    fBattery_set = Set(s.tech_fWithBattery)

    for tf in s.tech_flexible, ps in pss
        nnLoad = get(p.flex_nnLoad, tf, 0.0)
        fC     = get(p.flex_capacity, (tf, ps), 0.0)
        prof_t = get(p.profileType_tech, tf, :Flat)
        # flex_activity-based RHS coefficient (per ps)
        fa = get(p.flex_activity, tf, Symbol(""))
        ab_fa = fa == Symbol("") ? 0.0 : get(p.activity_balances, (tf, fa, ps), 0.0)

        for h in hours
            prof = get(p.hourly_profiles, (h, prof_t), 0.0)
            # ── UP bounds ──
            if tf in fStorage_set
                # capacityUP_dQtfe: ≥ −(fC × stock + prof × ab_fa × tu) × nnLoad
                if fC > 0.0 || (abs(prof * ab_fa) > _IJ_COEF_EPS)
                    expr = AffExpr(0.0)
                    add_to_expression!(expr, 1.0, dqUP[h, tf, ps])
                    add_to_expression!(expr, nnLoad * fC, ts[tf, ps])
                    if tf in tb_set
                        add_to_expression!(expr, nnLoad * prof * ab_fa, tu[tf, ps])
                    end
                    @constraint(m, expr >= 0.0, base_name = "capUPdQe[$tf,$h,$ps]")
                end
            elseif tf in fBattery_set && !(tf in fEV_set)
                # capacityUP_dQtfb battery: ≥ −techStock × flex_capacity
                if fC > 0.0
                    @constraint(m, dqUP[h, tf, ps] + fC * ts[tf, ps] >= 0.0,
                                base_name = "capUPdQb[$tf,$h,$ps]")
                end
            elseif tf in fEV_set
                # capacityUP_dQtfv EV: ≥ −(fC × stock + tu × ab_fa × prof)
                expr = AffExpr(0.0)
                add_to_expression!(expr, 1.0, dqUP[h, tf, ps])
                add_to_expression!(expr, fC, ts[tf, ps])
                if tf in tb_set
                    add_to_expression!(expr, prof * ab_fa, tu[tf, ps])
                end
                @constraint(m, expr >= 0.0, base_name = "capUPdQv[$tf,$h,$ps]")
            else
                # capacityUP_dQtfs (short shift): ≥ −(fC × stock + prof × ab_fa × tu)
                expr = AffExpr(0.0)
                add_to_expression!(expr, 1.0, dqUP[h, tf, ps])
                add_to_expression!(expr, fC, ts[tf, ps])
                if tf in tb_set
                    add_to_expression!(expr, prof * ab_fa, tu[tf, ps])
                end
                @constraint(m, expr >= 0.0, base_name = "capUPdQs[$tf,$h,$ps]")
            end
            # ── DW bounds ──
            if tf in fBattery_set && !(tf in fEV_set) && tf in fStorage_set == false
                # capacityDW_dQtfb battery: ≤ +techStock × flex_capacity (symmetric)
                if fC > 0.0
                    @constraint(m, dqDW[h, tf, ps] - fC * ts[tf, ps] <= 0.0,
                                base_name = "capDWdQb[$tf,$h,$ps]")
                end
            else
                # capacityDW_dQtfe/tfs/tfvc: ≤ -prof × ab_fa × tu × (1-nnLoad)
                if abs(prof * ab_fa) > _IJ_COEF_EPS && tf in tb_set
                    @constraint(m, dqDW[h, tf, ps] + prof * ab_fa * (1.0 - nnLoad) * tu[tf, ps] <= 0.0,
                                base_name = "capDWdQ[$tf,$h,$ps]")
                end
            end
        end
    end
end

# IESA-Opt 1.0 lines 4216-4253 — flex closed-loop annual balances per window-type.
#   sum_{ih in window} [dqUP × (1-loss_charge) + dqDW / (1-loss_disc)] = 0
function _add_flex_closed_loop!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    vars.deltaQ_UP === nothing && return
    pss = s.periods_solve
    dqUP = vars.deltaQ_UP
    dqDW = vars.deltaQ_DW

    # Helper: build the equality for one tech, one period, one set of hours
    function _closure!(t::Symbol, ps::Int, hs::Vector{Int}, label::String)
        isempty(hs) && return
        chg = 1.0 - get(p.flex_loss_charge, t, 0.0)
        disc = 1.0 - get(p.flex_loss_discharge_eff, t, 0.0)
        disc <= 0.0 && (disc = 1.0)
        expr = AffExpr(0.0)
        for h in hs
            add_to_expression!(expr, chg, dqUP[h, t, ps])
            add_to_expression!(expr, 1.0 / disc, dqDW[h, t, ps])
        end
        @constraint(m, expr == 0.0, base_name = label)
    end

    # Pre-group hours by various windows
    hours_by_q = Dict{Int,Vector{Int}}()
    hours_by_d = Dict{Int,Vector{Int}}()
    hours_by_w = Dict{Int,Vector{Int}}()
    hours_by_m = Dict{Int,Vector{Int}}()
    hours_by_seas = Dict{Int,Vector{Int}}()
    hours_by_sem  = Dict{Int,Vector{Int}}()
    hours_by_r    = Dict{Int,Vector{Int}}()
    for h in s.hours
        push!(get!(() -> Int[], hours_by_q, get(p.quarterPer_hour, h, 0)), h)
        push!(get!(() -> Int[], hours_by_d, get(p.dayPer_hour, h, 0)), h)
        push!(get!(() -> Int[], hours_by_w, get(p.weekPer_hour, h, 0)), h)
        push!(get!(() -> Int[], hours_by_m, get(p.monthPer_hour, h, 0)), h)
        push!(get!(() -> Int[], hours_by_seas, get(p.seasonPer_hour, h, 0)), h)
        push!(get!(() -> Int[], hours_by_sem, get(p.semesterPer_hour, h, 0)), h)
        push!(get!(() -> Int[], hours_by_r, get(p.rangePer_hour, h, 0)), h)
    end

    # tech_fStorage uses quarter-hour window (balanceQ_deltaQtfe)
    for t in s.tech_fStorage, ps in pss, (q, hs) in hours_by_q
        q == 0 && continue
        _closure!(t, ps, hs, "balQ_dQe[$t,$q,$ps]")
    end
    # Range membership by flex_range field per tech
    for t in s.tech_flexible, ps in pss
        rng = get(p.flex_range, t, Symbol(""))
        if rng == :var"1 day"
            for (d, hs) in hours_by_d
                d == 0 && continue
                _closure!(t, ps, hs, "balD_dQ[$t,$d,$ps]")
            end
        elseif rng == :var"3 days"
            for (r, hs) in hours_by_r
                r == 0 && continue
                _closure!(t, ps, hs, "balR_dQ[$t,$r,$ps]")
            end
        elseif rng == :var"1 week"
            for (w, hs) in hours_by_w
                w == 0 && continue
                _closure!(t, ps, hs, "balW_dQ[$t,$w,$ps]")
            end
        elseif rng == :var"1 month"
            for (mo, hs) in hours_by_m
                mo == 0 && continue
                _closure!(t, ps, hs, "balM_dQ[$t,$mo,$ps]")
            end
        elseif rng == :var"1 season"
            for (sn, hs) in hours_by_seas
                sn == 0 && continue
                _closure!(t, ps, hs, "balS_dQ[$t,$sn,$ps]")
            end
        elseif rng == :var"6 months"
            for (b, hs) in hours_by_sem
                b == 0 && continue
                _closure!(t, ps, hs, "balB_dQ[$t,$b,$ps]")
            end
        elseif rng == :var"1 year"
            _closure!(t, ps, collect(s.hours), "balY_dQ[$t,$ps]")
        end
    end
end

# ============================================================================
# Section 6 — Reservoir (deltaW_S Variable Definition + capacity + cumulative)
# ============================================================================

# IESA-Opt 1.0 lines 4137-4156 — deltaW_S(h, tw, ps) Variable Definition.
#   deltaW_S(h) = prev_W
#                + deltaW_UP(h) × (1 − phs_Losses)
#                + techStock(tw,ps) × cap2act × profile(h, profType(tw))  (inflow)
#                − tech_useHourly(h, tw, ps)                              (discharge)
function _add_reservoir!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    vars.deltaW_S === nothing && return
    pss = s.periods_solve
    dwS = vars.deltaW_S
    dwUP = vars.deltaW_UP
    ts  = vars.techStock
    tuh = vars.tech_useHourly
    hours = s.hours

    for tw in s.tech_reservoir, ps in pss
        loss = get(p.phs_Losses, tw, 0.0)
        c2a  = get(p.cap2act, tw, 0.0)
        prof_t = get(p.profileType_tech, tw, :Flat)
        phs_cap = get(p.phs_capacity, tw, 0.0)
        res_cap = get(p.reservoir_capacity, tw, 0.0)
        for (i, h) in enumerate(hours)
            h_prev = i == 1 ? hours[end] : hours[i - 1]
            prof = get(p.hourly_profiles, (h, prof_t), 0.0)
            expr = AffExpr(0.0)
            add_to_expression!(expr, 1.0, dwS[h, tw, ps])
            add_to_expression!(expr, -1.0, dwS[h_prev, tw, ps])
            add_to_expression!(expr, -(1.0 - loss), dwUP[h, tw, ps])
            add_to_expression!(expr, -c2a * prof, ts[tw, ps])
            if tuh !== nothing
                add_to_expression!(expr, 1.0, tuh[h, tw, ps])
            end
            @constraint(m, expr == 0.0, base_name = "dWSrec[$tw,$h,$ps]")
            # capacityUP_dW: deltaW_UP ≤ techStock × phs_capacity × profile(h, 'Flat')
            if phs_cap > 0.0
                flat = get(p.hourly_profiles, (h, :Flat), 1.0)
                @constraint(m, dwUP[h, tw, ps] <= phs_cap * flat * ts[tw, ps],
                            base_name = "capUP_dW[$tw,$h,$ps]")
            end
            # cumulativeS_dW: deltaW_S ≤ techStock × reservoir_capacity
            if res_cap > 0.0
                @constraint(m, dwS[h, tw, ps] <= res_cap * ts[tw, ps],
                            base_name = "cumS_dW[$tw,$h,$ps]")
            end
        end
    end
end

# ============================================================================
# Section 7 — Shedding (capacity + sufficiency + nonPos + balanceH + balanceW)
# ============================================================================

# IESA-Opt 1.0 lines 4143, 4174, 4179, 4649
function _add_shedding!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    vars.deltaS_shed === nothing && return
    pss = s.periods_solve
    tu  = vars.tech_use
    ts  = vars.techStock
    dS  = vars.deltaS_shed

    for tsh in s.tech_shedding, ps in pss
        prof_t = get(p.profileType_tech, tsh, :Flat)
        shedCap = get(p.shed_capacity, (tsh, ps), 0.0)
        shedVol = get(p.shed_volume, tsh, 0.0)
        for h in s.hours
            # capacity_deltaS: deltaS_shed >= -techStock × shed_capacity(t,ps)
            if shedCap > 0.0
                @constraint(m, dS[h, tsh, ps] + shedCap * ts[tsh, ps] >= 0.0,
                            base_name = "capS[$tsh,$h,$ps]")
            end
            # sufficiency_deltaS: deltaS_shed >= -tech_use × profile(h, profType(ts))
            prof = get(p.hourly_profiles, (h, prof_t), 0.0)
            if abs(prof) > _IJ_COEF_EPS && tsh in s.tech_balancers
                @constraint(m, dS[h, tsh, ps] + prof * tu[tsh, ps] >= 0.0,
                            base_name = "suffS[$tsh,$h,$ps]")
            end
            # balanceH_deltaS: deltaS_shed >= -tech_use × shed_volume × profile (only for ts_h)
            if tsh in s.tech_shedH && tsh in s.tech_balancers
                expr = AffExpr(0.0)
                add_to_expression!(expr, 1.0, dS[h, tsh, ps])
                coef = shedVol * prof
                abs(coef) <= _IJ_COEF_EPS || add_to_expression!(expr, coef, tu[tsh, ps])
                @constraint(m, expr >= 0.0, base_name = "balH_dS[$tsh,$h,$ps]")
            end
        end
    end
end

# ============================================================================
# Section 8 — Backlog (DR + BE) state recursion + cap + closure
# ============================================================================

# IESA-Opt 1.0 lines 4468-4540
function _add_backlog!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    pss = s.periods_solve
    ts   = vars.techStock
    dqUP = vars.deltaQ_UP
    dqDW = vars.deltaQ_DW
    hours = s.hours

    # DR backlog (IESA-Opt 1.0 index tfs = tech_fDRshifting)
    if vars.deltaQ_backlog_DR !== nothing && !isempty(s.tech_fDRshifting)
        b = vars.deltaQ_backlog_DR
        for tfs in s.tech_fDRshifting, ps in pss
            chg  = 1.0 - get(p.flex_loss_charge, tfs, 0.0)
            disc = 1.0 - get(p.flex_loss_discharge_eff, tfs, 0.0)
            disc <= 0.0 && (disc = 1.0)
            fS = get(p.flex_storage, tfs, 0.0)
            fC = get(p.flex_capacity, (tfs, ps), 0.0)
            for (i, h) in enumerate(hours)
                h_prev = i == 1 ? hours[end] : hours[i - 1]
                expr = AffExpr(0.0)
                add_to_expression!(expr, 1.0, b[h, tfs, ps])
                if i != 1
                    add_to_expression!(expr, -1.0, b[h_prev, tfs, ps])
                end
                dqUP !== nothing && add_to_expression!(expr, -chg, dqUP[h, tfs, ps])
                dqDW !== nothing && add_to_expression!(expr, -(1.0 / disc), dqDW[h, tfs, ps])
                @constraint(m, expr == 0.0, base_name = "stB_DR[$tfs,$h,$ps]")
                if fS > 0.0 && fC > 0.0
                    @constraint(m, b[h, tfs, ps] <= ts[tfs, ps] * fS * fC,
                                base_name = "stCap_DR[$tfs,$h,$ps]")
                end
            end
            # Closure at horizon boundaries + year-end
            horizon = get(p.flex_backlog_horizon_days, tfs, 0)
            for d in s.days
                if (horizon > 0 && mod(d, horizon) == 0) || d == last(s.days)
                    lh = get(p.lastHourOfDay, d, 0)
                    lh > 0 && @constraint(m, b[lh, tfs, ps] == 0.0,
                                          base_name = "stCls_DR[$tfs,$d,$ps]")
                end
            end
        end
    end

    # BE backlog (IESA-Opt 1.0 index tfe = tech_fBEshifting)
    if vars.deltaQ_backlog_BE !== nothing && !isempty(s.tech_fBEshifting)
        b = vars.deltaQ_backlog_BE
        for tfe in s.tech_fBEshifting, ps in pss
            chg  = 1.0 - get(p.flex_loss_charge, tfe, 0.0)
            disc = 1.0 - get(p.flex_loss_discharge_eff, tfe, 0.0)
            disc <= 0.0 && (disc = 1.0)
            fS = get(p.flex_storage, tfe, 0.0)
            fC = get(p.flex_capacity, (tfe, ps), 0.0)
            for (i, h) in enumerate(hours)
                h_prev = i == 1 ? hours[end] : hours[i - 1]
                expr = AffExpr(0.0)
                add_to_expression!(expr, 1.0, b[h, tfe, ps])
                if i != 1
                    add_to_expression!(expr, -1.0, b[h_prev, tfe, ps])
                end
                dqUP !== nothing && add_to_expression!(expr, -chg, dqUP[h, tfe, ps])
                dqDW !== nothing && add_to_expression!(expr, -(1.0 / disc), dqDW[h, tfe, ps])
                @constraint(m, expr == 0.0, base_name = "stB_BE[$tfe,$h,$ps]")
                if fS > 0.0 && fC > 0.0
                    @constraint(m, b[h, tfe, ps] <= ts[tfe, ps] * fS * fC,
                                base_name = "stCap_BE[$tfe,$h,$ps]")
                end
            end
            horizon = get(p.flex_backlog_horizon_days, tfe, 0)
            for d in s.days
                if (horizon > 0 && mod(d, horizon) == 0) || d == last(s.days)
                    lh = get(p.lastHourOfDay, d, 0)
                    lh > 0 && @constraint(m, b[lh, tfe, ps] == 0.0,
                                          base_name = "stCls_BE[$tfe,$d,$ps]")
                end
            end
        end
    end
end

# ============================================================================
# Section 9 — CHP (balance H + capacity UP/DW)
# ============================================================================

# IESA-Opt 1.0 lines 3473-3528.  Simplified hourly CHP heat balance:
#   deltaU_CHP(h,tk,ps) × ab(tk, CHP_prod, ps) = CHP_eta × deltaP_CHP / CHP_eps
# capacityUP/DW_deltaUchp: ±tech_use × profile × CHP_dev_use
# capacityUP/DW_deltaPchp: ±(tu × prof + deltaU_CHP) × Σ_{iah: dP_elec=1} ab(tk, iah, ps) × CHP_dev_PtoH
# IESA-Opt 1.0 lines 3542-3576.  CHP ramping (UP/DW for both deltaU_CHP and deltaP_CHP):
#   |Δ_t deltaU_CHP| ≤ tu × prof × dev_u × ramp_effective
#   |Δ_t deltaP_CHP| ≤ tu × prof × ab_elec × dev_pH × ramp_effective
function _add_chp!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    s, p = md.sets, md.params
    (vars.deltaU_CHP === nothing) && return
    pss = s.periods_solve
    tu   = vars.tech_use
    duCHP = vars.deltaU_CHP
    dpCHP = vars.deltaP_CHP
    hours = s.hours

    for tk in s.tech_hourlyCHPflex, ps in pss
        prof_t = get(p.profileType_tech, tk, :Flat)
        eta    = get(p.CHP_eta, tk, 0.0)
        eps_   = max(get(p.CHP_eps, (tk, ps), 0.0), 0.01)
        dev_u  = get(p.CHP_dev_use, tk, 0.0)
        dev_pH = get(p.CHP_dev_PtoH, tk, 0.0)
        ramp_t = get(p.ramping, tk, 0.0)
        ramp_eff = ramp_t > 0.0 ? ramp_t : 1.0
        prod_a = get(p.CHP_prod, tk, Symbol(""))
        ab_prod = prod_a == Symbol("") ? 0.0 : get(p.activity_balances, (tk, prod_a, ps), 0.0)

        # Σ_{iah | dP_electricity(tk,iah)=1} ab(tk,iah,ps)
        ab_elec = 0.0
        for ((tk2, iah), v) in p.dP_electricity
            tk2 == tk || continue
            v == 1.0 || continue
            ab_elec += get(p.activity_balances, (tk, iah, ps), 0.0)
        end

        for (i, h) in enumerate(hours)
            h_prev = i == 1 ? hours[end] : hours[i - 1]
            prof = get(p.hourly_profiles, (h, prof_t), 0.0)
            # balanceH_deltaHchp: deltaU_CHP × ab_prod − (CHP_eta/CHP_eps) × deltaP_CHP = 0
            if abs(ab_prod) > _IJ_COEF_EPS && eta > 0.0
                @constraint(m, ab_prod * duCHP[h, tk, ps] - (eta / eps_) * dpCHP[h, tk, ps] == 0.0,
                            base_name = "balH_chp[$tk,$h,$ps]")
            end
            # capacityUP_deltaUchp: deltaU_CHP <=  tu × prof × dev_u
            # capacityDW_deltaUchp: deltaU_CHP >= -tu × prof × dev_u
            if abs(prof * dev_u) > _IJ_COEF_EPS && tk in s.tech_balancers
                @constraint(m, duCHP[h, tk, ps] - prof * dev_u * tu[tk, ps] <= 0.0,
                            base_name = "capUP_dU[$tk,$h,$ps]")
                @constraint(m, duCHP[h, tk, ps] + prof * dev_u * tu[tk, ps] >= 0.0,
                            base_name = "capDW_dU[$tk,$h,$ps]")
            end
            # capacityUP/DW_deltaPchp: deltaP_CHP <= (tu×prof + deltaU_CHP) × ab_elec × dev_pH
            #                          deltaP_CHP >= -(tu×prof + deltaU_CHP) × ab_elec × dev_pH
            # JuMP form: deltaP - ab_elec × dev_pH × (tu × prof + deltaU_CHP) <= 0
            if abs(ab_elec * dev_pH) > _IJ_COEF_EPS
                if tk in s.tech_balancers
                    @constraint(m, dpCHP[h, tk, ps]
                                  - ab_elec * dev_pH * prof * tu[tk, ps]
                                  - ab_elec * dev_pH * duCHP[h, tk, ps] <= 0.0,
                                base_name = "capUP_dP[$tk,$h,$ps]")
                    @constraint(m, dpCHP[h, tk, ps]
                                  + ab_elec * dev_pH * prof * tu[tk, ps]
                                  + ab_elec * dev_pH * duCHP[h, tk, ps] >= 0.0,
                                base_name = "capDW_dP[$tk,$h,$ps]")
                end
            end
            # IESA-Opt 1.0 lines 3542-3556. rampingUP_deltaUchp / rampingDW_deltaUchp.
            # Active only when hourly_profile(h, profType_tech(tk)) > 0.
            chp_ramp_enabled = get(ENV, "IESA_DISABLE_CHP_RAMP", "0") != "1"
            if chp_ramp_enabled && prof > 0.0 && tk in s.tech_balancers
                rhs_u = prof * dev_u * ramp_eff
                if abs(rhs_u) > _IJ_COEF_EPS
                    @constraint(m, duCHP[h, tk, ps] - duCHP[h_prev, tk, ps]
                                   - rhs_u * tu[tk, ps] <= 0.0,
                                base_name = "rmpUP_dU[$tk,$h,$ps]")
                    @constraint(m, duCHP[h, tk, ps] - duCHP[h_prev, tk, ps]
                                   + rhs_u * tu[tk, ps] >= 0.0,
                                base_name = "rmpDW_dU[$tk,$h,$ps]")
                end
                # IESA-Opt 1.0 lines 3558-3576. rampingUP_deltaPchp / rampingDW_deltaPchp.
                rhs_p = prof * ab_elec * dev_pH * ramp_eff
                if abs(rhs_p) > _IJ_COEF_EPS
                    @constraint(m, dpCHP[h, tk, ps] - dpCHP[h_prev, tk, ps]
                                   - rhs_p * tu[tk, ps] <= 0.0,
                                base_name = "rmpUP_dP[$tk,$h,$ps]")
                    @constraint(m, dpCHP[h, tk, ps] - dpCHP[h_prev, tk, ps]
                                   + rhs_p * tu[tk, ps] >= 0.0,
                                base_name = "rmpDW_dP[$tk,$h,$ps]")
                end
            end
        end
    end
end
