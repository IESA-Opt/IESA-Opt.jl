# Input Database

IESA-Opt.jl reads scenario data from an Excel workbook. The public example workbook is `Input/default_data.xlsx`; study-specific workbooks can be placed under `Input/` and should normally remain outside Git. Scenario variants are configured in the UI or campaign workflow rather than by maintaining a separate workbook folder.

The workbook is more than a collection of tables. It defines the model universe: periods, regions, activities, technologies, policy targets, time profiles, technology-activity balances, infrastructure assets, prices, learning assumptions, feedstocks, and retrofit relations. The Julia reader converts these sheets into `ModelSets` and `ModelParams`, derives secondary sets and parameters, and then passes those structures to the model builder.

## Pages In This Section

- [Workbook Structure](workbook-structure.md): active sheets and editing rules.
- [Sheet-by-Sheet Guide](sheet-by-sheet-guide.md): what each sheet represents and how the Julia reader uses it.
- [Data Flow](data-flow.md): workbook ingestion through sets, derived parameters, model build, and outputs.
- [Derived Parameters](derived-parameters.md): formulas computed after reading the workbook.
- [QA Checklist](qa-checklist.md): checks to run before launching long solves.

## Practical Rule

Rows are scenario data. Columns are part of the workbook interface. Adding rows is usually safe when identifiers remain consistent across sheets; reordering, deleting, or renaming columns can break the reader because `src/data_reading.jl` maps fixed sheet ranges into Julia dictionaries.

Back to the [documentation home](../../index.md) or the [repository README](https://github.com/IESA-Opt/IESA-Opt.jl#readme).