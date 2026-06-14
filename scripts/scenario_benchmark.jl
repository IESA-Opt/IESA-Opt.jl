# =============================================================================
# scripts/scenario_benchmark.jl
#
# DIAGNOSTIC SCRIPT (Phase 5 polish — temporary; remove once distributed-
# scaling validation is finished). Sweeps worker counts on the SAME scenario
# spec and prints a wall-clock + speedup table so we can characterise where
# the distributed runner breaks even on a beefier machine.
#
# Background:
#   * On the development laptop (~14 cores, modest RAM), N=4 + Gurobi
#     BarrierCrossover @ 10 rep days gave:
#       Serial  = 48.7s
#       Distrib = 63.6s (2 workers) -> 0.77x
#     Diagnosis: ~13.6s addprocs+using bootstrap + per-worker first-solve
#     JIT tax. Distributed is expected to win at N >= ~10 with 2 workers
#     and to scale further to 4-8 workers.
#
# What this script does:
#   1. Loads default_data.xlsx and prepares ModelData ONCE.
#   2. Generates a single deterministic set of N variants (CO2 price *
#      bunker multiplier, LHS-sampled, seed=42).
#   3. For each worker-count in WORKER_COUNTS:
#        a. Optionally drops the first per-worker solve from the timing.
#        b. Runs `run_campaign(...)` end-to-end.
#        c. Records wall time, sum(build_s), sum(solve_s), sum(apply_s),
#           cold-build count, per-worker variant assignment.
#   4. Prints a comparison table at the end (markdown-formatted).
#   5. Writes a CSV with the raw measurements next to the script for later
#      analysis on the slower machine.
#
# Configuration knobs (top of file):
#   * WORKER_COUNTS — which N_WORKERS values to sweep (0 = serial path)
#   * N_VARIANTS    — campaign size (same across all worker counts)
#   * N_REPDAYS     — TS rep days (higher = longer per-solve cost)
#   * SOLVER        — :gurobi (license required) or :highs
#   * SOLVER_ATTRS  — passed through; defaults to BarrierCrossover for Gurobi
#
# Output CSV columns: n_workers, n_variants, n_repdays, solver, wall_seconds,
#   cold_builds, sum_build_s, sum_apply_s, sum_solve_s, speedup_vs_serial,
#   variants_per_worker (json).
#
# Run:
#   julia --project=. scripts/scenario_benchmark.jl
# Faster dev iteration (skip precompile + UI warmup, doesn't change results):
#   $env:IESA_OPT_SKIP_PRECOMPILE='1'; $env:IESA_OPT_SKIP_WARMUP='1'; julia --project=. scripts/scenario_benchmark.jl
# =============================================================================

using IESAOpt
using Printf
using Random
using CSV
using DataFrames
using JSON3

# -----------------------------------------------------------------------------
# Configuration — edit these to suit your machine
# -----------------------------------------------------------------------------
const WORKER_COUNTS = [0, 2, 4]      # 0 = serial; add 8, 16 on a big PC
const N_VARIANTS    = 12             # large enough that 4 workers can divide
const N_REPDAYS     = 10
const PERIOD        = 2050
const SOLVER        = :gurobi        # change to :highs if no Gurobi license
const THREADS_PER_WORKER = 1
const SEED          = 42
const SOLVER_ATTRS = SOLVER === :gurobi ?
    Dict{String,Any}("Method" => 2, "Crossover" => -1) :   # Barrier + auto crossover
    Dict{String,Any}()                                       # HiGHS defaults

const OUTPUT_CSV = normpath(joinpath(@__DIR__, "..", "Output",
                                      "scenario_benchmark.csv"))

# -----------------------------------------------------------------------------
# 1. Workbook + ModelData prep (done once, reused across worker-count runs)
# -----------------------------------------------------------------------------
workbook = normpath(joinpath(@__DIR__, "..", "data", "default_data.xlsx"))
isfile(workbook) || error("Default workbook not found: $workbook")

println("=== Loading + preparing ModelData ===")
md_base = read_data_cached(workbook)
md_base = deepcopy(md_base)
md_base.sets.periods_solve = [PERIOD]
md_base.params.hoursPer_day = 24
md_base.params.n_repDays = N_REPDAYS
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

# -----------------------------------------------------------------------------
# 2. Deterministic LHS over two leaves (CO2 price + bunker multiplier)
# -----------------------------------------------------------------------------
const NODE     = :NL
const BASE_CO2 = get(md_base.params.price_co2, (NODE,), 90.0)
const BASE_BNK = get(md_base.params.emissionTargetBunker, (NODE, PERIOD), 7.7)
BASE_BNK == 0.0 && error("emissionTargetBunker[($NODE,$PERIOD)] is zero")

