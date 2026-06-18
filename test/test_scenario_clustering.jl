using Test
using IESAOpt

# =============================================================================
# Phase 3.5 — Per-variant clustering registry + partition logic
#
# We unit-test the *pieces* that change in Phase 3.5:
#   * `register_clustering_affecting!` / `unregister_clustering_affecting!` /
#     `is_clustering_affecting` / `clustering_affecting_fields`
#   * `variant_affects_clustering`
#   * `IESAOpt._cluster_cache_key` (sort-stable, value-sensitive)
#   * `IESAOpt._partition_variants_by_cluster_key`
#   * `IESAOpt._split_cluster_changes`
#
# The end-to-end behaviour — running a campaign whose variants partition
# into multiple cluster groups — is exercised by local manual diagnostics on
# real workbook inputs; doing it in unit tests would require monkey-patching
# `build_temporal_clusters!`, which is fragile.
#
# IMPORTANT INVARIANT: the default registry must be EMPTY so the Phase 3
# single-group fast path is preserved bit-for-bit for every existing user.
# =============================================================================

# All test blocks save & restore the global registry to avoid cross-test
# leakage and to guarantee we leave the package in its default-empty state.
_with_clean_registry(f) = begin
    saved = copy(IESAOpt.CLUSTERING_AFFECTING_FIELDS)
    try
        empty!(IESAOpt.CLUSTERING_AFFECTING_FIELDS)
        f()
    finally
        empty!(IESAOpt.CLUSTERING_AFFECTING_FIELDS)
        for s in saved
            push!(IESAOpt.CLUSTERING_AFFECTING_FIELDS, s)
        end
    end
end

@testset "default registry is empty (Phase 3 fast-path preservation)" begin
    @test clustering_affecting_fields() == Symbol[]
    @test !is_clustering_affecting(:hourly_profilesReadOrig)
    @test !is_clustering_affecting(:price_carbon)
end

@testset "register / unregister / is / list" begin
    _with_clean_registry() do
        @test clustering_affecting_fields() == Symbol[]

        register_clustering_affecting!(:hourly_profilesReadOrig)
        @test is_clustering_affecting(:hourly_profilesReadOrig)
        @test clustering_affecting_fields() == [:hourly_profilesReadOrig]

        # Idempotent
        register_clustering_affecting!(:hourly_profilesReadOrig)
        @test clustering_affecting_fields() == [:hourly_profilesReadOrig]

        register_clustering_affecting!(:another_profile)
        @test clustering_affecting_fields() == [:another_profile, :hourly_profilesReadOrig]

        # Unregister returns true if present, false otherwise
        @test unregister_clustering_affecting!(:another_profile) === true
        @test !is_clustering_affecting(:another_profile)
        @test unregister_clustering_affecting!(:another_profile) === false

        @test clustering_affecting_fields() == [:hourly_profilesReadOrig]
    end
end

@testset "variant_affects_clustering" begin
    _with_clean_registry() do
        ch_scalar = [LeafChange(:price_carbon, (:NL, 2050), 80.0),
                     LeafChange(:em_target_air, (:NL, 2050), 30.0)]
        ch_mixed  = vcat(ch_scalar,
                         [LeafChange(:hourly_profilesReadOrig, (:wind_nl, 4711), 0.8)])

        # No tagged fields → false even when the variant clearly touches profile leaves.
        @test !variant_affects_clustering(ch_mixed)

        register_clustering_affecting!(:hourly_profilesReadOrig)
        @test !variant_affects_clustering(ch_scalar)
        @test variant_affects_clustering(ch_mixed)
    end
end

@testset "_cluster_cache_key — empty when nothing tagged" begin
    _with_clean_registry() do
        ch = [LeafChange(:hourly_profilesReadOrig, (:wind_nl, 1), 0.5),
              LeafChange(:price_carbon, (:NL, 2050), 80.0)]
        # Registry empty → fast-path key is ALWAYS () regardless of changes.
        @test IESAOpt._cluster_cache_key(ch) === ()
        @test IESAOpt._cluster_cache_key(LeafChange[]) === ()
    end
end

