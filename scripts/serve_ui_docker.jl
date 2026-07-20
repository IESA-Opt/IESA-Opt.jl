using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using IESAOpt

# Container entry point: binds 0.0.0.0 (reachable from outside the container)
# instead of scripts/serve_ui.jl's 127.0.0.1 default, and never tries to open
# a browser. Host/port stay overridable via env vars so the same image can be
# reused if the published port ever needs to change.
host = get(ENV, "IESAOPT_HOST", "0.0.0.0")
port = parse(Int, get(ENV, "IESAOPT_PORT", "8001"))

serve_ui!(; host = host, port = port, open_browser = false)
