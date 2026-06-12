#!/usr/bin/env julia
# Single-solve harness, mirroring the IESA-Opt run workflow.
#
# Usage (planned):
#   julia --project=. scripts/run_single.jl \
#       --xlsx data/default_data.xlsx \
#       --periods 2022,2025,2030,2035,2040,2045,2050 \
#       --mode ts \
#       --rep_days 20 \
#       --solver gurobi \
#       --out_dir Output/run_$(date +%Y%m%d_%H%M%S)
#
# This script is a placeholder for the command-line single-run interface.

println("scripts/run_single.jl is a placeholder; use scripts/run_ts_timing.jl for current time-slice runs.")
exit(0)
