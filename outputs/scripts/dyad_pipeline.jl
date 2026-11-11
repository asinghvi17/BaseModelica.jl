# End-to-end: Base Modelica (.bmo, e.g. emitted by rumoca) -> BaseModelica.jl -> unsimplified
# ModelingToolkit System -> DyadInterface.simplify_model -> ODEProblem -> OrdinaryDiffEq,
# plus DyadInterface.TransientAnalysis on the same unsimplified System.
#
# Run from an environment that has BaseModelica (this branch), DyadInterface and
# OrdinaryDiffEq; add SynchToolkit to exercise the SynchToolkit discrete backend:
#   julia --project=<env> outputs/scripts/dyad_pipeline.jl
using BaseModelica
using DyadInterface
using ModelingToolkit
using OrdinaryDiffEq

const SYNCH = Base.find_package("SynchToolkit") !== nothing
SYNCH && @eval using SynchToolkit

testfile(name) = joinpath(pkgdir(BaseModelica), "test", "testfiles", name * ".bmo")

function report_bounce(label, sys, sol)
    h = sol[sys.h]
    v = sol[sys.v]
    flips = count(i -> v[i] < 0 && v[i + 1] > 0, 1:(length(v) - 1))
    println(rpad(label, 46), "retcode=", sol.retcode, "  min(h)=", minimum(h), "  bounces=", flips)
    return nothing
end

backends = SYNCH ? (:mtk, :synchtoolkit) : (:mtk,)
for backend in backends
    # 1. Unsimplified System from the .bmo file, experiment settings carried as metadata
    model = parse_basemodelica(testfile("BouncingBall"); simplify = false, discrete_backend = backend)
    settings = experiment_settings(model)
    println("[$backend] unsimplified System: ", length(equations(model)), " equations, ",
        length(ModelingToolkit.continuous_events(model)), " continuous event(s); experiment ", settings)

    # 2. Dyad's simplification instead of a direct mtkcompile
    sys = DyadInterface.simplify_model(model)
    prob = ODEProblem(sys, [], (settings.StartTime, settings.StopTime))
    sol = solve(prob, Tsit5(); reltol = settings.Tolerance, saveat = settings.Interval)
    report_bounce("[$backend] simplify_model + solve", sys, sol)

    # 3. The same through create_odeproblem with simplify = DyadInterface.simplify_model
    prob2 = create_odeproblem(testfile("BouncingBall"); simplify = DyadInterface.simplify_model,
        discrete_backend = backend)
    report_bounce("[$backend] create_odeproblem(simplify_model)", prob2.f.sys, solve(prob2, Tsit5()))

    # 4. DyadInterface.TransientAnalysis on the unsimplified System
    result = TransientAnalysis(; model, stop = settings.StopTime, abstol = 1.0e-8, reltol = 1.0e-8)
    raw = DyadInterface.artifacts(result, :RawSolution)
    report_bounce("[$backend] TransientAnalysis", DyadInterface.artifacts(result, :SimplifiedSystem), raw)
end

# Discrete variable updated in a when-clause (`n = pre(n) + 1`) through the Dyad path
for backend in backends
    model = parse_basemodelica(testfile("DiscreteCounter"); simplify = false, discrete_backend = backend)
    sys = DyadInterface.simplify_model(model)
    sol = solve(ODEProblem(sys, [], (0.0, 1.0)), Tsit5())
    println(rpad("[$backend] DiscreteCounter", 46), "retcode=", sol.retcode,
        "  y(0.25)=", sol(0.25; idxs = sys.y), " (expect 0.5)  y(1)=", sol(1.0; idxs = sys.y), " (expect 3)")
end
