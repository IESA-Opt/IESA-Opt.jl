# =============================================================================
# ui_maps.jl -- regional-map geometry read from GeoPackages in ui/assets/maps
# =============================================================================
#
# Every *.gpkg in ui/assets/maps is discovered at request time, so new or
# re-shaped clusterings can be dropped in without code changes. Layers are
# recognised by content rather than by name:
#   * clusters  -- polygon layer with a cluster id column (e.g. municipalities)
#   * power     -- point layer with a cluster id column (electricity network)
#   * gas       -- point layer with a cluster id column whose name contains
#                  "gas" (natural gas, hydrogen and CCS networks)
#   * hubs      -- optional point layer without cluster ids whose name contains
#                  "hub" or "north_sea" (offshore / external endpoints)
# The node count of a file is the number of distinct cluster ids.

using SQLite

const UI_MAP_CACHE = Dict{String,Tuple{Tuple{Float64,Int},Any}}()
const UI_MAP_CACHE_LOCK = ReentrantLock()
const _MAP_ID_COLUMNS = ("cluster_id", "clusterid", "cluster", "node_id", "node")

_map_assets_dir() = joinpath(_ui_dir(), "assets", "maps")

function _map_cached(compute::Function, kind::String, path::String)
    st = stat(path)
    stamp = (Float64(st.mtime), Int(st.size))
    key = string(kind, '|', path)
    lock(UI_MAP_CACHE_LOCK) do
        hit = get(UI_MAP_CACHE, key, nothing)
        hit !== nothing && hit[1] == stamp && return hit[2]
    end
    value = compute()
    lock(UI_MAP_CACHE_LOCK) do
        UI_MAP_CACHE[key] = (stamp, value)
    end
    return value
end

_map_rows(db, sql, args...) =
    [NamedTuple{Tuple(propertynames(r))}(Tuple(r[k] for k in propertynames(r)))
     for r in SQLite.DBInterface.execute(db, sql, collect(Any, args))]

function _map_id_column(columns::Vector{String})
    lowered = lowercase.(columns)
    for name in _MAP_ID_COLUMNS
        idx = findfirst(==(name), lowered)
        idx === nothing || return columns[idx]
    end
    return nothing
end

function _map_pick(layers, preferred::Tuple)
    isempty(layers) && return nothing
    for word in preferred
        idx = findfirst(l -> occursin(word, lowercase(l["table"])), layers)
        idx === nothing || return layers[idx]
    end
    return first(layers)
end

function _gpkg_layer_info(db)
    rows = _map_rows(db, """
        SELECT c.table_name AS tbl, g.column_name AS geom, upper(g.geometry_type_name) AS gtype, g.srs_id AS srs
        FROM gpkg_contents c JOIN gpkg_geometry_columns g ON g.table_name = c.table_name
        WHERE c.data_type = 'features'""")
    layers = Dict{String,Any}[]
    for row in rows
        table = String(row.tbl)
        columns = [String(r.name) for r in _map_rows(db, "PRAGMA table_info(\"$(replace(table, "\"" => "\"\""))\")")]
        push!(layers, Dict{String,Any}(
            "table" => table,
            "geom" => String(row.geom),
            "gtype" => String(row.gtype),
            "srs" => Int(row.srs),
            "columns" => columns,
            "id" => _map_id_column(columns),
        ))
    end
    is_polygon(l) = occursin("POLYGON", l["gtype"]) || l["gtype"] == "GEOMETRY"
    is_point(l) = occursin("POINT", l["gtype"])
    polygons = filter(l -> is_polygon(l) && l["id"] !== nothing, layers)
    points = filter(l -> is_point(l) && l["id"] !== nothing, layers)
    gas_points = filter(l -> occursin("gas", lowercase(l["table"])), points)
    power_points = filter(l -> !occursin("gas", lowercase(l["table"])), points)
    hub_points = filter(l -> is_point(l) && l["id"] === nothing &&
                             (occursin("hub", lowercase(l["table"])) || occursin("north_sea", lowercase(l["table"]))), layers)
    return Dict{String,Any}(
        "clusters" => _map_pick(polygons, ("cluster", "region", "municipal")),
        "power" => _map_pick(power_points, ("power", "elec", "lvl1", "centroid")),
        "gas" => _map_pick(gas_points, ("centroid",)),
        "hubs" => _map_pick(hub_points, ("north_sea", "hub")),
    )
