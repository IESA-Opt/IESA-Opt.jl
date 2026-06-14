using Test
using IESAOpt
using JuMP
using HiGHS

# =============================================================================
# Phase 2 — In-place LP mutation
#
# Covers:
#   * `Mutation` struct + `apply_mutation!` for :rhs, :coef, :obj on a tiny
#     synthetic JuMP+HiGHS model.
#   * Registry: `register_mutation!`, `is_mutation_registered`,
#     `registered_mutation_fields`, `build_mutations` lookup + replace.
#   * Default registrations populated by `_register_default_mutations!`
#     for emission-cap RHS families.
#   * `LeafChange` constructor + `apply_leaf_change!` for :set and :multiply
#     against ModelParams Dict-typed fields.
#   * `apply_variant!` end-to-end on a tiny synthetic model wired to a
#     minimal `ModelData` — uses `rederive=false` so we don't trip
#     `compute_derived_params!` on an empty fixture.
# =============================================================================

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
"""
    _tiny_model()

Build a tiny LP and return `(model, x_ref, y_ref)`. Constraints:
  myCap : x + y <= 10
  xCap  : x     <=  6
Objective: Max 3x + 2y. Optimal x=6, y=4, obj=26.
"""
function _tiny_model()
    m = Model(HiGHS.Optimizer)
    set_silent(m)
    @variable(m, x >= 0, base_name = "x")
    @variable(m, y >= 0, base_name = "y")
    @constraint(m, x + y <= 10, base_name = "myCap")
    @constraint(m, x <= 6, base_name = "xCap")
    @objective(m, Max, 3x + 2y)
    return m, x, y
end

"""
    _emcap_model()

Tiny model with a constraint named exactly like an IESA `emTargetAir`
constraint, plus one variable to give the constraint a body. Lets us prove
the default mutation builder pushes RHS through unchanged.
"""
function _emcap_model()
    m = Model(HiGHS.Optimizer)
    set_silent(m)
    @variable(m, u >= 0, base_name = "u")
    @constraint(m, u <= 100.0, base_name = "emTargetAir[NL,2050]")
    @objective(m, Max, u)
    return m, u
end

# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------
@testset "scenario/manifest.jl — Mutation + apply_mutation!" begin
    @testset "Mutation struct" begin
        m1 = Mutation(:rhs, "myCap", "", 7.5)
        @test m1.kind == :rhs
        @test m1.constraint_name == "myCap"
        @test m1.var_name == ""
        @test m1.new_value == 7.5

        # kwarg constructor
        m2 = Mutation(; kind = :coef, constraint_name = "c1",
                      var_name = "x", new_value = 3.14)
        @test m2.kind == :coef
        @test m2.constraint_name == "c1"
        @test m2.var_name == "x"
        @test m2.new_value == 3.14
    end

    @testset "apply_mutation! :rhs" begin
        m, x, y = _tiny_model()
        optimize!(m)
        @test termination_status(m) == MOI.OPTIMAL
        @test isapprox(objective_value(m), 26.0; atol = 1e-6)

        # Tighten myCap from 10 to 5 → new optimum x=5, y=0, obj=15
        apply_mutation!(m, Mutation(:rhs, "myCap", "", 5.0))
        optimize!(m)
        @test isapprox(objective_value(m), 15.0; atol = 1e-6)
        @test isapprox(value(x), 5.0; atol = 1e-6)
        @test isapprox(value(y), 0.0; atol = 1e-6)
    end

    @testset "apply_mutation! :coef" begin
        m, x, y = _tiny_model()
        # Make y twice as "heavy" in myCap: x + 2y <= 10
        apply_mutation!(m, Mutation(:coef, "myCap", "y", 2.0))
        optimize!(m)
        # Max 3x + 2y s.t. x ≤ 6, x + 2y ≤ 10
        # Try x=6, 2y ≤ 4 → y=2 → obj = 18+4 = 22
        @test isapprox(objective_value(m), 22.0; atol = 1e-6)
        @test isapprox(value(x), 6.0; atol = 1e-6)
        @test isapprox(value(y), 2.0; atol = 1e-6)
    end

    @testset "apply_mutation! :obj" begin
        m, x, y = _tiny_model()
        # Boost y's objective coefficient from 2 to 5: Max 3x + 5y
        apply_mutation!(m, Mutation(:obj, "", "y", 5.0))
        optimize!(m)
        # x + y ≤ 10, x ≤ 6 → optimum x=0, y=10, obj=50
        @test isapprox(objective_value(m), 50.0; atol = 1e-6)
        @test isapprox(value(x), 0.0; atol = 1e-6)
        @test isapprox(value(y), 10.0; atol = 1e-6)
    end

    @testset "apply_mutation! error paths" begin
        m, _, _ = _tiny_model()
        @test_throws ErrorException apply_mutation!(m,
            Mutation(:rhs, "nosuch", "", 1.0))
        @test_throws ErrorException apply_mutation!(m,
            Mutation(:coef, "myCap", "nosuch", 1.0))
        @test_throws ErrorException apply_mutation!(m,
            Mutation(:obj, "", "nosuch", 1.0))
        @test_throws ErrorException apply_mutation!(m,
            Mutation(:bogus, "myCap", "", 1.0))
    end

    @testset "apply_mutations! batch" begin
        m, _, _ = _tiny_model()
        n = apply_mutations!(m, [
            Mutation(:rhs, "myCap", "", 5.0),
            Mutation(:coef, "myCap", "y", 2.0),
        ])
        @test n == 2
        optimize!(m)
        # x + 2y ≤ 5, x ≤ 6, Max 3x + 2y → x=5, y=0, obj=15
        @test isapprox(objective_value(m), 15.0; atol = 1e-6)
    end
