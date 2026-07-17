#=
open_database:
- Julia version: 
- Author: ioana
- Date: 2026-07-06
=#
import Pkg
Pkg.add(["DuckDB", "DataFrames"])
using DuckDB, DBInterface, DataFrames
con = DBInterface.connect(DuckDB.DB, "data/.iesa_cache/default_data.iesa_input.duckdb")

# List tables
tables = DBInterface.execute(con, "SHOW TABLES") |> DataFrame
println(tables)

# For each table, show schema and a sample
for t in tables.name
    println("\n--- $t ---")
    println(DBInterface.execute(con, "DESCRIBE $t") |> DataFrame)
    println(DBInterface.execute(con, "SELECT * FROM $t LIMIT 5") |> DataFrame)
end