end

_map_quote(name::AbstractString) = "\"" * replace(String(name), "\"" => "\"\"") * "\""

function _map_file_summary(path::String)
    return _map_cached("summary", path) do
        try
            db = SQLite.DB(path)
            try
                layers = _gpkg_layer_info(db)
                clusters = layers["clusters"]
                clusters === nothing && error("no polygon layer with a cluster id column")
                layers["power"] === nothing && error("no point layer with cluster ids for the power nodes")
                n = only(_map_rows(db, "SELECT COUNT(DISTINCT $(_map_quote(clusters["id"]))) AS n FROM $(_map_quote(clusters["table"]))")).n
                Dict{String,Any}(
                    "file" => basename(path),
                    "nodes" => Int(n),
                    "modified" => Dates.format(Dates.unix2datetime(mtime(path)), "yyyy-mm-dd HH:MM"),
                    "mtime" => mtime(path),
                    "layers" => Dict(k => (v === nothing ? nothing : v["table"]) for (k, v) in layers),
                )
            finally
                close(db)
            end
        catch err
            Dict{String,Any}("file" => basename(path), "nodes" => 0, "mtime" => mtime(path),
                             "error" => sprint(showerror, err))
        end
    end
end

"""All GeoPackages in `ui/assets/maps`, newest first, with their detected node count."""
function _map_catalog()
    dir = _map_assets_dir()
    isdir(dir) || return Dict{String,Any}[]
    files = [joinpath(dir, f) for f in readdir(dir) if endswith(lowercase(f), ".gpkg") && isfile(joinpath(dir, f))]
    entries = [_map_file_summary(f) for f in files]
    sort!(entries; by = e -> -Float64(e["mtime"]))
    return entries
end

function _map_select_file(catalog, node_level::Int, requested::AbstractString)
    usable = filter(e -> !haskey(e, "error"), catalog)
    matching = filter(e -> e["nodes"] == node_level, usable)
    req = strip(String(requested))
    if !isempty(req)
        hit = findfirst(e -> e["file"] == req, usable)
        # A manual pick is honoured when it fits the run, or when nothing fits.
        hit !== nothing && (isempty(matching) || usable[hit]["nodes"] == node_level) && return usable[hit]
    end
    isempty(matching) || return first(matching)
    return nothing
end

function _map_geometry_path(file::AbstractString)
    name = String(file)
    (isempty(name) || basename(name) != name || !endswith(lowercase(name), ".gpkg")) && error("Invalid map file name: $name")
    path = joinpath(_map_assets_dir(), name)
    isfile(path) || error("Map file not found: $name")
    return path
end

# --- GeoPackage binary geometry ------------------------------------------------

function _wkb_geometry(io::IO, project)
    le = read(io, UInt8) == 0x01
    rd(::Type{T}) where {T} = le ? ltoh(read(io, T)) : ntoh(read(io, T))
    code = rd(UInt32)
    hasz = (code & 0x80000000) != 0
    hasm = (code & 0x40000000) != 0
    (code & 0x20000000) != 0 && rd(UInt32)  # EWKB embedded SRID
    code &= 0x0fffffff
    if code > 1000
        dim = code ÷ 1000
        hasz = dim in (1, 3)
        hasm = dim in (2, 3)
        code %= 1000
    end
    extra = Int(hasz) + Int(hasm)
    point() = begin
        x = rd(Float64); y = rd(Float64)
        for _ in 1:extra
            rd(Float64)
        end
        lon, lat = project(x, y)
        Float64[round(lon; digits = 6), round(lat; digits = 6)]
    end
    line() = [point() for _ in 1:rd(UInt32)]
    if code == 1
        return Dict{String,Any}("type" => "Point", "coordinates" => point())
    elseif code == 2
        return Dict{String,Any}("type" => "LineString", "coordinates" => line())
    elseif code == 3
        return Dict{String,Any}("type" => "Polygon", "coordinates" => [line() for _ in 1:rd(UInt32)])
    elseif code in (4, 5, 6)
        parts = [_wkb_geometry(io, project) for _ in 1:rd(UInt32)]
        kind = code == 4 ? "MultiPoint" : code == 5 ? "MultiLineString" : "MultiPolygon"
        return Dict{String,Any}("type" => kind, "coordinates" => [p["coordinates"] for p in parts])
    elseif code == 7
        return Dict{String,Any}("type" => "GeometryCollection", "geometries" => [_wkb_geometry(io, project) for _ in 1:rd(UInt32)])
    end
    error("Unsupported WKB geometry type $code")
