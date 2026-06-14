# =============================================================================
# scripts/scenario_poc_co2cap.jl
#
# Phase 2 proof-of-concept: in-place LP mutation vs full rebuild.
#
# Goal: prove that mutating the RHS of one emission-cap constraint on an
# already-built JuMP+HiGHS model yields the same objective as rebuilding the
# whole LP from scratch with the same parameter value. Also time both paths
# so we have a first data point for the speed-up the manifest design is
# supposed to deliver.
#
# Parameter under test: `emissionTargetBunker[(:NL, 2050)]`
#   * Single RHS in `emTargetBunker[NL,2050]`. Baseline value 7.7 in the
#     default workbook — non-zero, binding. Sweep multipliers ∈ {0.5, 1.0, 2.0}
#     applied to the baseline so we get both tighter and looser caps.
#
# Run:  julia --project=. scripts/scenario_poc_co2cap.jl
# Skip:  IESA_OPT_SKIP_PRECOMPILE=1 IESA_OPT_SKIP_WARMUP=1 julia --project=. ...
# Solver: HiGHS by default (no Gurobi license needed for the PoC).
# Mode:   TS (single rep day) so wall-clock stays under a minute on a laptop.
# =============================================================================

using IESAOpt
using JuMP
using HiGHS
using Printf

const NODE       = :NL
const PERIOD     = 2050
const PARAM      = :emissionTargetBunker        # leaf field in ModelParams
const CONS_NAME  = "emTargetBunker[NL,2050]"    # constraint base_name
const MULTIPLIERS = [0.5, 1.0, 2.0]
const OBJ_TOL    = 1e-3   # relative tolerance, dimensionless

# -----------------------------------------------------------------------------
# Workbook + ModelData prep (shared, NOT mutated)
# -----------------------------------------------------------------------------
workbook = normpath(joinpath(@__DIR__, "..", "data", "default_data.xlsx"))
isfile(workbook) || error("Default workbook not found: $workbook")

println("=== Loading + preparing ModelData ===")
md_base = read_data_cached(workbook)
md_base === nothing && error("read_data_cached returned nothing")
md_base = deepcopy(md_base)

# TS smoke-config: 1 rep day, 24 h — keeps the PoC fast.
md_base.sets.periods_solve = [PERIOD]
md_base.params.hoursPer_day = 24
md_base.params.n_repDays = 1
md_base.params.hoursPer_day_cluster = 24
md_base.params.clustering_approach = :kmeans_avg
md_base.params.ts_extremePeriods = false
md_base.params.ts_extremeDays_count = 0
md_base.params.ts_boundaryRamping = true
md_base.params.ts_capacityProfile_autoMode = true
md_base.params.ts_capacityProfile_autoFloor = 0.23
md_base.params.ts_capacityProfile_autoCap = 1.00
md_base.params.ts_capacityProfile_autoFloor_effective = 0.23
md_base.params.ts_capacityProfile_envelopeMode = 0
md_base.params.dayMix_softness = 0.0
md_base.params.dayMix_weightType = :auto

derive_sets!(md_base)
compute_derived_params!(md_base)
build_temporal_clusters!(md_base)

baseline_cap = get(md_base.params.emissionTargetBunker, (NODE, PERIOD), nothing)
baseline_cap === nothing &&
    error("$(PARAM)[($(NODE),$(PERIOD))] missing in workbook — pick a different node/period.")
baseline_cap == 0.0 &&
    error("$(PARAM)[($(NODE),$(PERIOD))] is zero in the workbook — multiplier sweep would be vacuous. Pick a non-zero baseline.")
@printf "Baseline cap value: %s[%s,%d] = %.6f\n" String(PARAM) NODE PERIOD baseline_cap

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
function _new_highs_model()
    m = Model(HiGHS.Optimizer)
    set_silent(m)
    set_attribute(m, "solver", "simplex")
    set_attribute(m, "parallel", "off")
    # Scenario-space mutation REQUIRES string names on constraints so
    # `constraint_by_name(model, "emTargetAir[NL,2050]")` works post-build.
    apply_lp_generation_speedups!(m; keep_names = true)
    return m
end

function build_and_solve(md)
    t_build = @elapsed begin
        m = _new_highs_model()
        build_ts_lp!(m, md)
    end
    t_solve = @elapsed optimize!(m)
    term = string(termination_status(m))
    obj  = term == "OPTIMAL" ? objective_value(m) : NaN
    return (model = m, obj = obj, term = term, t_build = t_build, t_solve = t_solve)
end

