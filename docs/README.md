# IESA-Opt.jl Documentation Source

IESA-Opt.jl documentation is built with Documenter.jl and published at <https://iesa-opt.github.io/IESA-Opt.jl/v0.1/>. This file is a short map for readers browsing the repository on GitHub; the documentation source lives under [src/](src/index.md), and the build script is [make.jl](make.jl).

## Main Pages

- [Welcome](src/index.md)
- [Getting started](src/user-guide/getting-started.md)
- [Input database](src/user-guide/input-database/index.md)
- [Solver settings](src/user-guide/solver-settings.md)
- [Outputs](src/user-guide/outputs.md)
- [Model scope](src/scientific-foundation/model-scope.md)
- [Formulation](src/scientific-foundation/formulation/index.md)
- [Notation](src/scientific-foundation/formulation/notation.md)
- [Scientific references](src/scientific-foundation/references.md)
- [API reference](src/reference/api.md)

Back to the [repository README](../README.md).

## Building Locally

From the repository root:

```powershell
julia --project=docs -e "using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()"
julia --project=docs docs/make.jl
```

The generated site is written to `docs/build/`, which is ignored by Git.

## Where New Documentation Should Go

Add new pages under `docs/src/`:

- `docs/src/user-guide/`: installation, input data, running studies, solver settings, and outputs.
- `docs/src/scientific-foundation/`: model scope, assumptions, formulation notes, and scientific references.
- `docs/src/reference/`: public Julia API documentation and developer-facing reference material.

When the documentation grows, keep the root README concise and expand the Documenter pages instead.