# =============================================================================
# cyclic_closures.jl — FH-only stateCycleAnnual_* constraints
#
# IESA-Opt 1.0 source: lines 4420-4480 (`stateCycleAnnual_dQ_S`, `stateCycleAnnual_dW_S`,
# `stateCycleAnnual_dQ_backlog_DR`, `stateCycleAnnual_dQ_backlog_BE`,
# `stateCycleAnnual_dB_S`).
#
# These constraints state that the year-start storage/reservoir/backlog level
# equals the year-end level (after appropriate decay/flux).  They are
# **LOGICALLY REDUNDANT** with the existing `_add_storage_state!`,
# `_add_reservoir!`, `_add_backlog!`, `_add_gasbuffer!` helpers in
# `model/hourly.jl`, all of which already implement the cyclic recurrence via
# `h_prev = i == 1 ? hours[end] : hours[i - 1]` (or the daily analog for
# `deltaB_S`).
#
# The IESA-Opt 1.0 source itself explicitly notes this redundancy
# (see `IESA-Opt.ams` line 4415-4419):
#
#   ! These constraints are logically REDUNDANT with the existing variable
#   ! Definitions and stateClosure_* constraints (which already enforce cyclic /
#   ! zero closure), but they are requested for symmetry with the TS calendar-day
#   ! cyclic closure ... Presolve will eliminate redundant rows; no impact on
#   ! LP optimum is expected.
#
# Therefore, **adding them in Julia would have no effect on the optimum** —
# they would also be presolved away.  We provide `add_cyclic_closures!` as a
# no-op stub for API symmetry and document the rationale here.  If you ever
# need to add them for byte-exact MPS comparison with IESA-Opt 1.0, uncomment the
# implementations below.
# =============================================================================

"""
    add_cyclic_closures!(m, vars, md)

No-op.  The cyclic closure invariants are already enforced by the FH state
recurrence helpers (`_add_storage_state!`, `_add_reservoir!`, `_add_backlog!`,
`_add_gasbuffer!`).  See file header for full rationale.

Returns `m` for chaining.
"""
function add_cyclic_closures!(m::JuMP.Model, vars::AnnualVars, md::ModelData)
    @info "add_cyclic_closures! — no-op (cyclic invariants enforced by state recurrences)"
    flush(stderr)
    return m
end
