# =============================================================================
# parameters.jl — Derived parameter computation
#
# Ported from `Backup/IESA-J/src/parameters.jl` derivation helpers and
# `Backup/IESA-J/src/data_reading.jl::_resolve_activity_names!` /
# `_derive_profile_and_node_maps!`.
#
# All routines operate on a `ModelData` (md.sets / md.params). Idempotent:
# every call clears + recomputes the target derived dictionaries.
#
# Functions:
#   compute_derived_params!(md)        — top-level orchestrator
#   compute_financial_params!(md)      — CRF, social_discount_factor, period_span
#   compute_investment_matrices!(md)   — InvMat_lifeTime, decomMat_NewInv
#   compute_activity_balances!(md)     — activity_balances from ref × (1 - EffImprov)
#   compute_chp_eps!(md)               — CHP_eps power-to-heat ratio per (t, p)
#   compute_activity_indicators!(md)   — dQ_hourly, dS_hourly, dW_hourly
#   compute_decom_planned_sel!(md)     — accumulate decom_planned into solved-period brackets (IESA-Opt 1.0 line 2752)
#   compute_temporal_helpers!(md)      — dayPer_hour, lastHourOfDay, prev/next, etc.
#   compute_flex_loss_split!(md)       — split flex_losses_legacy → charge / discharge_eff
#   compute_period_indicators!(md)     — period_weight, period_span, transition_interval
# =============================================================================

"""
    compute_derived_params!(md::ModelData) -> ModelData

Top-level entry. Runs every derivation in order. Called automatically by
`read_data`; can be re-run after manual edits to base parameters.
"""
function compute_derived_params!(md::ModelData)
    compute_temporal_helpers!(md)
    compute_period_indicators!(md)
    compute_financial_params!(md)
    compute_investment_matrices!(md)
    _resolve_activity_names!(md)
    _derive_profile_and_node_maps!(md)
    compute_activity_balances!(md)
    compute_chp_eps!(md)
    compute_activity_indicators!(md)
    compute_decom_planned_sel!(md)
    compute_flex_loss_split!(md)
    compute_flex_indicators!(md)
    compute_flex_capacity!(md)
    compute_shed_capacity!(md)
    compute_emission_target_aggregates!(md)
    compute_tech_activity!(md)
    init_policy_targets!(md)
    return md
end

# -----------------------------------------------------------------------------
# Temporal index helpers
# -----------------------------------------------------------------------------
"""
    compute_temporal_helpers!(md)

Build `dayPer_hour`, `hoursindayPer_hour`, `firstHourOfDay`, `lastHourOfDay`,
`prev_hour`, `next_hour` (cyclic) from `hours_orig` and `hoursPer_day`.
"""
function compute_temporal_helpers!(md::ModelData)
    s = md.sets
    p = md.params

    isempty(s.hours_orig) && return md
    p.hoursPer_day <= 0 && return md

    n_hours = length(s.hours_orig)
    n_days  = div(n_hours, p.hoursPer_day)

    empty!(p.dayPer_hour)
    empty!(p.hoursindayPer_hour)
    empty!(p.firstHourOfDay)
    empty!(p.lastHourOfDay)
    empty!(p.prev_hour)
    empty!(p.next_hour)
    empty!(p.slice_width_hours)
    empty!(p.hoursPerDayEffective)
    empty!(p.weekPer_hour)
    empty!(p.monthPer_hour)
    empty!(p.seasonPer_hour)
    empty!(p.semesterPer_hour)
    empty!(p.quarterPer_hour)
    empty!(p.rangePer_hour)
    empty!(p.rangePer_day)
    empty!(p.weekPer_day)
    empty!(p.monthPer_day)
    empty!(p.seasonPer_day)
    empty!(p.semesterPer_day)

    # IESA-Opt 1.0 uses calendar weeks 1..53 (52 + 1 partial), months 1..12,
    # seasons 1..4 (DJF=1, MAM=2, JJA=3, SON=4), semesters 1..2.
    # Approximations: week = ((d-1) ÷ 7) + 1 (capped at 53), month = `monthPer_hourOrig`
    # if loaded, else 12 equal bins; season = (month-1) ÷ 3 + 1 mapped; semester = (month-1) ÷ 6 + 1.
    days_per_range = max(1, p.daysPer_range)
    hours_per_quarter = max(1, p.hoursPer_quarter_cluster)

    for h in s.hours_orig
        d  = div(h - 1, p.hoursPer_day) + 1
        hd = mod(h - 1, p.hoursPer_day) + 1
        p.dayPer_hour[h] = d
        p.hoursindayPer_hour[h] = hd
        # slice_width_hours = how many actual clock-hours this slice represents.
        # For FH 24h: 1.0; for FH 12h: 2.0; for FH 8h: 3.0; for AS: variable
        p.slice_width_hours[h] = 24.0 / p.hoursPer_day
        p.hoursPerDayEffective[h] = Float64(p.hoursPer_day)
        # quarter-hour window: (h-1) ÷ hours_per_quarter + 1
        p.quarterPer_hour[h] = div(h - 1, hours_per_quarter) + 1
        # range (r_dayWindow): typically 3 days. range r = (d-1) ÷ days_per_range + 1
        p.rangePer_hour[h] = div(d - 1, days_per_range) + 1
    end

    # Per-day temporal mappings (IESA-Opt 1.0-equivalent: weekPer_day(d), monthPer_day(d), ...)
    for d in 1:n_days
        # week (1..53): 1-based 7-day buckets, day 365 → week 53
        wk = min(53, div(d - 1, 7) + 1)
        # month (1..12): try to pull from monthPer_hourOrig at first hour of day,
        # else fall back to even 12-month split (365/12 ≈ 30.42 days/month)
        first_h_of_d = (d - 1) * p.hoursPer_day + 1
        mo = if !isempty(p.monthPer_hourOrig)
            get(p.monthPer_hourOrig, first_h_of_d, max(1, min(12, div(d - 1, 31) + 1)))
        else
            max(1, min(12, div(d - 1, 31) + 1))
        end
        seas = (mo == 12 || mo <= 2) ? 1 : (mo <= 5 ? 2 : (mo <= 8 ? 3 : 4))
        sem  = (mo <= 6) ? 1 : 2

        p.weekPer_day[d]     = wk
        p.monthPer_day[d]    = mo
        p.seasonPer_day[d]   = seas
        p.semesterPer_day[d] = sem
        p.rangePer_day[d]    = div(d - 1, days_per_range) + 1

        p.firstHourOfDay[d] = first_h_of_d
        p.lastHourOfDay[d]  = d * p.hoursPer_day
    end

    # Per-hour week/month/season/semester (propagate from day)
    for h in s.hours_orig
        d = p.dayPer_hour[h]
        p.weekPer_hour[h]     = get(p.weekPer_day, d, 1)
        p.monthPer_hour[h]    = get(p.monthPer_day, d, 1)
        p.seasonPer_hour[h]   = get(p.seasonPer_day, d, 1)
        p.semesterPer_hour[h] = get(p.semesterPer_day, d, 1)
    end

    first_h = first(s.hours_orig)
    last_h  = last(s.hours_orig)
    for h in s.hours_orig
        p.prev_hour[h] = h == first_h ? last_h  : h - 1
        p.next_hour[h] = h == last_h  ? first_h : h + 1
    end
    return md
