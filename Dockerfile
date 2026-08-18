# Serves IESA-Opt.jl's HTTP API + UI as the `julia-backend` service in the
# unified-project orchestrator (D:\I-AI\UniversityCode\unified-project).
# Manifest.toml is gitignored in the source repo, but if one is present in the
# build context we copy it (see the optional-glob COPY below) so instantiate
# installs the exact locked versions instead of re-resolving the whole
# dependency graph on every build; without one it falls back to resolution.
# Pinned to 1.12 to match the Julia version this project is actually
# developed/run against locally — julia:1.10's older stdlib caused a
# precompile failure (UndefVarError: StaticData not defined) when Pkg
# freshly resolved current package versions against it.
FROM julia:1.12

WORKDIR /app

# Pkg.instantiate() auto-precompiles by default; disable that so precompilation
# happens only in the two explicit steps below, both of which set
# RESEAU_PRECOMPILE_ONLY (see next). Otherwise instantiate would precompile the
# skipped-below `tls` workload and reintroduce the hang.
ENV JULIA_PKG_PRECOMPILE_AUTO=0

# Reseau (pulled in transitively via HTTP.jl) runs a set of loopback self-tests
# during precompilation. One of them, `tls`, validates a test certificate
# bundled in the package whose validity window ended 2026-08-05 - so on any
# later clock precompile used to abort with "certificate has expired". An
# earlier fix pinned the wall clock back inside that window with libfaketime,
# but faketime also skews the monotonic clock that Reseau's epoll event loop
# uses for its wait deadlines, so its loopback poll loop blocked on epoll_wait
# forever: precompilation hung indefinitely right after Parquet2, with the whole
# HTTP/Reseau/OpenSSL branch never finishing. Reseau exposes
# RESEAU_PRECOMPILE_ONLY to choose which self-tests run; selecting every
# workload EXCEPT `tls` never touches the expired cert, so no faketime is
# needed, the clock stays real, and precompile completes. The TLS code paths
# still compile lazily on first use at runtime, against real certificates and
# with no self-test (this env var gates only the precompile workload, not
# runtime TLS). Set once here so both precompile steps below inherit it.
ENV RESEAU_PRECOMPILE_ONLY=eventloops,internal_poll,socket_ops,tcp,host_resolvers

# --- Dependency layer: keyed only on the project's manifest files -----------
# Copying just Project.toml (+ Manifest.toml if present; the [l] glob makes it
# optional so a checkout without one still builds) means this layer's cache is
# invalidated only when dependencies actually change, not on every source edit.
COPY Project.toml Manifest.tom[l] ./
RUN julia --project=. -e 'using Pkg; Pkg.instantiate()'

# Precompile all *dependencies* (JuMP/Gurobi/DuckDB/XLSX/HTTP/... — the
# multi-minute part) here, before the app source is copied. IESAOpt is itself
# the active project package, so Pkg.precompile() needs *some* src/IESAOpt.jl to
# exist; a trivial stub lets the whole dependency tree compile into
# ~/.julia/compiled. Because this layer depends only on the manifest files
# above, those compiled dependency caches survive any change under src/,
# scripts/, ui/, data/, etc. `timeout` fails the build fast if a dependency ever
# reintroduces a precompile hang, instead of appearing to run forever.
RUN mkdir -p src && printf 'module IESAOpt end\n' > src/IESAOpt.jl \
    && timeout 900 julia --project=. -e 'using Pkg; Pkg.precompile()'

# --- Source layer -----------------------------------------------------------
# The real source (including the true src/IESAOpt.jl, overwriting the stub)
# lands here. This second precompile reuses the cached dependency .ji files from
# the layer above, so it only has to compile IESAOpt itself (plus its own
# @compile_workload, which builds an LP model from data/default_data).
COPY . .
RUN timeout 900 julia --project=. -e 'using Pkg; Pkg.precompile()'

EXPOSE 8001

# --threads=auto: the server's own startup log warns that a single-threaded
# Julia blocks HTTP handling (including progress-poll JSON requests) while a
# solve or data read is running on that same thread, making the UI look like
# it "lost connection" mid-run even though the process is still alive.
CMD ["julia", "--project=.", "--threads=auto", "scripts/serve_ui_docker.jl"]
