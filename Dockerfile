# Serves IESA-Opt.jl's HTTP API + UI as the `julia-backend` service in the
# unified-project orchestrator (D:\I-AI\UniversityCode\unified-project).
# Manifest.toml is gitignored (not tracked) — Pkg.instantiate() does a fresh
# dependency resolution on every build, same as any new local checkout today.
# Pinned to 1.12 to match the Julia version this project is actually
# developed/run against locally — julia:1.10's older stdlib caused a
# precompile failure (UndefVarError: StaticData not defined) when Pkg
# freshly resolved current package versions against it.
FROM julia:1.12

WORKDIR /app

COPY Project.toml ./
RUN julia --project=. -e 'using Pkg; Pkg.instantiate()'

COPY . .
RUN julia --project=. -e 'using Pkg; Pkg.precompile()'

EXPOSE 8001

CMD ["julia", "--project=.", "scripts/serve_ui_docker.jl"]
