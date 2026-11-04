using Test
using IESAOpt

# One year of synthetic hourly profiles named like the regional (10Nodes)
# workbooks: per-cluster onshore wind / sun and per-zone offshore wind.
function _regional_profile_data(; n_repDays = 8, approach = :kmeans_avg, extremes = true, n_ex = 5)
    md = ModelData()
    p = md.params
    for d in 1:365, hh in 1:24
        h = (d - 1) * 24 + hh
        p.hourly_profilesReadOrig[(h, Symbol("EU Load"))] = (1 + 0.3 * sin(2π * d / 365) + 0.2 * sin(2π * hh / 24)) / 8760
        p.hourly_profilesReadOrig[(h, Symbol("CL1_Wind Onshore NL"))] = clamp(0.4 + 0.35 * sin(2π * d / 17 + hh / 12), 0.0, 1.0)
        p.hourly_profilesReadOrig[(h, Symbol("CL1_Sun NL"))] = max(0.0, sin(π * (hh - 6) / 12)) * (0.5 + 0.4 * sin(2π * (d - 80) / 365))
        p.hourly_profilesReadOrig[(h, Symbol("Wind Offshore NS1"))] = clamp(0.5 + 0.4 * cos(2π * d / 23 + hh / 8), 0.0, 1.0)
    end
    p.n_repDays = n_repDays
    p.hoursPer_day_cluster = 24
    p.clustering_approach = approach
    p.ts_extremePeriods = extremes
    p.ts_extremeDays_count = n_ex
    return md
end

@testset "Extreme periods with regional profile names" begin
    md = _regional_profile_data()
    build_temporal_clusters!(md)
    p = md.params

    @test md.sets.repDays == collect(1:8)
    @test sort(unique(values(p.mapDay_repDay))) == collect(1:8)
    @test sum(values(p.dayWeight)) == 365
    @test sum(values(p.clusterHourWeight)) ≈ 8760
    # 5 extreme days (peak net load, dunkelflaute, VRES surplus, peak demand,
    # max ramp) each get their own rep day; the RES-based criteria need the
    # regional wind/sun profiles to be recognised.
    @test count(==(1.0), values(p.dayWeight)) >= 5
    for yp in unique(yp for ((_, yp), _) in p.hourly_profilesReadOrig)
        annual = sum(p.hourly_profilesReadOrig[(h, yp)] for h in 1:8760)
        clustered = sum(p.clusterHourWeight[hc] * p.hourly_profiles_cluster[(hc, yp)] for hc in md.sets.hours_cluster)
        @test clustered ≈ annual rtol = 1e-9
    end
end

@testset "Seeded k-means gives reproducible rep days" begin
    maps = map(1:2) do _
        md = _regional_profile_data(; n_repDays = 6, approach = :kmeans_shape, extremes = false)
        build_temporal_clusters!(md)
        [md.params.mapDay_repDay[d] for d in 1:365]
    end
    @test maps[1] == maps[2]
end

@testset "RES profile detection for extreme periods" begin
    for name in ("Wind Onshore NL", "Wind Offshore NL", "Sun NL", "CL1_Wind Onshore NL", "CL10_Sun NL", "Wind Offshore NS3")
        @test IESAOpt._is_res_profile(Symbol(name))
    end
    for name in ("EU Load", "Hydro RoR NL", "Flat low night 6 days", "Electric Vehicles - Use")
        @test !IESAOpt._is_res_profile(Symbol(name))
    end
end
