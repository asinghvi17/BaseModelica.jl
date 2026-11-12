using Test
using BaseModelica
using ModelingToolkit
using OrdinaryDiffEq

BM = BaseModelica

testfile(name) = joinpath(dirname(dirname(pathof(BM))), "test", "testfiles", name * ".bmo")

function write_model(body)
    path = tempname() * ".bmo"
    write(
        path, """//! base 0.1.0
        package 'M'
          model 'M'
        $body
          end 'M';
        end 'M';
        """
    )
    return path
end

@testset "When-equations and events" begin
    @testset "Bouncing ball: reinit bounces ($parser)" for parser in (:julia, :antlr)
        prob = create_odeproblem(testfile("BouncingBall"); parser, discrete_backend = :mtk)
        sys = prob.f.sys
        @test length(ModelingToolkit.continuous_events(sys)) == 1
        sol = solve(prob, Tsit5())
        @test sol.retcode == ReturnCode.Success
        h = sol[sys.h]
        v = sol[sys.v]
        # The ball never falls through the floor ...
        @test minimum(h) > -1.0e-6
        # ... and its velocity flips from downwards to upwards at every bounce
        @test count(i -> v[i] < 0 && v[i + 1] > 0, 1:(length(v) - 1)) >= 3
        # First impact at t1 = sqrt(2 h0 / g); the rebound speed is e * g * t1
        t1 = sqrt(2 * 1.0 / 9.81)
        @test sol(t1 + 1.0e-3; idxs = sys.v) ≈ 0.8 * 9.81 * t1 - 9.81e-3 atol = 1.0e-3
        @test sol(t1 + 1.0e-3; idxs = sys.h) > 0
    end

    @testset "Discrete assignment with pre ($parser)" for parser in (:julia, :antlr)
        prob = create_odeproblem(testfile("DiscreteCounter"); parser, discrete_backend = :mtk)
        sys = prob.f.sys
        sol = solve(prob, Tsit5())
        @test sol.retcode == ReturnCode.Success
        n = sol.ps[sys.n]
        @test first(n) == 0.0
        @test last(n) == 1.0
        # The update of n must not disturb the continuous state x, which is coupled to
        # n through the algebraic equation y = 2x + n
        @test sol(1.0; idxs = sys.x) ≈ 1.0 atol = 1.0e-8
        @test sol(1.0; idxs = sys.y) ≈ 3.0 atol = 1.0e-8
        @test sol(0.25; idxs = sys.y) ≈ 0.5 atol = 1.0e-8
    end

    @testset "elsewhen branches ($parser)" for parser in (:julia, :antlr)
        package = parser == :julia ? BM.parse_file_julia(testfile("WhenElsewhen")) :
            BM.parse_file_antlr(testfile("WhenElsewhen"))
        when_eq = only(
            filter(!isnothing, BM.as_when_equation.(package.model.long_class_specifier.composition.equations))
        )
        @test length(when_eq.whens) == 2
        @test length(when_eq.thens) == 2

        prob = create_odeproblem(testfile("WhenElsewhen"); parser, discrete_backend = :mtk)
        sys = prob.f.sys
        sol = solve(prob, Tsit5())
        @test sol.retcode == ReturnCode.Success
        @test last(sol.ps[sys.a]) == 1.0
        @test last(sol.ps[sys.b]) == 2.0
    end

    @testset "Discrete start value from initial equation" begin
        path = write_model(
            """
                Real 'x'(fixed = true, start = 0.0);
                discrete Real 'd';
              initial equation
                pre('d') = 5.0;
              equation
                der('x') = 1.0;
                when 'x' > 0.5 then
                  'd' = pre('d') + 1.0;
                end when;
            """
        )
        sys = parse_basemodelica(path; discrete_backend = :mtk)
        sol = solve(ODEProblem(sys, [], (0.0, 1.0)), Tsit5())
        @test first(sol.ps[sys.d]) == 5.0
        @test last(sol.ps[sys.d]) == 6.0
    end

    @testset "Discrete start value from initial algorithm ($parser)" for parser in (:julia, :antlr)
        path = write_model(
            """
                Real 'x'(fixed = true, start = 0.0);
                discrete Real 'd';
                discrete Real 'e';
              equation
                der('x') = 1.0;
                when 'x' > 0.5 then
                  'd' = pre('d') + 1.0;
                  'e' = pre('e') * 2.0;
                end when;
              initial algorithm
                'd' := integer((time + 2.5) / 1.0);
                'e' := 'd' + 1.0;
            """
        )
        sys = parse_basemodelica(path; parser, discrete_backend = :mtk)
        sol = solve(ODEProblem(sys, [], (0.0, 1.0)), Tsit5())
        @test first(sol.ps[sys.d]) == 2.0
        @test first(sol.ps[sys.e]) == 3.0
        @test last(sol.ps[sys.d]) == 3.0
        @test last(sol.ps[sys.e]) == 6.0
    end

    @testset "Unsupported constructs throw" begin
        reinit_outside = write_model(
            """
                Real 'x'(fixed = true, start = 1.0);
              equation
                der('x') = -'x';
                reinit('x', 0.0);
            """
        )
        @test_throws BM.UnsupportedFeatureError parse_basemodelica(reinit_outside)

        compound_condition = write_model(
            """
                Real 'x'(fixed = true, start = 0.0);
                discrete Real 'd';
              equation
                der('x') = 1.0;
                when 'x' > 0.5 and 'x' < 2.0 then
                  'd' = 1.0;
                end when;
            """
        )
        @test_throws BM.UnsupportedFeatureError parse_basemodelica(compound_condition; discrete_backend = :mtk)

        unknown_function = write_model(
            """
                Real 'x'(fixed = true, start = 0.0);
              equation
                der('x') = 'notAFunction'('x');
            """
        )
        @test_throws BM.UnsupportedFeatureError parse_basemodelica(unknown_function)
    end

    @testset "Unsimplified systems and experiment metadata" begin
        raw = parse_basemodelica(testfile("BouncingBall"); simplify = false)
        @test raw isa System
        @test !ModelingToolkit.iscomplete(raw)
        @test experiment_settings(raw) == (StartTime = 0.0, StopTime = 3.0, Tolerance = 1.0e-6, Interval = 0.01)

        compiled = mtkcompile(raw)
        @test experiment_settings(compiled) == experiment_settings(raw)
        sol = solve(ODEProblem(compiled, [], (0.0, 3.0)), Tsit5())
        @test minimum(sol[compiled.h]) > -1.0e-6

        custom = parse_basemodelica(testfile("BouncingBall"); simplify = mtkcompile)
        @test ModelingToolkit.iscomplete(custom)
        @test isnothing(experiment_settings(parse_basemodelica(testfile("NewtonCoolingBase"))))

        @test_throws ArgumentError create_odeproblem(testfile("BouncingBall"); simplify = false)
        @test_throws ArgumentError parse_basemodelica(testfile("BouncingBall"); discrete_backend = :bogus)
    end
end