end

# -----------------------------------------------------------------------------
# Period weights / transition intervals
# -----------------------------------------------------------------------------
"""
    compute_period_indicators!(md)

Mirror IESA-Opt 1.0 exactly (lines ~2644-2680 + ~1893 in `MainProject/IESA-Opt.ams`):

- `period_weight[pss]` — "stair" formulation:
      if pss == last(periods_solve):
          10 / (val(last) - val(first) + 10)
      else:
          (val(next) - val(pss)) / (val(last) - val(first) + 10)
  Note: the 10 here is the "system-inertia" tail and **must be added to the
  base-period stretch**, matching IESA-Opt 1.0 `last_period_length`.

- `period_span[pss]` — in 5-year units (IESA-Opt 1.0 hard-codes /5):
      if pss == first(periods_solve): (val(pss) - 2015) / 5
      else:                            (val(pss) - val(prev)) / 5

- `transition_interval_scalar` — scalar across full `periods` set:
      val(last(periods)) - val(first(periods)) + 10
  Stored in `md.params.transition_interval[0]` (sentinel key) for scalar use,
  and per-period in `md.params.transition_interval[ps]` = same scalar (kept
  for compatibility with older callers).
"""
function compute_period_indicators!(md::ModelData)
    s = md.sets
    p = md.params

    empty!(p.period_weight)
    empty!(p.period_span)
    empty!(p.transition_interval)

    pss = isempty(s.periods_solve) ? s.periods : s.periods_solve
    n = length(pss)
    n == 0 && return md

    pss_first = first(pss)
    pss_last  = last(pss)
    denom = pss_last - pss_first + 10  # IESA-Opt 1.0 "+ 10" tail for inertia

    # period_weight — stair formulation
    for (i, ps) in enumerate(pss)
        if ps == pss_last
            p.period_weight[ps] = 10.0 / denom
        else
            next_ps = pss[i + 1]
            p.period_weight[ps] = (next_ps - ps) / denom
        end
    end

    # period_span — divided by 5 (IESA-Opt 1.0 hard-codes 5-year intervals)
    for (i, ps) in enumerate(pss)
        if ps == pss_first
            p.period_span[ps] = (ps - 2015) / 5.0
        else
            prev_ps = pss[i - 1]
            p.period_span[ps] = (ps - prev_ps) / 5.0
        end
    end

    # transition_interval — scalar across FULL periods set (not selection)
    full_periods = isempty(s.periods) ? pss : s.periods
    ti_scalar = last(full_periods) - first(full_periods) + 10
    # Store as both scalar (key=0) and per-period (matches scalar; IESA-Opt 1.0 uses
    # it as a scalar inside constraint sums multiplied per ps)
    p.transition_interval[0] = ti_scalar
    for ps in pss
        p.transition_interval[ps] = ti_scalar
    end
    return md
end

# -----------------------------------------------------------------------------
# Financial parameters
# -----------------------------------------------------------------------------
"""
    compute_financial_params!(md)

Capital recovery factor `CRF[t]` and social discount factor `social_discount_factor[p]`.

Formula (matches IESA-Opt 1.0 `CRF` definition):
    CRF(t) = ((1 - (1 + WACC)^(-1)) / (1 - (1 + WACC)^(-L))) * (1 + WACC)^0.5
where L = economic_lifetime.
"""
function compute_financial_params!(md::ModelData)
    s = md.sets
    p = md.params

    empty!(p.CRF)
    empty!(p.social_discount_factor)

    for (t, w) in p.WACC
        L = get(p.economic_lifetime, t, 25.0)
        if w > 0 && L > 0
            p.CRF[t] = ((1 - (1 + w)^(-1)) / (1 - (1 + w)^(-L))) * (1 + w)^0.5
        else
            p.CRF[t] = 1.0 / max(L, 1.0)
        end
    end

    r = p.social_discount_rate
    by = p.base_year
    for ps in s.periods
        p.social_discount_factor[ps] = (1 + r)^(by - ps)
    end
    return md
