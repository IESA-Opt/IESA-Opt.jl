using Documenter
using IESAOpt

DocMeta.setdocmeta!(IESAOpt, :DocTestSetup, :(using IESAOpt); recursive = true)

build_dir = get(ENV, "DOCUMENTER_BUILD_DIR", "build")
clean_build = lowercase(get(ENV, "DOCUMENTER_CLEAN", "true")) != "false"

makedocs(
    modules = [IESAOpt],
    authors = "TNO IESA team",
    sitename = "IESA-Opt.jl",
    build = build_dir,
    clean = clean_build,
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://iesa-opt.github.io/IESA-Opt.jl/",
        edit_link = nothing,
        assets = ["assets/iesa-symbols.css"],
        inventory_version = "0.1",
    ),
    pages = [
        "Home" => "index.md",
        "User Guide" => [
            "Getting Started" => "user-guide/getting-started.md",
            "Input Database" => [
                "Overview" => "user-guide/input-database/index.md",
                "Workbook Structure" => "user-guide/input-database/workbook-structure.md",
                "Sheet-by-Sheet Guide" => "user-guide/input-database/sheet-by-sheet-guide.md",
                "Data Flow" => "user-guide/input-database/data-flow.md",
                "Derived Parameters" => "user-guide/input-database/derived-parameters.md",
                "QA Checklist" => "user-guide/input-database/qa-checklist.md",
            ],
            "Solver Settings" => "user-guide/solver-settings.md",
            "Outputs" => "user-guide/outputs.md",
        ],
        "Scientific Foundation" => [
            "Model Scope" => "scientific-foundation/model-scope.md",
            "Formulation" => [
                "Overview" => "scientific-foundation/formulation/index.md",
                "Notation" => "scientific-foundation/formulation/notation.md",
                "Balances and Policy" => "scientific-foundation/formulation/balances-and-policy.md",
                "Objective and Costs" => "scientific-foundation/formulation/objective-and-costs.md",
                "Capacity and Stock" => "scientific-foundation/formulation/capacity-and-stock.md",
                "Temporal Representation" => "scientific-foundation/formulation/temporal-representation.md",
                "Flexibility Archetypes" => "scientific-foundation/formulation/flexibility-archetypes.md",
            ],
            "References" => "scientific-foundation/references.md",
        ],
        "Reference" => [
            "API Reference" => "reference/api.md",
        ],
    ],
)

deploydocs(
    repo = "github.com/IESA-Opt/IESA-Opt.jl.git",
    devbranch = "main",
    devurl = "v0.1",
    versions = ["0.1" => "v0.1"],
    push_preview = true,
)