rng = MersenneTwister(SEED)
co2_samples = sort!(BASE_CO2 .+ (rand(rng, N_VARIANTS) .- 0.5) .* BASE_CO2)
mult_samples = 0.5 .+ rand(rng, N_VARIANTS) .* 1.0   # 0.5..1.5

changes_per_variant = Vector{Vector{LeafChange}}()
for i in 1:N_VARIANTS
    push!(changes_per_variant, LeafChange[
        LeafChange(:price_co2, (NODE,), co2_samples[i]),
        LeafChange(:emissionTargetBunker, (NODE, PERIOD), BASE_BNK * mult_samples[i]),
    ])
end
@printf "\nBaselines: price_co2[%s]=%.2f, emissionTargetBunker[%s,%d]=%.4f\n" NODE BASE_CO2 NODE PERIOD BASE_BNK
@printf "Prepared %d variants. Sweeping worker counts: %s\n\n" N_VARIANTS string(WORKER_COUNTS)

# -----------------------------------------------------------------------------
# 3. Sweep worker counts
# -----------------------------------------------------------------------------
struct BenchRow
    n_workers::Int
    wall_seconds::Float64
    cold_builds::Int
    sum_build_s::Float64
    sum_apply_s::Float64
    sum_solve_s::Float64
    variants_per_worker::Dict{Int,Vector{Int}}
end

rows = BenchRow[]

for n_w in WORKER_COUNTS
    @printf "\n=== n_workers = %d ===\n" n_w
    t_wall = @elapsed begin
        results = run_campaign(md_base, changes_per_variant;
            n_workers          = n_w,
            threads_per_worker = THREADS_PER_WORKER,
            solver             = SOLVER,
            solver_attrs       = SOLVER_ATTRS,
            mode               = :ts,
        )
    end
    cold = count(r -> r.build_seconds > 0, results)
    sum_b = sum(r.build_seconds for r in results)
    sum_a = sum(r.apply_seconds for r in results)
    sum_s = sum(r.solve_seconds for r in results)
    assign = Dict{Int,Vector{Int}}()
    for r in results
        push!(get!(assign, r.worker_pid, Int[]), r.variant_id)
    end
    push!(rows, BenchRow(n_w, t_wall, cold, sum_b, sum_a, sum_s, assign))

    @printf "  wall=%.2fs cold_builds=%d sum_build=%.2fs sum_apply=%.2fs sum_solve=%.2fs\n" t_wall cold sum_b sum_a sum_s
    for (pid, vids) in sort(collect(assign); by = first)
        @printf "    pid=%d handled %d variant(s): %s\n" pid length(vids) string(sort(vids))
    end
end

# -----------------------------------------------------------------------------
# 4. Markdown comparison table
# -----------------------------------------------------------------------------
baseline = rows[1].wall_seconds  # use whichever was first (typically serial)
println("\n=== Summary table (markdown) ===\n")
println("| n_workers | wall (s) | speedup | cold_builds | Σbuild (s) | Σsolve (s) | Σapply (s) |")
println("|----------:|---------:|--------:|------------:|-----------:|-----------:|-----------:|")
for r in rows
    speedup = baseline / r.wall_seconds
    @printf "| %9d | %8.2f | %7.2fx | %11d | %10.2f | %10.2f | %10.2f |\n" r.n_workers r.wall_seconds speedup r.cold_builds r.sum_build_s r.sum_solve_s r.sum_apply_s
end

# -----------------------------------------------------------------------------
# 5. Persist raw measurements to CSV for later analysis
# -----------------------------------------------------------------------------
mkpath(dirname(OUTPUT_CSV))
df = DataFrame(
    n_workers           = [r.n_workers for r in rows],
    n_variants          = fill(N_VARIANTS, length(rows)),
    n_repdays           = fill(N_REPDAYS, length(rows)),
    solver              = fill(String(SOLVER), length(rows)),
    wall_seconds        = [r.wall_seconds for r in rows],
    cold_builds         = [r.cold_builds for r in rows],
    sum_build_s         = [r.sum_build_s for r in rows],
    sum_apply_s         = [r.sum_apply_s for r in rows],
    sum_solve_s         = [r.sum_solve_s for r in rows],
    speedup_vs_baseline = [baseline / r.wall_seconds for r in rows],
    variants_per_worker = [JSON3.write(Dict(string(k) => v for (k, v) in r.variants_per_worker))
                           for r in rows],
)
CSV.write(OUTPUT_CSV, df)
@printf "\nRaw measurements written to: %s\n" OUTPUT_CSV
println("(commit the CSV alongside HANDOFF.md so we can compare across machines.)")
