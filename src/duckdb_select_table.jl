# =============================================================================
# duckdb_select_table.jl — build a DuckDB table (with PK/FK) from an arbitrary
# SELECT, validating each FK candidate against the real data first.
#
# Extracted from scripts/merge_with_iesa_sim.jl's original `_create_merged_table!`
# (unchanged behavior — see that script's git history) so both it and
# src/data_merge.jl share one implementation instead of two copies.
#
# DuckDB's `CREATE TABLE ... AS SELECT ...` (CTAS) cannot carry PRIMARY
# KEY/FOREIGN KEY at all — same limitation `input_tables.jl` works around for
# the single-model writer. This builds an explicit `CREATE TABLE (columns,
# PK, FK)` + `INSERT INTO ... SELECT` instead. It is agnostic to *how* the
# SELECT combines rows (side-by-side union-with-tag, priority-fill anti-join,
# ...) — that decision belongs to the caller.
# =============================================================================

"""
    _create_table_from_select!(con, name, select_sql; pk, fks)

Create table `name` in `con` from `select_sql` (which must already produce
exactly the target column list, in order) with `pk` (a `Vector{String}` of
column names, or `nothing`) and `fks` (a `Vector` of
`(cols::Vector{String}, ref_table::String, ref_cols::Vector{String})`
candidates). Each FK candidate is checked with an anti-join against
`select_sql` before being declared, and dropped (with a printed reason) if
any non-NULL child value has no match in the parent.
"""
function _create_table_from_select!(con, name::String, select_sql::String;
                                     pk::Union{Nothing,Vector{String}} = nothing,
                                     fks::Vector = Tuple{Vector{String},String,Vector{String}}[])
    schema_df = DBInterface.execute(con, "SELECT * FROM ($(select_sql)) LIMIT 0") |> DataFrames.DataFrame
    colnames = names(schema_df)

    valid_fks = Tuple{Vector{String},String,Vector{String}}[]
    for (cols, ref_table, ref_cols) in fks
        join_cond = join(("c.\"$(a)\" = p.\"$(b)\"" for (a, b) in zip(cols, ref_cols)), " AND ")
        notnull_cond = join(("c.\"$(a)\" IS NOT NULL" for a in cols), " AND ")
        check_sql = """
            SELECT COUNT(*) AS n FROM ($(select_sql)) c
            LEFT JOIN $(ref_table) p ON $(join_cond)
            WHERE $(notnull_cond) AND p."$(ref_cols[1])" IS NULL
        """
        n = (DBInterface.execute(con, check_sql) |> first)[1]
        if n == 0
            push!(valid_fks, (cols, ref_table, ref_cols))
        else
            println("  [$(name)] dropping FK $(cols) -> $(ref_table)$(ref_cols): $(n) orphan value(s)")
        end
    end

    col_list_sql = join(("\"$(c)\"" for c in colnames), ", ")
    constraints = String[]
    pk !== nothing && push!(constraints, "PRIMARY KEY (" * join(("\"$(c)\"" for c in pk), ", ") * ")")
    for (cols, ref_table, ref_cols) in valid_fks
        push!(constraints, "FOREIGN KEY (" * join(("\"$(c)\"" for c in cols), ", ") * ") REFERENCES " *
                            "$(ref_table)(" * join(("\"$(c)\"" for c in ref_cols), ", ") * ")")
    end

    # Column types come from the (already-typed) SELECT itself — describe the
    # zero-row projection to get them without re-deriving each type by hand.
    types_df = DBInterface.execute(con, "DESCRIBE SELECT * FROM ($(select_sql)) LIMIT 0") |> DataFrames.DataFrame
    types = Dict{String,String}(row.column_name => row.column_type for row in eachrow(types_df))
    cols_sql = join(("\"$(c)\" $(types[c])" for c in colnames), ",\n    ")

    body = join(vcat([cols_sql], constraints), ",\n    ")
    DBInterface.execute(con, "CREATE TABLE \"$(name)\" (\n    $(body)\n)")
    DBInterface.execute(con, "INSERT INTO \"$(name)\" SELECT $(col_list_sql) FROM ($(select_sql))")
    return nothing
end
