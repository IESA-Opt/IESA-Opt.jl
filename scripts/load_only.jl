#!/usr/bin/env julia
# Minimal Phase 1 smoke harness.
#
# Usage:
#   julia --project=. scripts/load_only.jl <path-to-WY*.xlsx>
#
# Once Phase 1 is implemented, this will:
#   1. Call read_data(xlsx_path)
#   2. Call derive_sets!(md)
#   3. Call compute_derived_params!(md)
#   4. Print summary stats (set sizes, sample params)
#
# Right now it prints the Phase-0-only summary (empty sets, helper indices).

using IESA_J

function main()
    xlsx_path = isempty(ARGS) ? "" : ARGS[1]

    md = if !isempty(xlsx_path) && isfile(xlsx_path)
        IESA_J.read_data(xlsx_path)
    else
        println("No XLSX argument or file not found; using empty ModelData skeleton.")
        IESA_J.ModelData()
    end

    # Compute the helpers that do work in Phase 0 (temporal indices)
    md.sets.hours_orig = collect(1:8760)
    md.params.hoursPer_day = 24
    IESA_J.derive_sets!(md)
    IESA_J.compute_derived_params!(md)

    println("\n========== IESA-Opt.jl ModelData summary ==========")
    println("Sets:")
    println("  technologies      = ", length(md.sets.technologies))
    println("  activities        = ", length(md.sets.activities))
    println("  nodes             = ", length(md.sets.nodes))
    println("  periods           = ", md.sets.periods)
    println("  hours_orig        = ", length(md.sets.hours_orig))
    println("  hours_inDay       = ", length(md.sets.hours_inDay))
    println("  days              = ", length(md.sets.days))
    println("  weeks             = ", length(md.sets.weeks))
    println()
    println("Helpers (computed):")
    println("  dayPer_hour[1]    = ", get(md.params.dayPer_hour, 1, "n/a"))
    println("  dayPer_hour[8760] = ", get(md.params.dayPer_hour, 8760, "n/a"))
    println("  prev_hour[1]      = ", get(md.params.prev_hour, 1, "n/a"))
    println("  next_hour[8760]   = ", get(md.params.next_hour, 8760, "n/a"))
    println()
    println("Parameters:")
    println("  inv_cost entries          = ", length(md.params.inv_cost))
    println("  hourly_profiles_orig entries = ", length(md.params.hourly_profiles_orig))
    println("====================================================\n")
end

main()
