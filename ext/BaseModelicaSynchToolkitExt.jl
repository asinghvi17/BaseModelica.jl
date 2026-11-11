# Lowers Base Modelica discrete variables and `when` equations to synchronous (clocked)
# partitions compiled by SynchToolkit.jl:
#
#   when cond then v = expr; end when   →  ZeroCrossing(cond) / EventClock,  v(k) ~ expr
#   when sample(start, dt) then ...     →  Clock(dt; phase = start),         v(k) ~ expr
#   pre(v)                              →  v(k - 1)  (start value via v(k - 1) ~ start)
#   discrete v read in continuous eqs   →  Hold(v)
#   continuous x read in a clocked eq   →  Sample()(x)
#   reinit(x, expr)                     →  Impulsive()(x) ~ expr on the clause's clock
#
# A clause containing only `reinit`s has no clocked variables, so it is lowered with the
# MTK events backend (a plain SymbolicContinuousCallback that is not linked to a clock).
#
# Experimental: selected only with `discrete_backend = :synchtoolkit`. Checked against
# SynchToolkit 0.4.8 (the version installable when this was written): counters on an event
# clock tick at the right times and values, but `Hold(v)` reports the post-tick value before
# the first tick, constant assignments (`v = 1.0`) record NaN, and `Impulsive` on an event
# clock fails inside SynchToolkit (`UndefVarError: typ`). Re-check with SynchToolkit 0.5.
module BaseModelicaSynchToolkitExt

using BaseModelica: BaseModelica, DiscreteBackend, LoweredEvents, MTKEventsBackend,
    WhenClause, CLOCK_CONTEXT, eval_AST, group_by_crossing, is_continuous_variable,
    is_discrete_variable, symbol_name, unsupported, variable_map, with_eval_mode
import BaseModelica: clocked_pre, clocked_reference, compile_system, declare_discrete,
    discrete_reference, lower_when_clauses, synchtoolkit_backend
using ModelingToolkit: ModelingToolkit, @variables, Equation, Hold, Sample, ShiftIndex,
    mtkcompile, t_nounits as t
using SciMLBase: SciMLBase
using SynchToolkit: SynchToolkit

"""
    SynchToolkitBackend()

Discrete backend that compiles discrete variables and `when` equations with SynchToolkit.jl.
Selected by `discrete_backend = :synchtoolkit`, or by `:auto` when SynchToolkit is loaded.
"""
struct SynchToolkitBackend <: DiscreteBackend
    # names of discrete variables read from continuous equations (through `Hold`)
    held::Set{Symbol}
end
SynchToolkitBackend() = SynchToolkitBackend(Set{Symbol}())

synchtoolkit_backend() = SynchToolkitBackend()

declare_discrete(::SynchToolkitBackend, name::Symbol) = only(@variables($name(t)))

function discrete_reference(backend::SynchToolkitBackend, sym)
    push!(backend.held, symbol_name(sym))
    return Hold(sym)
end

# CLOCK_CONTEXT holds `(clock, shift_index)` of the clause being lowered. Samples name the
# clock explicitly: a partition holding only `Impulsive(x) ~ f(Sample(x))` has no other
# link to the event clock.
clocked_reference(::SynchToolkitBackend, sym) =
    is_continuous_variable(sym) ? Sample(CLOCK_CONTEXT[][1])(sym) : sym

function clocked_pre(::SynchToolkitBackend, sym)
    is_discrete_variable(sym) && return sym(CLOCK_CONTEXT[][2] - 1)
    # pre of a continuous variable is its left limit: the value sampled at the tick
    return is_continuous_variable(sym) ? Sample(CLOCK_CONTEXT[][1])(sym) : sym
end

compile_system(::SynchToolkitBackend, sys) =
    mtkcompile(sys; additional_passes = [SynchToolkit.compile_lustre])

function lower_when_clauses(
        backend::SynchToolkitBackend, clauses, states, discrete_starts
    )
    starts = Dict(discrete_starts)
    reinit_only = filter(c -> isempty(c.assignments), clauses)
    clocked = filter(c -> !isempty(c.assignments), clauses)

    # Reinit-only clauses: plain MTK events, not linked to a clock
    lowered = lower_when_clauses(MTKEventsBackend(), reinit_only, states, Pair[])

    groups = Tuple{Any, Vector{WhenClause}}[]
    crossings, grouped = group_by_crossing(filter(c -> isnothing(c.sample), clocked))
    for (crossing, group) in zip(crossings, grouped)
        # Rising edge only: the clock ticks when the condition becomes true
        evt = ModelingToolkit.ZeroCrossing(crossing; up = true, down = false)
        push!(lowered.continuous_events, evt)
        push!(groups, (SciMLBase.Clocks.EventClock(evt), group))
    end
    for clause in filter(c -> !isnothing(c.sample), clocked)
        start, interval = clause.sample
        push!(groups, (SciMLBase.Clock(interval; phase = start), [clause]))
    end

    assigned = Dict{Symbol, Any}()   # discrete variable name => its ShiftIndex
    for (clock, group) in groups
        k = ShiftIndex(clock)
        CLOCK_CONTEXT[] = (clock, k)
        try
            with_eval_mode(:clocked) do
                for clause in group
                    for (var, rhs) in clause.assignments
                        is_discrete_variable(var) ||
                            unsupported("assignment to `$(symbol_name(var))` in a when-equation; only discrete variables can be assigned")
                        name = symbol_name(var)
                        haskey(assigned, name) &&
                            unsupported("discrete variable `$name` is assigned in more than one when-clause")
                        assigned[name] = k
                        push!(lowered.equations, var(k) ~ eval_AST(rhs))
                    end
                    for (state, rhs) in clause.reinits
                        push!(lowered.equations, SynchToolkit.Impulsive()(state) ~ eval_AST(rhs))
                    end
                end
            end
        finally
            CLOCK_CONTEXT[] = nothing
        end
    end

    for name in BaseModelica.discrete_variable_names
        var = variable_map[name]
        haskey(assigned, name) ||
            unsupported("discrete variable `$name` is never assigned in a when-equation")
        start = starts[var]
        push!(lowered.initialization_eqs, var(assigned[name] - 1) ~ start)
        # Value seen by continuous equations before the first tick
        name in backend.held && push!(lowered.initial_conditions, Hold(var) => start)
    end
    return lowered
end

end