end

@testset "scenario/manifest.jl — registry + default builders" begin
    @testset "default registrations populated" begin
        regs = registered_mutation_fields()
        for f in (:emissionTargetAir, :emissionTargetBunker, :emissionTargetFS,
                  :emissionTargetAll, :emissionTarget_inclScope3andFuelex,
                  :CO2_cumulative_budget, :cumulative_CO2storage)
            @test f in regs
            @test is_mutation_registered(f)
        end
    end

    @testset "build_mutations: node-period RHS" begin
        md = ModelData()
        muts = build_mutations(md, :emissionTargetAir, (:NL, 2050), 7.0)
        @test length(muts) == 1
        @test muts[1].kind == :rhs
        @test muts[1].constraint_name == "emTargetAir[NL,2050]"
        @test muts[1].var_name == ""
        @test muts[1].new_value == 7.0

        muts2 = build_mutations(md, :emissionTargetBunker, (:NL, 2050), 1.5)
        @test muts2[1].constraint_name == "emTargetBunker[NL,2050]"
    end

    @testset "build_mutations: period-only and node-only RHS" begin
        md = ModelData()
        muts_p = build_mutations(md, :emissionTarget_inclScope3andFuelex, (2050,), 9.0)
        @test muts_p[1].constraint_name == "emTargetInclScope3[2050]"

        muts_n = build_mutations(md, :CO2_cumulative_budget, (:NL,), 42.0)
        @test muts_n[1].constraint_name == "emTargetCum[NL]"

        muts_s = build_mutations(md, :cumulative_CO2storage, (:NL,), 100.0)
        @test muts_s[1].constraint_name == "co2StorageCum[NL]"
    end

    @testset "build_mutations error: unregistered field" begin
        md = ModelData()
        @test_throws ArgumentError build_mutations(md, :totally_unknown, (:NL, 2050), 1.0)
    end

    @testset "register_mutation! replace + restore" begin
        # Replace the default for :emissionTargetAir, then restore.
        saved = IESAOpt.MUTATION_REGISTRY[:emissionTargetAir]
        try
            register_mutation!(:emissionTargetAir, (md, idx, v) -> Mutation[
                Mutation(:rhs, "custom[$(idx[1]),$(idx[2])]", "", v)])
            muts = build_mutations(ModelData(), :emissionTargetAir, (:NL, 2050), 3.0)
            @test muts[1].constraint_name == "custom[NL,2050]"
        finally
            register_mutation!(:emissionTargetAir, saved)
        end
        # Confirm restore worked
        muts = build_mutations(ModelData(), :emissionTargetAir, (:NL, 2050), 3.0)
        @test muts[1].constraint_name == "emTargetAir[NL,2050]"
    end

    @testset "default builder bad arity" begin
        md = ModelData()
        # node-period builder expects 2-tuple
        @test_throws ArgumentError build_mutations(md, :emissionTargetAir, (:NL,), 1.0)
        # period-only builder expects 1-tuple
        @test_throws ArgumentError build_mutations(md, :emissionTarget_inclScope3andFuelex,
                                                   (:NL, 2050), 1.0)
        # node-only builder expects 1-tuple
        @test_throws ArgumentError build_mutations(md, :CO2_cumulative_budget,
                                                   (:NL, 2050), 1.0)
    end
end