end

# -----------------------------------------------------------------------------
# Investment matrices
# -----------------------------------------------------------------------------
"""
    compute_investment_matrices!(md)

Build `InvMat_lifeTime[(t, inv_p, solve_p)]` and `decomMat_NewInv[(t, inv_p, solve_p)]`.

An investment made at period `inv_p` for technology `t` (with construction time
`ct` and economic lifetime `L_inv`) contributes to stock in any solve period
`solve_p` ∈ [inv_p + ct, inv_p + ct + L_inv).

A new-investment decommission event lands in `solve_p` if `inv_p + ct + L_decom`
falls strictly within `(prev_solve_p, solve_p]`.
"""
function compute_investment_matrices!(md::ModelData)
    s = md.sets
    p = md.params

    empty!(p.InvMat_lifeTime)
    empty!(p.decomMat_NewInv)

    # InvMat_lifeTime(t, jp, ps) = (ps <= jp + ec_lifetime(t)) * (ps >= jp)
    # IESA-Opt 1.0 line ~13848. Note: <=, not <. construction_time is NOT in this formula.
    periods = s.periods
    for (t, L_inv) in p.economic_lifetime
        for jp in periods
            invest_end = jp + L_inv  # inclusive upper bound per IESA-Opt 1.0
            for ps in periods
                if jp <= ps <= invest_end
                    p.InvMat_lifeTime[(t, jp, ps)] = 1.0
                end
            end
        end
    end

    # decomMat_NewInv(t, pa, ps) — IESA-Opt 1.0 line ~2748:
    #     (ps > pa + tec_lifetime(t)) * (ps >= pa)
    #   - (ps-1 > pa + tec_lifetime(t)) * (ps >= pa)
    # i.e. = 1 only on the FIRST ps after the lifetime expiry; 0 elsewhere.
    for (t, L_inv) in p.economic_lifetime
        L_decom = get(p.technical_lifetime, t, L_inv)
        for pa in periods
            decom_threshold = pa + L_decom
            for ps in periods
                if ps < pa
                    continue
                end
                a = (ps > decom_threshold) ? 1 : 0
                b = ((ps - 1) > decom_threshold) ? 1 : 0
                if (a - b) == 1
                    p.decomMat_NewInv[(t, pa, ps)] = 1.0
                end
            end
        end
    end
    return md
end

# -----------------------------------------------------------------------------
# Activity balances (with efficiency learning)
# -----------------------------------------------------------------------------
"""
    compute_activity_balances!(md)

Mirror IESA-Opt 1.0 `activity_balances`:

`round(activity_balancesOrig[t, a, p] + Σ grouped original activities, 5)`

where `activity_balancesOrig = activity_balancesRef * (1 - activity_EffImprov)`.

If `EffImprov` is absent for a key, the multiplier is 1.0.
"""
function compute_activity_balances!(md::ModelData)
    p = md.params

    empty!(p.activity_balances)
    orig = Dict{Tuple{Symbol,Symbol,Int},Float64}()
    for ((t, a, per), ref) in p.activity_balancesRef
        eff = get(p.activity_EffImprov, (t, a, per), 0.0)
        orig[(t, a, per)] = ref * (1.0 - eff)
    end

    final_keys = Set{Tuple{Symbol,Symbol,Int}}()
    for (key, _) in orig
        push!(final_keys, key)
        t, a, per = key
        grouped = get(p.act_to_group, a, a)
        if grouped != a
            push!(final_keys, (t, grouped, per))
        end
    end

    grouped_children = Dict{Symbol,Vector{Symbol}}()
    for (orig_act, grouped_act) in p.act_to_group
        push!(get!(() -> Symbol[], grouped_children, grouped_act), orig_act)
    end

    for (t, a, per) in final_keys
        value = get(orig, (t, a, per), 0.0)
        for child in get(grouped_children, a, Symbol[])
            value += get(orig, (t, child, per), 0.0)
        end
        rounded = round(value; digits = 5)
        rounded != 0.0 && (p.activity_balances[(t, a, per)] = rounded)
    end
    return md
end

# -----------------------------------------------------------------------------
# CHP power-to-heat ratio
# -----------------------------------------------------------------------------
"""
    compute_chp_eps!(md)

CHP_eps[(t, p)] mirrors IESA-Opt 1.0:

    sum[iah | dP_electricity(t,iah)=1, activity_balances(t,iah,p)] /
    (-activity_balances(t,CHP_fuel(t),p) - activity_balances(t,CHP_prod(t),p)/CHP_eta_safe(t))

where `dP_electricity` is the base-year positive electricity-output selector.
"""
function compute_chp_eps!(md::ModelData)
    s = md.sets
    p = md.params

    empty!(p.CHP_eps)
    electricity_label = Symbol("Electricity")
    by = p.base_year
    for t in s.tech_hourlyCHPflex
        η = get(p.CHP_eta, t, 0.0)
        η_safe = η >= 0.05 ? η : 0.05
        prod = get(p.CHP_prod, t, Symbol(""))
        fuel = get(p.CHP_fuel, t, Symbol(""))
        prod == Symbol("") && continue
        fuel == Symbol("") && continue
        electricity_activities = Symbol[]
        for ah in s.activities_hour
            get(p.activity_balances, (t, ah, by), 0.0) > 0.0 || continue
            get(p.labelPer_act, ah, Symbol("")) == electricity_label || continue
            push!(electricity_activities, ah)
        end
        for per in s.periods
            numerator = sum(get(p.activity_balances, (t, iah, per), 0.0) for iah in electricity_activities)
            denominator = -get(p.activity_balances, (t, fuel, per), 0.0) - get(p.activity_balances, (t, prod, per), 0.0) / η_safe
            p.CHP_eps[(t, per)] = abs(denominator) > 1e-12 ? numerator / denominator : 0.0
        end
    end
    return md