function reload_md_with_cap(cap_value)
    md = deepcopy(md_base)
    md.params.emissionTargetBunker[(NODE, PERIOD)] = cap_value
    # Re-derive so any downstream derived params that read the cap see it.
    compute_derived_params!(md)
    return md
end

# -----------------------------------------------------------------------------
# 1. Baseline build + solve (will be reused for in-place mutations)
# -----------------------------------------------------------------------------
println("\n=== Build + solve baseline (cap = $baseline_cap) ===")
md_for_inplace = deepcopy(md_base)
inplace_res = build_and_solve(md_for_inplace)
@printf "Baseline: term=%s obj=%.6f build=%.2fs solve=%.2fs\n" inplace_res.term inplace_res.obj inplace_res.t_build inplace_res.t_solve
inplace_res.term == "OPTIMAL" || error("Baseline solve failed: $(inplace_res.term)")

# Confirm the constraint exists with the right name.
con_ref = constraint_by_name(inplace_res.model, CONS_NAME)
con_ref === nothing &&
    error("Constraint `$CONS_NAME` not found in model — " *
          "did you forget `apply_lp_generation_speedups!(m; keep_names=true)`?")

println("\n=== Mutation vs rebuild sweep ===")
@printf "%-7s | %-15s | %-15s | %-15s | %-13s | %-13s | %-13s | %-13s\n" "mult" "cap" "obj_mutate" "obj_rebuild" "obj_rel_diff" "t_mut_solve" "t_rebuild_b" "t_rebuild_s"
@printf "%s\n" repeat('-', 130)

results = Vector{NamedTuple}()
for mult in MULTIPLIERS
    cap = baseline_cap * mult

    # --- Path A: in-place mutation on the existing solved model ---
    md_inp = deepcopy(md_base)
    md_inp.params.emissionTargetBunker[(NODE, PERIOD)] = cap
    t_mut_apply = @elapsed apply_variant!(inplace_res.model, md_inp,
        LeafChange[LeafChange(PARAM, (NODE, PERIOD), cap)];
        rederive = true)
    t_mut_solve = @elapsed optimize!(inplace_res.model)
    term_mut = string(termination_status(inplace_res.model))
    obj_mut  = term_mut == "OPTIMAL" ? objective_value(inplace_res.model) : NaN

    # --- Path B: full rebuild on a fresh model + ModelData copy ---
    md_rb = reload_md_with_cap(cap)
    rb = build_and_solve(md_rb)

    rel_diff = isfinite(obj_mut) && isfinite(rb.obj) && abs(rb.obj) > 0 ?
               abs(obj_mut - rb.obj) / abs(rb.obj) : NaN

    @printf "%-7.2f | %-15.6f | %-15.6f | %-15.6f | %-13.2e | %-13.3f | %-13.3f | %-13.3f\n" mult cap obj_mut rb.obj rel_diff t_mut_solve rb.t_build rb.t_solve

    push!(results, (mult = mult, cap = cap, obj_mut = obj_mut, obj_rb = rb.obj,
                    rel_diff = rel_diff, t_mut_apply = t_mut_apply,
                    t_mut_solve = t_mut_solve, t_rebuild_build = rb.t_build,
                    t_rebuild_solve = rb.t_solve))
end

# -----------------------------------------------------------------------------
# Verdict
# -----------------------------------------------------------------------------
println("\n=== Verdict ===")
all_match = all(r -> isfinite(r.rel_diff) && r.rel_diff < OBJ_TOL, results)
if all_match
    println("PASS: in-place mutation matched full-rebuild objective within $(OBJ_TOL) relative tolerance for every cap multiplier.")
else
    println("FAIL: at least one cap value gave different objectives between mutation and rebuild — see table above.")
end

avg_mut_solve   = sum(r.t_mut_solve for r in results) / length(results)
avg_rebuild_all = sum(r.t_rebuild_build + r.t_rebuild_solve for r in results) / length(results)
avg_rebuild_b   = sum(r.t_rebuild_build for r in results) / length(results)
avg_rebuild_s   = sum(r.t_rebuild_solve for r in results) / length(results)
@printf "\nAverage timings across %d variants:\n" length(results)
@printf "  mutate-then-solve     : %.3f s  (just optimize! after apply_variant!)\n" avg_mut_solve
@printf "  rebuild build + solve : %.3f s  (%.3f s build + %.3f s solve)\n" avg_rebuild_all avg_rebuild_b avg_rebuild_s
@printf "  speedup (rebuild / mutate-solve): %.1fx\n" (avg_rebuild_all / avg_mut_solve)

exit(all_match ? 0 : 1)
