# =============================================================================
# land_use.jl — industrial-cluster land-use limit (project-specific)
#
# Port of the AIMMS constraint `c_ClusterSpace_Limit` (regional "Komar"
# model, IESA_AIMMS_Original_KJ `IESA-Opt.ams`):
#
#     Constraint c_ClusterSpace_Limit {
#         IndexDomain: (icl,ps) | ps='2050' and p_clusterAvailableArea(icl);
#         Definition: sum( t | ep_clusterPer_tech(t) = icl,
#                          p_techSpace(t) * techStock(t, ps) )
#                     <= p_clusterAvailableArea(icl);
#     }
#
#   • `ep_clusterPer_tech(t)` — industrial cluster of a technology, taken from
#     the `CLn_` prefix of its ID (AIMMS `ClusterPrefix`).
#   • `p_techSpace(t)` — land use per unit of capacity [Hectare/UoC], read
#     from Technologies!DS "Space (Ha)"  → `md.params.techSpace`.
#   • `p_clusterAvailableArea(icl)` — area available per cluster [Hectare],
#     read from the Parameters rows `CL1_AvailableArea` .. `CL5_AvailableArea`
#     (B49:B53)  → `md.params.clusterAvailableArea`.
#
# Activation: `:land_use in md.params.extensions`. The UI exposes a
# `Cluster land use` toggle (default OFF). When OFF, no constraint is added.
# Workbooks without the land-use inputs add no constraint either.
# =============================================================================

# AIMMS applies the limit to the 2050 stock only (`ps='2050'`).
const _LU_PERIOD = 2050

# AIMMS `ClusterPrefix(t)`: the part of the tech ID before the first underscore.
_lu_cluster_prefix(t::Symbol) = Symbol(first(split(String(t), '_'; limit = 2)))

# Natural order for cluster names (CL2 before CL10).
_lu_cluster_order(cl::Symbol) = (length(String(cl)), String(cl))

"""
    land_use_clusters(md::ModelData) -> Vector{NamedTuple}

Industrial clusters with a non-zero available area (AIMMS domain
`p_clusterAvailableArea(icl)`), in natural cluster order. Each row is
`(cluster, area, techs, space)`: the cluster's technologies (`CLn_` prefix,
restricted to `md.sets.technologies`) with a non-zero space requirement and
their space per unit of capacity [Hectare/UoC].
"""
function land_use_clusters(md::ModelData)
    p = md.params
    rows = NamedTuple{(:cluster, :area, :techs, :space),
                      Tuple{Symbol,Float64,Vector{Symbol},Vector{Float64}}}[]
    isempty(p.clusterAvailableArea) && return rows

    members = Dict{Symbol,Vector{Symbol}}()
    for t in md.sets.technologies
        iszero(get(p.techSpace, t, 0.0)) && continue
        push!(get!(members, _lu_cluster_prefix(t), Symbol[]), t)
    end

    for cl in sort!(collect(keys(p.clusterAvailableArea)); by = _lu_cluster_order)
        area = p.clusterAvailableArea[cl]
        iszero(area) && continue
        techs = get(members, cl, Symbol[])
        push!(rows, (cluster = cl, area = area, techs = techs,
                     space = Float64[p.techSpace[t] for t in techs]))
    end
    return rows
end

"""
    apply_land_use!(m, vars, md; mode::Symbol=:fh) -> Int

Add one `c_ClusterSpace_Limit[<cluster>,2050]` constraint per industrial
cluster with an available area and at least one space-using technology:

    Σ_{t ∈ cluster} techSpace(t) · techStock(t, 2050) ≤ clusterAvailableArea(cluster)

Nothing is added when 2050 is not among `md.sets.periods_solve`. Returns the
number of constraints added. Mode-agnostic: only the annual `techStock`
variable is used, which exists in every build path.
"""
function apply_land_use!(m::JuMP.Model, vars, md::ModelData; mode::Symbol = :fh)
    _LU_PERIOD in md.sets.periods_solve || return 0
    techStock = vars.techStock
    n_added = 0
    for c in land_use_clusters(md)
        isempty(c.techs) && continue
        @constraint(m, sum(c.space[i] * techStock[c.techs[i], _LU_PERIOD] for i in eachindex(c.techs)) <= c.area,
                    base_name = "c_ClusterSpace_Limit[$(c.cluster),$(_LU_PERIOD)]")
        n_added += 1
    end
    return n_added
end

"""
    land_use_plan(md::ModelData) -> String

One-line, human-readable summary of what `apply_land_use!` adds for `md`
(used in run logs).
"""
function land_use_plan(md::ModelData)
    clusters = [c for c in land_use_clusters(md) if !isempty(c.techs)]
    if isempty(clusters)
        return "Cluster land use: this workbook has no land-use data (Parameters rows CLn_AvailableArea and " *
               "Technologies column DS \"Space (Ha)\"), so no land-use constraint is added"
    elseif !(_LU_PERIOD in md.sets.periods_solve)
        return "Cluster land use: the limit applies to $(_LU_PERIOD) only and $(_LU_PERIOD) is not selected, " *
               "so no land-use constraint is added"
    end
    parts = ["$(c.cluster) <= $(round(c.area; digits = 1)) ha ($(length(c.techs)) techs)" for c in clusters]
    return "Cluster land use: adding $(length(clusters)) constraint(s) for $(_LU_PERIOD): " * join(parts, ", ")
end

"""
    land_use_report(vars, md::ModelData) -> Vector{NamedTuple}

Area occupied [Hectare] per industrial cluster and solved period in the solved
stock (AIMMS reporting parameter `p_clusterSpace_used`), next to the cluster's
available area. Rows are `(cluster, period, used, available)`. Requires primal
values; independent of whether the limit was enabled.
"""
function land_use_report(vars, md::ModelData)
    rows = NamedTuple{(:cluster, :period, :used, :available), Tuple{Symbol,Int,Float64,Float64}}[]
    for c in land_use_clusters(md), ps in md.sets.periods_solve
        used = sum((c.space[i] * JuMP.value(vars.techStock[c.techs[i], ps]) for i in eachindex(c.techs)); init = 0.0)
        push!(rows, (cluster = c.cluster, period = ps, used = used, available = c.area))
    end
    return rows
end