end

# -----------------------------------------------------------------------------
# Activity indicators (binary indicators per tech for flex / shed / buffer)
# -----------------------------------------------------------------------------
"""
    compute_activity_indicators!(md)

`dQ_hourly[(t, a)] = 1` if activity `a` is the main flex activity of tech `t`
(i.e. `flex_activity[t] == a`). Similarly `dS_hourly`, `dW_hourly` for storage
and weekly-flex techs. Used in the model formulation as multipliers for
flex-state propagation constraints.
"""
function compute_activity_indicators!(md::ModelData)
    s = md.sets
    p = md.params

    empty!(p.dQ_hourly)
    empty!(p.dS_hourly)
    empty!(p.dW_hourly)
    empty!(p.dB_daily)
    empty!(p.dP_electricity)
    empty!(p.dP_heat)

    for t in s.tech_flexible
        a = get(p.flex_activity, t, Symbol(""))
        a == Symbol("") && continue
        p.dQ_hourly[(t, a)] = 1.0
        if t in s.tech_fStorage || t in s.tech_fWithBattery
            p.dS_hourly[(t, a)] = 1.0
        end
        if t in s.tech_flexW || t in s.tech_flexM || t in s.tech_flexS
            p.dW_hourly[(t, a)] = 1.0
        end
    end

    for tg in s.tech_gasBuffer
        ad = get(p.buffer_activity, tg, Symbol(""))
        ad == Symbol("") && continue
        p.dB_daily[(tg, ad)] = 1.0
    end

    electricity_label = Symbol("Electricity")
    by = p.base_year
    for tk in s.tech_hourlyCHPflex
        for ah in s.activities_hour
            get(p.activity_balances, (tk, ah, by), 0.0) > 0.0 || continue
            get(p.labelPer_act, ah, Symbol("")) == electricity_label || continue
            p.dP_electricity[(tk, ah)] = 1.0
        end
        prod = get(p.CHP_prod, tk, Symbol(""))
        prod == Symbol("") || (p.dP_heat[(tk, prod)] = 1.0)
    end
    return md
end

# -----------------------------------------------------------------------------
# Unified tech_activity mapping
# IESA-Opt 1.0 line 1973: tech_activity(t) := activityPer_tech(t) if t∈tech_balancers
#                                       else infra_activity(t) if t∈tech_infra
# Used by infrastructure constraints (infraVol_*) and many balance reductions.
# -----------------------------------------------------------------------------
"""
    compute_tech_activity!(md::ModelData)

Fill `params.tech_activity[t]` with the single primary activity of each tech.
For balancer techs, use `activityPer_tech[t]` (post-grouping). For infra techs,
use `infra_activity[t]`. Missing entries default to `Symbol("")`.
"""
function compute_tech_activity!(md::ModelData)
    s = md.sets
    p = md.params
    empty!(p.tech_activity)
    for t in s.tech_balancers
        a = get(p.activityPer_tech, t, get(p.activityPer_techOrig, t, Symbol("")))
        a != Symbol("") && (p.tech_activity[t] = a)
    end
    for t in s.tech_infra
        a = get(p.infra_activity, t, get(p.infra_activityOrig, t, Symbol("")))
        a != Symbol("") && (p.tech_activity[t] = a)
    end
    return md
end

# -----------------------------------------------------------------------------
# Policy / regulatory targets (hard-coded constants from IESA-Opt 1.0 source)
# IESA-Opt 1.0 lines 20913-21015 — these are scalar parameters with period-indexed values.
# -----------------------------------------------------------------------------
"""
    init_policy_targets!(md::ModelData)

Populate the policy-target dictionaries (`ReFuelEU_Aviation_eSAF_target`,
`ReFuelEU_Aviation_SAF_target`, `FuelEU_Maritime_target`) with the hard-coded
year-indexed values from the IESA-Opt 1.0 source. Idempotent; clears before writing.

Values (per period, IESA-Opt 1.0 source verbatim):
  - ReFuelEU eSAF fraction: 2030→0.012, 2035→0.050, 2040→0.100, 2045→0.150, 2050→0.350
  - ReFuelEU SAF  fraction: 2030→0.060, 2035→0.200, 2040→0.340, 2045→0.420, 2050→0.700
  - FuelEU Maritime intensity reduction (g CO2eq/MJ): 2030→35.0, 2035→32.2, 2040→26.7, 2045→16.4, 2050→10.4
"""
function init_policy_targets!(md::ModelData)
    p = md.params
    empty!(p.ReFuelEU_Aviation_eSAF_target)
    empty!(p.ReFuelEU_Aviation_SAF_target)
    empty!(p.FuelEU_Maritime_target)

    p.ReFuelEU_Aviation_eSAF_target[2030] = 0.012
    p.ReFuelEU_Aviation_eSAF_target[2035] = 0.050
    p.ReFuelEU_Aviation_eSAF_target[2040] = 0.100
    p.ReFuelEU_Aviation_eSAF_target[2045] = 0.150
    p.ReFuelEU_Aviation_eSAF_target[2050] = 0.350

    p.ReFuelEU_Aviation_SAF_target[2030] = 0.060
    p.ReFuelEU_Aviation_SAF_target[2035] = 0.200
    p.ReFuelEU_Aviation_SAF_target[2040] = 0.340
    p.ReFuelEU_Aviation_SAF_target[2045] = 0.420
    p.ReFuelEU_Aviation_SAF_target[2050] = 0.700

    p.FuelEU_Maritime_target[2030] = 35.0
    p.FuelEU_Maritime_target[2035] = 32.2
    p.FuelEU_Maritime_target[2040] = 26.7
    p.FuelEU_Maritime_target[2045] = 16.4
    p.FuelEU_Maritime_target[2050] = 10.4
    return md