@testset "scenario/variant.jl — LeafChange + apply_leaf_change!" begin
    @testset "LeafChange constructor + validation" begin
        ch = LeafChange(:emissionTargetAir, (:NL, 2050), 7.0)
        @test ch.field == :emissionTargetAir
        @test ch.indices == (:NL, 2050)
        @test ch.value == 7.0
        @test ch.type == :set

        # bare-scalar indices are wrapped in a 1-tuple
        ch_scalar = LeafChange(:WACC, :OPE01_03, 0.07, :multiply)
        @test ch_scalar.indices == (:OPE01_03,)
        @test ch_scalar.type == :multiply

        # kwarg constructor
        ch_kw = LeafChange(; field = :emissionTargetAir, indices = (:NL, 2050),
                           value = 1.5, type = :multiply)
        @test ch_kw.type == :multiply

        @test_throws ArgumentError LeafChange(:F, (1,), 0.0, :bogus)
    end

    @testset "apply_leaf_change! :set on tuple-keyed dict" begin
        md = ModelData()
        md.params.emissionTargetAir[(:NL, 2050)] = 10.0
        new_val = apply_leaf_change!(md, LeafChange(:emissionTargetAir, (:NL, 2050), 4.5))
        @test new_val == 4.5
        @test md.params.emissionTargetAir[(:NL, 2050)] == 4.5
    end

    @testset "apply_leaf_change! :multiply on existing entry" begin
        md = ModelData()
        md.params.emissionTargetAir[(:NL, 2050)] = 10.0
        new_val = apply_leaf_change!(md,
            LeafChange(:emissionTargetAir, (:NL, 2050), 0.5, :multiply))
        @test new_val == 5.0
        @test md.params.emissionTargetAir[(:NL, 2050)] == 5.0
    end

    @testset "apply_leaf_change! :multiply on missing entry warns + zeroes" begin
        md = ModelData()
        # Entry deliberately missing
        @test_logs (:warn, r"multiply on missing/zero entry") begin
            v = apply_leaf_change!(md,
                LeafChange(:emissionTargetAir, (:NL, 2050), 3.0, :multiply))
            @test v == 0.0
            @test md.params.emissionTargetAir[(:NL, 2050)] == 0.0
        end
    end

    @testset "apply_leaf_change! unknown field" begin
        md = ModelData()
        @test_throws ArgumentError apply_leaf_change!(md,
            LeafChange(:not_a_field, (1,), 1.0))
    end

    @testset "apply_leaf_changes! returns ordered new values" begin
        md = ModelData()
        md.params.emissionTargetAir[(:NL, 2050)] = 10.0
        md.params.emissionTargetBunker[(:NL, 2050)] = 4.0
        vals = apply_leaf_changes!(md, LeafChange[
            LeafChange(:emissionTargetAir,    (:NL, 2050), 8.0),
            LeafChange(:emissionTargetBunker, (:NL, 2050), 0.5, :multiply),
        ])
        @test vals == [8.0, 2.0]
        @test md.params.emissionTargetAir[(:NL, 2050)] == 8.0
        @test md.params.emissionTargetBunker[(:NL, 2050)] == 2.0
    end
end

@testset "scenario/variant.jl — apply_variant! end-to-end" begin
    @testset "RHS push: leaf -> model" begin
        # Build the synthetic model + a minimal ModelData with one entry.
        m, _ = _emcap_model()
        optimize!(m)
        @test isapprox(objective_value(m), 100.0; atol = 1e-6)

        md = ModelData()
        md.params.emissionTargetAir[(:NL, 2050)] = 100.0

        # Tighten the cap to 30 via a LeafChange.
        out = apply_variant!(m, md,
            LeafChange[LeafChange(:emissionTargetAir, (:NL, 2050), 30.0)];
            rederive = false)
        @test out.values == [30.0]
        @test out.n_mutations == 1
        @test md.params.emissionTargetAir[(:NL, 2050)] == 30.0

        optimize!(m)
        @test isapprox(objective_value(m), 30.0; atol = 1e-6)
    end

    @testset "Multiplier path: pre-existing value * multiplier" begin
        m, _ = _emcap_model()
        md = ModelData()
        md.params.emissionTargetAir[(:NL, 2050)] = 100.0
        # Halve the cap via a multiplier (existing 100 × 0.5 = 50).
        out = apply_variant!(m, md,
            LeafChange[LeafChange(:emissionTargetAir, (:NL, 2050), 0.5, :multiply)];
            rederive = false)
        @test out.values == [50.0]
        optimize!(m)
        @test isapprox(objective_value(m), 50.0; atol = 1e-6)
    end
end