end

function _gpkg_geometry(blob::AbstractVector{UInt8}, project)
    (length(blob) >= 8 && blob[1] == 0x47 && blob[2] == 0x50) || error("Not a GeoPackage geometry blob")
    flags = blob[4]
    (flags & 0x10) != 0 && return nothing          # empty geometry
    (flags & 0x20) != 0 && error("Extended GeoPackage geometries are not supported")
    envelope = (flags >> 1) & 0x07
    offset = 8 + (envelope == 0 ? 0 : envelope == 1 ? 32 : envelope in (2, 3) ? 48 : envelope == 4 ? 64 :
                  error("Invalid GeoPackage envelope indicator $envelope"))
    return _wkb_geometry(IOBuffer(view(blob, offset+1:length(blob))), project)
end

# Dutch RD New (EPSG:28992) -> WGS84, Schreutelkamp & Strang van Hees approximation (~1 m).
function _rd_to_wgs84(x::Float64, y::Float64)
    dx = (x - 155000.0) * 1e-5
    dy = (y - 463000.0) * 1e-5
    n = 3235.65389dy - 32.58297dx^2 - 0.2475dy^2 - 0.84978dx^2*dy - 0.0655dy^3 - 0.01709dx^2*dy^2 -
        0.00738dx + 0.0053dx^4 - 0.00039dx^2*dy^3 + 0.00033dx^4*dy - 0.00012dx*dy
    e = 5260.52916dx + 105.94684dx*dy + 2.45656dx*dy^2 - 0.81885dx^3 + 0.05594dx*dy^3 - 0.05607dx^3*dy +
        0.01199dy - 0.00256dx^3*dy^2 + 0.00128dx*dy^4 + 0.00022dy^2 - 0.00022dx^2 + 0.00026dx^5
    return (5.38720621 + e / 3600.0, 52.15517440 + n / 3600.0)
end

function _map_projection(db, srs_id::Int, table::String)
    rows = _map_rows(db, "SELECT organization, organization_coordsys_id FROM gpkg_spatial_ref_sys WHERE srs_id = ?", srs_id)
    org, code = isempty(rows) ? ("EPSG", srs_id) : (uppercase(string(rows[1].organization)), Int(rows[1].organization_coordsys_id))
    (org == "EPSG" && code in (4326, 4258)) && return (x, y) -> (x, y)
    (org == "EPSG" && code == 28992) && return _rd_to_wgs84
    error("Layer '$table' uses CRS $org:$code; save it as EPSG:4326 (WGS84) or EPSG:28992 (RD New).")
end

function _map_property(value)
    (value === missing || value === nothing) && return nothing
    value isa AbstractVector{UInt8} && return nothing
    return value
end