end

# -----------------------------------------------------------------------------
# Decommissioning filter
# -----------------------------------------------------------------------------
"""
    compute_decom_planned_sel!(md)

Mirror IESA-Opt 1.0 line 2752:
    decom_plannedSel(t, ps) = sum[ip | (ps-1) < ip <= ps, decom_planned(t, ip)]
where `ps-1` is the **previous element of `periods_solve`** (the set sometimes
called `periods_selection` in IESA-Opt 1.0), NOT `ps minus 1` arithmetic.

Concretely: for each solved period `ps`, accumulate `decom_planned(t, ip)` over
all database years `ip` strictly greater than the previous solved year and
less-than-or-equal to `ps`. For the first solved period, "previous" is treated
as the smallest year present in `decom_planned` minus 1 (so the cumulative sum
captures every planned decommissioning year up to and including `ps`).

This is how IESA-Opt 1.0 converts year-of-database decommissioning into solving-set
years, e.g. if the database has decom for 2025 but we solve {2020, 2030, 2040,
2050}, the 2025 event is folded into the 2030 `decom_plannedSel` entry.
"""
function compute_decom_planned_sel!(md::ModelData)
    s = md.sets
    p = md.params

    empty!(p.decom_plannedSel)
    isempty(s.periods_solve) && return md
    isempty(p.decom_planned) && return md

    # Sorted solved periods
    pss_sorted = sort(collect(s.periods_solve))

    # Group decom_planned by tech for efficient per-tech accumulation
    by_tech = Dict{Symbol,Vector{Tuple{Int,Float64}}}()
    for ((t, ip), v) in p.decom_planned
        v == 0.0 && continue
        push!(get!(by_tech, t, Vector{Tuple{Int,Float64}}()), (ip, v))
    end

    for (t, entries) in by_tech
        # Pre-sort by year so we can scan in order against the solved boundaries
        sort!(entries, by = x -> x[1])
        for (i, ps) in enumerate(pss_sorted)
            lower_excl = i == 1 ? typemin(Int) : pss_sorted[i - 1]
            acc = 0.0
            for (ip, v) in entries
                if lower_excl < ip <= ps
                    acc += v
                end
            end
            if acc != 0.0
                p.decom_plannedSel[(t, ps)] = acc
            end
        end
    end
    return md
end

# -----------------------------------------------------------------------------
# Flex-loss split (Phase 7 storage upgrade)
# -----------------------------------------------------------------------------
"""
    compute_flex_loss_split!(md)

Mirror the IESA-Opt 1.0 storage loss definitions used by the solver-facing run:
    flex_loss_discharge          (raw input from sheet column BD; loaded into
                                  `flex_losses_legacy[t]` here)
    flex_loss_discharge_eff(tb) = min(flex_loss_discharge(tb), 0.99)
    flex_loss_charge(tb)        = flex_loss_discharge(tb)

`flex_standing_loss_effective` is left at 0.0 unless explicit input data has
already populated it. The target IESA-Opt 1.0 MPS has storage-state coefficients of
exactly -1, so the declaration InitialData is not active in the generated LP.

Despite its name, IESA-Opt 1.0 `flex_loss_discharge_eff` is the *loss* fraction
(capped at 0.99 to keep `1/(1-loss)` finite), NOT the discharge efficiency.
Constraints use `(1 - flex_loss_charge)` and `1/(1 - flex_loss_discharge_eff)`,
so feeding in a small loss yields ≈1 inverse-efficiency multipliers.

Callers can override these by writing into the dicts directly after read.
"""
function compute_flex_loss_split!(md::ModelData)
    p = md.params

    for (t, total_loss) in p.flex_losses_legacy
        # Already populated by an upstream source: don't overwrite
        haskey(p.flex_loss_charge, t)         || (p.flex_loss_charge[t]         = total_loss)
        haskey(p.flex_loss_discharge_eff, t)  || (p.flex_loss_discharge_eff[t]  = min(total_loss, 0.99))
        if haskey(p.flex_standing_loss, t) && !haskey(p.flex_standing_loss_effective, t)
            p.flex_standing_loss_effective[t] = min(p.flex_standing_loss[t], 1.85522e-5)
        end
    end
    return md
end

