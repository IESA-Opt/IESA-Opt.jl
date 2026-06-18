# Contributing

Contributions to IESA-Opt.jl are welcome when they improve the model, documentation, tests, examples, or usability of the public package.

## Development Setup

From the repository root, instantiate the Julia environment and run the tests:

```powershell
julia --project=. -e "using Pkg; Pkg.instantiate()"
julia --project=. test/runtests.jl
```

Use Julia 1.10 or newer. For production-scale solver changes, test with Gurobi when possible. HiGHS is suitable for smoke tests and development checks that do not require a commercial solver license.

## Pull Request Guidelines

- Keep changes focused and explain the modeling or workflow reason for the change.
- Add or update tests when changing model construction, data reading, data writing, solver behavior, or public APIs.
- Update documentation when changing user-facing commands, input expectations, output tables, or solver settings.
- Keep generated outputs, private workbooks, solver logs, and local run scripts out of Git.
- Prefer root-relative paths in documentation and scripts.

## Reporting Issues

When opening an issue, include:

- operating system and Julia version;
- solver and solver version;
- command or script that was run;
- relevant error message or output summary;
- whether the problem occurs with `Input/default_data.xlsx` or only with a private workbook.

Do not attach confidential scenario data to public issues. If a private workbook is needed to reproduce a problem, describe its structure and the failing sheet or field instead.