@testset "_cluster_cache_key — order-invariant, value-sensitive" begin
    _with_clean_registry() do
        register_clustering_affecting!(:hourly_profilesReadOrig)

        a = LeafChange(:hourly_profilesReadOrig, (:wind_nl, 1), 0.5)
        b = LeafChange(:hourly_profilesReadOrig, (:solar_nl, 1), 0.7)
        s = LeafChange(:price_carbon, (:NL, 2050), 80.0)

        k_ab = IESAOpt._cluster_cache_key([a, b, s])
        k_ba = IESAOpt._cluster_cache_key([b, s, a])
        @test k_ab == k_ba          # order of input does not matter
        @test length(k_ab) == 2     # scalar `s` is excluded

        # Different value of the same profile leaf → distinct key.
        a_hi = LeafChange(:hourly_profilesReadOrig, (:wind_nl, 1), 0.9)
        @test IESAOpt._cluster_cache_key([a_hi, b]) != k_ab

        # Different mutation type (:multiply vs :set) → distinct key.
        a_mul = LeafChange(:hourly_profilesReadOrig, (:wind_nl, 1), 0.5, :multiply)
        @test IESAOpt._cluster_cache_key([a_mul, b]) != k_ab

        # Variant with no tagged-leaf changes still hashes to () even when
        # other variants in the same campaign do touch tagged leaves.
        @test IESAOpt._cluster_cache_key([s]) === ()
    end
end

@testset "_partition_variants_by_cluster_key — single group by default" begin
    _with_clean_registry() do
        ch_per_variant = [
            [LeafChange(:hourly_profilesReadOrig, (:wind_nl, 1), 0.5),
             LeafChange(:price_carbon, (:NL, 2050), 80.0)],
            [LeafChange(:hourly_profilesReadOrig, (:wind_nl, 1), 0.9),
             LeafChange(:price_carbon, (:NL, 2050), 90.0)],
            [LeafChange(:price_carbon, (:NL, 2050), 70.0)],
        ]
        ordered, groups = IESAOpt._partition_variants_by_cluster_key(ch_per_variant)
        # Default-empty registry → every variant has key () → one group.
        @test ordered == [()]
        @test groups[()] == [1, 2, 3]
    end
end

@testset "_partition_variants_by_cluster_key — groups by profile sub-state" begin
    _with_clean_registry() do
        register_clustering_affecting!(:hourly_profilesReadOrig)

        ch_per_variant = [
            # variant 1: profile_lo + carbon=80
            [LeafChange(:hourly_profilesReadOrig, (:wind_nl, 1), 0.5),
             LeafChange(:price_carbon, (:NL, 2050), 80.0)],
            # variant 2: profile_hi + carbon=90
            [LeafChange(:hourly_profilesReadOrig, (:wind_nl, 1), 0.9),
             LeafChange(:price_carbon, (:NL, 2050), 90.0)],
            # variant 3: profile_lo (same as v1) + carbon=70  ← shares group with v1
            [LeafChange(:hourly_profilesReadOrig, (:wind_nl, 1), 0.5),
             LeafChange(:price_carbon, (:NL, 2050), 70.0)],
            # variant 4: NO profile touch + carbon=60  ← lands in the () group
            [LeafChange(:price_carbon, (:NL, 2050), 60.0)],
        ]
        ordered, groups = IESAOpt._partition_variants_by_cluster_key(ch_per_variant)
        @test length(ordered) == 3                          # lo, hi, ()
        @test length(groups[ordered[1]]) == 2 && groups[ordered[1]] == [1, 3]
        @test length(groups[ordered[2]]) == 1 && groups[ordered[2]] == [2]
        @test length(groups[ordered[3]]) == 1 && groups[ordered[3]] == [4]
        @test ordered[3] === ()                             # untouched group is empty tuple
    end
end

@testset "_split_cluster_changes — order preserved within subsets" begin
    _with_clean_registry() do
        # No registration → empty cluster subset, full scalar subset.
        ch = [LeafChange(:hourly_profilesReadOrig, (:wind_nl, 1), 0.5),
              LeafChange(:price_carbon, (:NL, 2050), 80.0)]
        cluster, scalar = IESAOpt._split_cluster_changes(ch)
        @test isempty(cluster)
        @test scalar == ch          # default fast-path: everything is scalar

        register_clustering_affecting!(:hourly_profilesReadOrig)
        cluster, scalar = IESAOpt._split_cluster_changes(ch)
        @test length(cluster) == 1 && cluster[1].field === :hourly_profilesReadOrig
        @test length(scalar)  == 1 && scalar[1].field  === :price_carbon
        # Original order preserved within each subset.
        ch_long = [
            LeafChange(:price_carbon, (:NL, 2050), 70.0),
            LeafChange(:hourly_profilesReadOrig, (:wind_nl, 1), 0.5),
            LeafChange(:em_target_air, (:NL, 2050), 30.0),
            LeafChange(:hourly_profilesReadOrig, (:solar_nl, 1), 0.7),
        ]
        cluster2, scalar2 = IESAOpt._split_cluster_changes(ch_long)
        @test [c.field for c in cluster2] ==
              [:hourly_profilesReadOrig, :hourly_profilesReadOrig]
        @test [c.field for c in scalar2] == [:price_carbon, :em_target_air]
    end
end