# -----------------------------------------------------------------------------
# Flex indicator helpers (IESA-Opt 1.0 lines 3289-3309 region)
# -----------------------------------------------------------------------------
"""
    compute_flex_indicators!(md)

Populate `is_BEshifting_tech[t]` for every `tech_balancers` element. Mirrors
IESA-Opt 1.0 line 3289 (Parameter `is_BEshifting_tech` — true when
`flexibilityType_tech(tb) = 'BE shifting'`).

Independent of clustering. Run from `compute_derived_params!`.
"""
function compute_flex_indicators!(md::ModelData)
    s = md.sets
    p = md.params
    empty!(p.is_BEshifting_tech)
    empty!(p.flex_backlog_horizon_days)
    BE = :BEshifting
    BE_alt = Symbol("BE shifting")  # support both Symbol forms
    for t in s.tech_balancers
        ft = get(p.flexibilityType_tech, t, Symbol(""))
        p.is_BEshifting_tech[t] = (ft == BE) || (ft == BE_alt)
    end
    for t in s.tech_flexible
        range = get(p.flex_range, t, Symbol(""))
        p.flex_backlog_horizon_days[t] = if range == Symbol("1 day [d]")
            1
        elseif range == Symbol("3 days [r]")
            p.daysPer_range
        elseif range == Symbol("1 week [w]")
            7
        elseif range == Symbol("1 month [m]")
            30
        elseif range == Symbol("1 season [s]")
            91
        elseif range == Symbol("6 months [b]")
            182
        else
            365
        end
    end
    return md
end

# -----------------------------------------------------------------------------
# Cluster-resolution flex helpers (post-clustering)
# IESA-Opt 1.0 lines 4543/4698/4793/4842 region — RHS aggregates and EV helpers.
# -----------------------------------------------------------------------------
"""
    compute_flex_TS_helpers!(md)

Populate cluster-dependent helper parameters used by the TS flex constraints:

- `cumulativeS_dQtfv_helper1_TS[(tfv, hc)]` =
      `hourly_profiles_cluster[hc, profileType_EVuse[tfv]] / avg_speed[tfv]`
  (IESA-Opt 1.0 — used in EV cumulative state of charge `cumulativeS_dQtfv_TS`).
- `cumulativeS_dQtfv_helper2_TS[(tfv, hc)]` = 0 (IESA-Opt 1.0 default).
- `cumulativeUP_DW_dQtfe_helper_TS[(hc, tfe, ps)]` =
      `hourly_profiles_cluster[hc, profileType_tech[tfe]] *
       activity_balances[tfe, flex_activity[tfe], ps]`
  (IESA-Opt 1.0 — per-cluster-hour BE shifting RHS).
- `cumulative_dQtfe_rhs_TS[(qc, tfe, ps)]` =
      `sum_{ihc | quarterPer_clusterHour(ihc)=qc} clusterHourWeight(ihc) *
        cumulativeUP_DW_dQtfe_helper_TS[(ihc, tfe, ps)]`
  (IESA-Opt 1.0 — quarter-window aggregated RHS for `cumulativeUP/DW_dQtfe_TS`).

Must be called AFTER `build_temporal_clusters!` populates
`hourly_profiles_cluster`, `clusterHourWeight`, `quarterPer_clusterHour`.
"""
function compute_flex_TS_helpers!(md::ModelData)
    s = md.sets
    p = md.params

    empty!(p.cumulativeS_dQtfv_helper1_TS)
    empty!(p.cumulativeS_dQtfv_helper2_TS)
    empty!(p.cumulativeUP_DW_dQtfe_helper_TS)
    empty!(p.cumulative_dQtfe_rhs_TS)
    empty!(p.repDayWeight_range)
    empty!(p.repDayWeight_week)
    empty!(p.repDayWeight_month)
    empty!(p.repDayWeight_season)
    empty!(p.repDayWeight_semester)
    empty!(p.repDayWeight_year)

    pss = isempty(s.periods_solve) ? s.periods : s.periods_solve

    # 0. IESA-Opt 1.0 line ~7682:
    #     repDayWeight_range(rd, r)    := sum[id | mapDay_repDay(id)=rd ∧ rangePer_day(id)=r,    1]
    #     repDayWeight_week(rd, w)     := sum[id | mapDay_repDay(id)=rd ∧ weekPer_day(id)=w,     1]
    #     repDayWeight_month(rd, m)    := sum[id | mapDay_repDay(id)=rd ∧ monthPer_day(id)=m,    1]
    #     repDayWeight_season(rd, sn)  := sum[id | mapDay_repDay(id)=rd ∧ seasonPer_day(id)=sn,  1]
    #     repDayWeight_semester(rd, b) := sum[id | mapDay_repDay(id)=rd ∧ semesterPer_day(id)=b, 1]
    # i.e. for each (rd, scope) the count of calendar days that map to rd AND fall in that scope.
    # Used by balanceR/W/M/S/B_deltaQd_TS (lines 4708-4724) and balanceW_deltaHchp_TS (line ~3608).
    # If left empty, those constraints become 0=0 and impose NO round-trip-loss balance — which
    # silently makes weekly/monthly/seasonal storage techs (PNL03_02/04, etc.) "free".
    for (d, rd) in p.mapDay_repDay
        r  = get(p.rangePer_day,    d, 0)
        w  = get(p.weekPer_day,     d, 0)
        mo = get(p.monthPer_day,    d, 0)
        sn = get(p.seasonPer_day,   d, 0)
        bm = get(p.semesterPer_day, d, 0)
        if r  != 0; key = (rd, r);  p.repDayWeight_range[key]    = get(p.repDayWeight_range,    key, 0.0) + 1.0; end
        if w  != 0; key = (rd, w);  p.repDayWeight_week[key]     = get(p.repDayWeight_week,     key, 0.0) + 1.0; end
        if mo != 0; key = (rd, mo); p.repDayWeight_month[key]    = get(p.repDayWeight_month,    key, 0.0) + 1.0; end
        if sn != 0; key = (rd, sn); p.repDayWeight_season[key]   = get(p.repDayWeight_season,   key, 0.0) + 1.0; end
        if bm != 0; key = (rd, bm); p.repDayWeight_semester[key] = get(p.repDayWeight_semester, key, 0.0) + 1.0; end
    end
    # repDayWeight_year[rd] = #days mapped to rd (== dayWeight[rd]); kept for completeness even
    # though IESA-Opt 1.0 balanceY_deltaQd_TS uses dayWeight directly.
    for (rd, dw) in p.dayWeight
        p.repDayWeight_year[rd] = dw
    end

    # 1. EV state-of-charge helper1 = profile / avg_speed
    for tfv in s.tech_fEV
        prof_t = get(p.profileType_EVuse, tfv, Symbol(""))
        spd    = get(p.avg_speed, tfv, 0.0)
        (prof_t == Symbol("") || spd == 0.0) && continue
        for hc in s.hours_cluster
            v = get(p.hourly_profiles_cluster, (hc, prof_t), 0.0) / spd
            p.cumulativeS_dQtfv_helper1_TS[(tfv, hc)] = v
            p.cumulativeS_dQtfv_helper2_TS[(tfv, hc)] = 0.0
        end
    end

    # 2. BE-shifting helper per cluster hour: profile × activity_balance
    for tfe in s.tech_fBEshifting
        prof_t = get(p.profileType_tech, tfe, Symbol(""))
        fa     = get(p.flex_activity, tfe, Symbol(""))
        (prof_t == Symbol("") || fa == Symbol("")) && continue
        for ps in pss
            ab = get(p.activity_balances, (tfe, fa, ps), 0.0)
            ab == 0.0 && continue
            for hc in s.hours_cluster
                v = get(p.hourly_profiles_cluster, (hc, prof_t), 0.0) * ab
                p.cumulativeUP_DW_dQtfe_helper_TS[(hc, tfe, ps)] = v
            end
        end
    end

    # 3. Quarter-window RHS aggregate
    for ((hc, tfe, ps), v) in p.cumulativeUP_DW_dQtfe_helper_TS
        qc = get(p.quarterPer_clusterHour, hc, 0)
        qc == 0 && continue
        w  = get(p.clusterHourWeight, hc, 1.0)
        key = (qc, tfe, ps)
        p.cumulative_dQtfe_rhs_TS[key] = get(p.cumulative_dQtfe_rhs_TS, key, 0.0) + w * v
    end

    return md
