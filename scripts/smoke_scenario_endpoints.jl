# Smoke test for the new scenario-space HTTP endpoints.
# Loads IESAOpt, starts the UI server on a fixed port, posts a small spec
# to /api/scenario/run, polls /api/scenario/status until done, and prints
# the final result.
using IESAOpt
using HTTP
using JSON3

println("Package loaded.")
println("  isdefined :_scenario_run = ", isdefined(IESAOpt, :_scenario_run))
println("  isdefined :_scenario_status = ", isdefined(IESAOpt, :_scenario_status))
println("  isdefined :_scenario_stop! = ", isdefined(IESAOpt, :_scenario_stop!))
println("  isdefined :_scenario_result = ", isdefined(IESAOpt, :_scenario_result))
println("  isdefined :_row_to_leaf_target = ", isdefined(IESAOpt, :_row_to_leaf_target))
println("  isdefined :_parse_indices_cell = ", isdefined(IESAOpt, :_parse_indices_cell))
println("  isdefined :_campaign_session_skeleton = ", isdefined(IESAOpt, :_campaign_session_skeleton))

# Unit tests for the indices parser (no server needed).
println("\n_parse_indices_cell smoke tests:")
for (input, expected) in [
        ("NL",            (:NL,)),
        ("2050",          (2050,)),
        (":NL",           (:NL,)),
        ("(NL, 2050)",    (:NL, 2050)),
        ("(:NL, 2050)",   (:NL, 2050)),
        ("NL,2050",       (:NL, 2050)),
    ]
    got = IESAOpt._parse_indices_cell(input)
    ok = got == expected
    println("  ", ok ? "PASS" : "FAIL", "  '", input, "' -> ", got, ok ? "" : "  (expected $expected)")
end

println("\nAll done.")
