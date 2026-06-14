# =============================================================================
# scripts/scenario_run_campaign.jl
#
# Phase 3 end-to-end smoke: run a small campaign with `run_campaign`
#
#   * Path A: serial (n_workers = 0) — one model held warm across N variants
#   * Path B: distributed (n_workers = 2) — pool of worker procs, each
#     holding one model warm
#
# Both paths solve the same N variants and report per-variant timings + the
# objective. The two paths must agree on the objective for every variant.
#
# Parameter under test: `emissionTargetBunker[(:NL, 2050)]` (baseline 7.7
# in the default workbook, binding, non-zero so multipliers matter).
#
# Run:  julia --project=. scripts/scenario_run_campaign.jl
# Skip precompile + warmup for faster turnaround:
#   $env:IESA_OPT_SKIP_PRECOMPILE='1'; $env:IESA_OPT_SKIP_WARMUP='1'; julia --project=. scripts/scenario_run_campaign.jl
# =============================================================================

using IESAOpt
using Printf

const NODE        = :NL
const PERIOD      = 2050
const PARAM       = :emissionTargetBunker
const MULTIPLIERS = [0.5, 0.75, 1.0, 1.5]      # 4 variants
const OBJ_TOL_REL = 1e-3

# -----------------------------------------------------------------------------
# Workbook + ModelData prep (TS smoke config, 24 h × 1 rep day)
# -----------------------------------------------------------------------------
workbook = normpath(joinpath(@__DIR__, "..", "data", "default_data.xlsx"))
isfile(workbook) || error("Default workbook not found: $workbook")

println("=== Loading + preparing ModelData ===")
md_base = read_data_cached(workbook)
md_base === nothing && error("read_data_cached returned nothing")
md_base = deepcopy(md_base)

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
    error("$(PARAM)[($(NODE),$(PERIOD))] missing in workbook.")
baseline_cap == 0.0 &&
    error("$(PARAM)[($(NODE),$(PERIOD))] is zero in workbook — sweep would be vacuous.")
@printf "Baseline cap: %s[%s,%d] = %.6f\n" String(PARAM) NODE PERIOD baseline_cap

# -----------------------------------------------------------------------------
# Build per-variant LeafChange lists (one leaf per variant — emissionTargetBunker)
# -----------------------------------------------------------------------------
changes_per_variant = Vector{Vector{LeafChange}}()
for mult in MULTIPLIERS
    cap = baseline_cap * mult
    push!(changes_per_variant,
          LeafChange[LeafChange(PARAM, (NODE, PERIOD), cap)])
end
@printf "Prepared %d variants (multipliers = %s)\n" length(changes_per_variant) string(MULTIPLIERS)

# -----------------------------------------------------------------------------
# Callbacks
# -----------------------------------------------------------------------------
function _print_progress(nt)
    if nt.stage == "start"
        @printf "  [progress] variant %d/%d start\n" nt.variant_id nt.total
    elseif nt.stage == "done"
        term = haskey(nt, :result) ? nt.result.term_status : "?"
        @printf "  [progress] variant %d/%d done  (term=%s)\n" nt.variant_id nt.total term
    end
end

function _print_result(r::VariantResult)
    @printf "  [result] v=%-3d term=%-12s obj=%14s build=%5.2fs apply=%5.2fs solve=%5.2fs err=%s\n" r.variant_id r.term_status (isnan(r.objective) ? "NaN" : @sprintf("%14.6f", r.objective)) r.build_seconds r.apply_seconds r.solve_seconds (r.error === nothing ? "-" : r.error)
end

# -----------------------------------------------------------------------------
# Path A — serial
# -----------------------------------------------------------------------------
println("\n=== Path A — serial (n_workers = 0) ===")
t_serial = @elapsed begin
    results_serial = run_campaign(md_base, changes_per_variant;
        n_workers = 0,
        solver    = :highs,
        mode      = :ts,
        on_progress = _print_progress,
        on_result   = _print_result,
    )
end
@printf "Serial total wall time: %.2f s\n" t_serial

# -----------------------------------------------------------------------------
# Path B — distributed (2 workers)
# -----------------------------------------------------------------------------
println("\n=== Path B — distributed (n_workers = 2) ===")
t_distributed = @elapsed begin
    results_distributed = run_campaign(md_base, changes_per_variant;
        n_workers          = 2,
        threads_per_worker = 1,
        solver             = :highs,
        mode               = :ts,
        on_progress = _print_progress,
        on_result   = _print_result,
    )
end
@printf "Distributed total wall time (incl. addprocs bootstrap + rmprocs): %.2f s\n" t_distributed

# -----------------------------------------------------------------------------
# Comparison
# -----------------------------------------------------------------------------
println("\n=== Per-variant comparison: serial vs distributed ===")
@printf "%-3s | %-15s | %-15s | %-13s | %-12s | %-12s\n" "id" "obj_serial" "obj_distrib" "obj_rel_diff" "term_serial" "term_distrib"
println(repeat('-', 92))

all_match = true
for i in eachindex(results_serial)
    rs = results_serial[i]
    rd = results_distributed[i]
    rel = (isfinite(rs.objective) && isfinite(rd.objective) && abs(rs.objective) > 0) ?
          abs(rs.objective - rd.objective) / abs(rs.objective) : NaN
    @printf "%-3d | %-15.6f | %-15.6f | %-13.2e | %-12s | %-12s\n" rs.variant_id rs.objective rd.objective rel rs.term_status rd.term_status
    if !(isfinite(rel) && rel < OBJ_TOL_REL)
        global all_match = false
    end
end

println()
if all_match
    println("PASS: serial and distributed paths agree on every variant within $(OBJ_TOL_REL) relative tolerance.")
else
    println("FAIL: at least one variant disagreed between serial and distributed paths.")
end

@printf "\nSpeedup (serial / distributed) on %d variants: %.2fx\n" length(MULTIPLIERS) (t_serial / t_distributed)

exit(all_match ? 0 : 1)