end

# -----------------------------------------------------------------------------
# flex_capacity (IESA-Opt 1.0 line ~3997: Parameter flex_capacity)
# -----------------------------------------------------------------------------
"""
    compute_flex_capacity!(md)

Derive `flex_capacity[t,ps]` from `flex_capacity_pct[t]`, peak profile value,
`activity_balances[t, flex_activity, ps]`, and `cap2act[t]`. IESA-Opt 1.0 formula
(IESA-Opt.ams line ~3997):

```
flex_capacity(tb, ps) :=
    if flexibilityType_tech(tb) = 'Storage' then
        flex_capacity_pct(tb) * max_h hourly_profiles(h, profileType_tech(tb)) * cap2act(tb)
    else
        flex_capacity_pct(tb) * max_h hourly_profiles(h, profileType_tech(tb))
            * (-1 * activity_balances(tb, flex_activity(tb), ps)) * cap2act(tb)
    endif
```

The peak profile uses the **full-hourly** profile (`hourly_profiles`) over all
`hours_orig`, not the clustered one — IESA-Opt 1.0 computes this before clustering.
"""
function compute_flex_capacity!(md::ModelData)
    s = md.sets
    p = md.params

    empty!(p.flex_capacity)

    # Precompute peak profile value per profile_type over all hours.
    # IESA-Opt 1.0 evaluates this lazily: uses whichever `hourly_profiles` is current
    # at solve time. We fall back to `hourly_profilesReadOrig` (raw 8760) if
    # the cluster-resolved one is empty, so that callers running
    # `compute_derived_params!` before clustering still get correct values.
    profile_dict = !isempty(p.hourly_profiles)            ? p.hourly_profiles            :
                   !isempty(p.hourly_profilesRead)        ? p.hourly_profilesRead        :
                                                            p.hourly_profilesReadOrig
    peak_by_profile = Dict{Symbol,Float64}()
    for ((_, ptype), v) in profile_dict
        cur = get(peak_by_profile, ptype, -Inf)
        v > cur && (peak_by_profile[ptype] = v)
    end

    # IESA-Opt 1.0 hourly_profiles Definition (line 3031): for yp ∈ activities_indirect,
    #   hourly_profiles(h, yp) :=
    #     sum[itb | activity_balances(itb,yp,base_year) < 0,
    #         hourly_profilesRead(h, profileType_techRead(itb)) * activity_balances(itb,yp,base_year)]
    #     / sum[itb | activity_balances(itb,yp,base_year) < 0, activity_balances(itb,yp,base_year)]
    # The peak over h then matters for flex_capacity. Compute resolved peak for indirect activities.
    ind_set = isempty(s.activities_indirect) ? Set{Symbol}() : Set(s.activities_indirect)
    if !isempty(ind_set) && !isempty(p.hourly_profilesReadOrig) &&
       !isempty(p.profileType_techRead) && !isempty(p.activity_balances)
        by = p.base_year
        # Build consumer list per indirect activity once.
        consumers_for = Dict{Symbol, Vector{Tuple{Symbol,Float64}}}()
        for ((t, a, ps), ab) in p.activity_balances
            (ps == by && ab < 0.0 && a in ind_set) || continue
            ptr = get(p.profileType_techRead, t, Symbol(""))
            ptr == Symbol("") && continue
            push!(get!(() -> Tuple{Symbol,Float64}[], consumers_for, a), (ptr, ab))
        end
        # Hours that appear in raw profile dict.
        h_orig_set = Set{Int}()
        for (h_orig, _) in keys(p.hourly_profilesReadOrig)
            push!(h_orig_set, h_orig)
        end
        for (yp, cs) in consumers_for
            denom = sum(ab for (_, ab) in cs)
            denom == 0.0 && continue
            local_peak = -Inf
            for h_orig in h_orig_set
                num = 0.0
                for (ptr, ab) in cs
                    num += get(p.hourly_profilesReadOrig, (h_orig, ptr), 0.0) * ab
                end
                v = num / denom
                v > local_peak && (local_peak = v)
            end
            local_peak > -Inf && (peak_by_profile[yp] = local_peak)
        end
    end

    storage_sym = Symbol("Storage")

    for (tb, fpct) in p.flex_capacity_pct
        fpct == 0.0 && continue
        ptype = get(p.profileType_tech, tb, Symbol(""))
        ptype == Symbol("") && continue
        peak = get(peak_by_profile, ptype, 0.0)
        peak == 0.0 && continue
        c2a = get(p.cap2act, tb, 0.0)
        c2a == 0.0 && continue
        ftype = get(p.flexibilityType_tech, tb, Symbol(""))
        ftype == Symbol("") && continue

        if ftype == storage_sym
            for ps in s.periods
                p.flex_capacity[(tb, ps)] = fpct * peak * c2a
            end
        else
            fa = get(p.flex_activity, tb, Symbol(""))
            fa == Symbol("") && continue
            for ps in s.periods
                ab = get(p.activity_balances, (tb, fa, ps), 0.0)
                ab == 0.0 && continue
                p.flex_capacity[(tb, ps)] = fpct * peak * (-ab) * c2a
            end
        end
    end
    return md