function _map_layer_features(db, layer::Dict{String,Any})
    table, geom, id_col = layer["table"], layer["geom"], layer["id"]
    project = _map_projection(db, layer["srs"], table)
    features = Dict{String,Any}[]
    skip = Set(lowercase.([geom, "fid"]))
    for row in SQLite.DBInterface.execute(db, "SELECT * FROM $(_map_quote(table))")
        blob = row[Symbol(geom)]
        blob === missing && continue
        geometry = _gpkg_geometry(blob, project)
        geometry === nothing && continue
        props = Dict{String,Any}()
        for name in propertynames(row)
            key = String(name)
            lowercase(key) in skip && continue
            props[key] = _map_property(row[name])
        end
        if id_col !== nothing
            raw = props[id_col]
            id = raw isa Real ? Int(raw) : tryparse(Int, replace(string(something(raw, "")), r"^\s*CL\s*"i => ""))
            id === nothing && continue
            props["cluster_id"] = id
        end
        push!(features, Dict{String,Any}("type" => "Feature", "properties" => props, "geometry" => geometry))
    end
    return Dict{String,Any}("type" => "FeatureCollection", "name" => table, "features" => features)
end

"""GeoJSON (as a JSON string) of the clusters, power/gas node points and optional hubs in a map GeoPackage."""
function _map_geometry_json(file::AbstractString)
    path = _map_geometry_path(file)
    return _map_cached("geometry", path) do
        db = SQLite.DB(path)
        try
            layers = _gpkg_layer_info(db)
            layers["clusters"] === nothing && error("$(basename(path)): no polygon layer with a cluster id column")
            layers["power"] === nothing && error("$(basename(path)): no point layer with cluster ids for the power nodes")
            payload = Dict{String,Any}(
                "file" => basename(path),
                "layers" => Dict(k => (v === nothing ? nothing : v["table"]) for (k, v) in layers),
                "clusters" => _map_layer_features(db, layers["clusters"]),
                "powerCentroids" => _map_layer_features(db, layers["power"]),
                "gasCentroids" => layers["gas"] === nothing ? nothing : _map_layer_features(db, layers["gas"]),
                "hubs" => layers["hubs"] === nothing ? nothing : _map_layer_features(db, layers["hubs"]),
            )
            JSON3.write(_json_sanitize(payload))
        finally
            close(db)
        end
    end
end

function _map_geometry_response(query::Union{Nothing,String})
    params = query === nothing ? Dict{String,String}() : HTTP.queryparams(query)
    body = _map_geometry_json(get(params, "file", ""))
    return HTTP.Response(200, ["Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store"], body)
end

"""Map assets for the regional-map payload: the GeoPackage matching `node_level` (or `requested`)."""
function _regional_map_assets(node_level::Int, requested::AbstractString = "")
    catalog = _map_catalog()
    usable = filter(e -> !haskey(e, "error"), catalog)
    selected = _map_select_file(catalog, node_level, requested)
    matching = filter(e -> e["nodes"] == node_level, usable)
    choices = isempty(matching) ? usable : matching
    hubs_geojson = joinpath(_map_assets_dir(), "north_sea_hubs.geojson")
    available_levels = sort!(unique(Int[e["nodes"] for e in usable]))
    message = if selected !== nothing
        ""
    elseif isempty(usable)
        "No map GeoPackage (*.gpkg) found in ui/assets/maps."
    elseif node_level <= 0
        "Could not determine the node count of this run. Pick a map from the Map list."
    else
        "No map GeoPackage with $(node_level) nodes in ui/assets/maps (available: $(join(available_levels, ", "))). Pick one from the Map list."
    end
    return Dict{String,Any}(
        "nodeLevel" => node_level,
        "available" => selected !== nothing,
        "file" => selected === nothing ? nothing : selected["file"],
        "geometry" => selected === nothing ? nothing :
            "/api/maps/geometry?file=$(HTTP.escapeuri(selected["file"]))&v=$(round(Int, selected["mtime"]))",
        "northSeaHubs" => isfile(hubs_geojson) ? "/assets/maps/north_sea_hubs.geojson" : nothing,
        "options" => [Dict("file" => e["file"], "nodes" => e["nodes"], "modified" => e["modified"],
                           "label" => "$(e["file"]) ($(e["nodes"]) nodes, $(e["modified"]))") for e in choices],
        "availableLevels" => available_levels,
        "invalid" => [Dict("file" => e["file"], "error" => e["error"]) for e in catalog if haskey(e, "error")],
        "message" => message,
    )
end
