# Probe of the experimental SynchToolkit discrete backend (discrete_backend = :synchtoolkit).
# Run in an environment with BaseModelica (this branch), SynchToolkit, OrdinaryDiffEq.
# Output from SynchToolkit 0.4.8 / SynchJulia 0.2.3 is in synchtoolkit_probe.log.
using BaseModelica, SynchToolkit, OrdinaryDiffEq, ModelingToolkit
const T = joinpath(pkgdir(BaseModelica), "test", "testfiles")
for (f, var, tend) in (("DiscreteCounter", :n, 1.0), ("WhenElsewhen", :a, 1.0), ("BouncingBallCounter", :bounces, 3.0))
    println("==== $f"); flush(stdout)
    try
        sys = parse_basemodelica(joinpath(T, f*".bmo"); discrete_backend = :synchtoolkit)
        sol = solve(ODEProblem(sys, [], (0.0, tend)), Tsit5())
        println(sol.retcode, " occ ", var, ": ", SynchToolkit.variable_occurrence_times(sys, sol, getproperty(sys, var)))
        f == "WhenElsewhen" && println(" occ b: ", SynchToolkit.variable_occurrence_times(sys, sol, sys.b))
        if f == "DiscreteCounter"
            println(" y at saved: ", [(round(t, digits=3), round(y, digits=3)) for (t, y) in zip(sol.t, sol[sys.y])][1:3:end])
        elseif f == "BouncingBallCounter"
            h = sol[sys.h]; v = sol[sys.v]
            println(" min h=", minimum(h), " flips=", count(i -> v[i] < 0 && v[i+1] > 0, 1:length(v)-1))
        end
    catch e
        showerror(stdout, e); println()
        Base.show_backtrace(stdout, catch_backtrace()[1:min(end, 12)]); println()
    end
    flush(stdout)
end