end

# -----------------------------------------------------------------------------
# shed_capacity (IESA-Opt 1.0 line ~3972: Parameter shed_capacity)
# -----------------------------------------------------------------------------
"""
    compute_shed_capacity!(md)

Derive `shed_capacity[ts,ps]` from the IESA-Opt 1.0 definition:

```
shed_capacity(ts, ps) :=
    shed_capacity_percentage(ts) * max_h hourly_profiles(h, profileType_tech(ts)) * cap2act(ts)
```

Like `flex_capacity`, the peak profile is taken over full-hourly profiles, not
clustered profiles.
"""
function compute_shed_capacity!(md::ModelData)
    s = md.sets
    p = md.params

    empty!(p.shed_capacity)

    profile_dict = !isempty(p.hourly_profiles)            ? p.hourly_profiles            :
                   !isempty(p.hourly_profilesRead)        ? p.hourly_profilesRead        :
                                                            p.hourly_profilesReadOrig
    peak_by_profile = Dict{Symbol,Float64}()
    for ((_, ptype), v) in profile_dict
        cur = get(peak_by_profile, ptype, -Inf)
        v > cur && (peak_by_profile[ptype] = v)
    end

    for (ts, pct) in p.shed_capacity_percentage
        pct == 0.0 && continue
        ptype = get(p.profileType_tech, ts, Symbol(""))
        ptype == Symbol("") && continue
        peak = get(peak_by_profile, ptype, 0.0)
        peak == 0.0 && continue
        c2a = get(p.cap2act, ts, 0.0)
        c2a == 0.0 && continue
        for ps in s.periods
            p.shed_capacity[(ts, ps)] = pct * peak * c2a
        end
    end
    return md
end

# -----------------------------------------------------------------------------
# Emission-target aggregates
# -----------------------------------------------------------------------------
"""
    compute_emission_target_aggregates!(md)

Derive aggregate emission-target parameters that IESA-Opt 1.0 computes via
`Definition:` clauses:

- `emissionTarget_inclScope3andFuelex[p]` = `sum[n|n='NL', emissionTargetAll(n, p)]`
  (IESA-Opt 1.0 line ~2349). Reduces to the single NL row of `emissionTargetAll` if it
  exists, else 0.

Other aggregates (`emissionTarget_Bunkers`, `emissionTarget_FeedStocks`,
`emissionTarget_cum`) are loaded directly from the XLSX, not derived.
"""
function compute_emission_target_aggregates!(md::ModelData)
    p = md.params
    empty!(p.emissionTarget_inclScope3andFuelex)

    nl = :NL
    for ((n, per), v) in p.emissionTargetAll
        if n == nl
            p.emissionTarget_inclScope3andFuelex[per] = v
        end
    end
    return md
end
