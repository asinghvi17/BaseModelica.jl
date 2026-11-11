# Lowering of Modelica `when` equations (discrete assignments and `reinit`) to
# ModelingToolkit. A `when` equation is first collected into a backend-independent
# `WhenClause`; a `DiscreteBackend` then turns the clauses into MTK equations and events.
#
# Two backends exist:
# - `MTKEventsBackend` (built in): discrete variables are `@discretes` updated by the
#   affect of a `SymbolicContinuousCallback` (zero crossings) or a periodic
#   `SymbolicDiscreteCallback` (`sample`).
# - `SynchToolkitBackend` (package extension, loaded with SynchToolkit.jl): discrete
#   variables are clocked variables on an `EventClock`/`Clock` compiled by SynchToolkit.

"""
    UnsupportedFeatureError(msg)

Thrown when a BaseModelica model uses a construct that cannot be converted to
ModelingToolkit yet. Conversion stops instead of producing a model that silently
omits or changes behaviour.
"""
struct UnsupportedFeatureError <: Exception
    msg::String
end

function Base.showerror(io::IO, e::UnsupportedFeatureError)
    return print(io, "UnsupportedFeatureError: ", e.msg)
end

unsupported(msg) = throw(UnsupportedFeatureError(msg))

# ── Evaluation modes ──────────────────────────────────────────────────────────
# The meaning of a variable reference and of `pre(x)` depends on where it appears:
#   :normal    continuous equations; discrete variables go through
#              `discrete_reference` (e.g. `Hold` for clocked variables)
#   :raw       plain symbols, no rewriting (used for the argument of `pre`)
#   :condition when-conditions; `pre(x)` is the current value of `x`
#   :affect    MTK callback affects; continuous variables read their pre-event value
#   :clocked   clocked (SynchToolkit) equations; see `clocked_reference`/`clocked_pre`
const EVAL_MODE = Ref(:normal)
const CURRENT_BACKEND = Ref{Any}(nothing)
# Backend-specific data for the clause being lowered (e.g. the `ShiftIndex`).
const CLOCK_CONTEXT = Ref{Any}(nothing)

function with_eval_mode(f, mode::Symbol)
    old = EVAL_MODE[]
    EVAL_MODE[] = mode
    try
        return f()
    finally
        EVAL_MODE[] = old
    end
end

is_discrete_variable(sym) = symbol_name(sym) in discrete_variable_names

# A continuous (non-parameter, time-dependent) variable such as `x(t)`.
function is_continuous_variable(sym)
    sym isa Num || return false
    inner = Symbolics.unwrap(sym)
    SymbolicUtils.iscall(inner) || return false
    ModelingToolkitBase.isparameter(inner) && return false
    return !is_discrete_variable(sym) && !(symbol_name(sym) in bool_comparison_names)
end

function symbol_name(sym)
    sym isa Num || return nothing
    inner = Symbolics.unwrap(sym)
    SymbolicUtils.iscall(inner) || SymbolicUtils.issym(inner) || return nothing
    return try
        SymbolicIndexingInterface.getname(inner)
    catch
        nothing
    end
end

# Rewrite a resolved variable reference according to the current evaluation mode.
function apply_reference_mode(sym)
    mode = EVAL_MODE[]
    if mode === :normal
        is_discrete_variable(sym) && return discrete_reference(CURRENT_BACKEND[], sym)
    elseif mode === :affect
        is_continuous_variable(sym) && return ModelingToolkit.Pre(sym)
    elseif mode === :clocked
        return clocked_reference(CURRENT_BACKEND[], sym)
    end
    return sym
end

# `pre(x)` evaluated in the current mode; `arg` is the plain symbol for `x`.
function apply_pre(arg)
    mode = EVAL_MODE[]
    if mode === :condition
        return arg
    elseif mode === :clocked
        return clocked_pre(CURRENT_BACKEND[], arg)
    elseif mode === :normal && is_discrete_variable(arg)
        # Outside of events pre(x) equals x (they differ only at event instants)
        return discrete_reference(CURRENT_BACKEND[], arg)
    end
    return ModelingToolkit.Pre(arg)
end

# ── When-clause IR ────────────────────────────────────────────────────────────

"""
One branch (`when` or `elsewhen`) of a `when` equation.

- `condition`: the condition AST.
- `sample`: `nothing`, or `(start, interval)` when the condition is `sample(start, interval)`.
- `assignments`: `(variable, rhs_ast)` for each `v = expr` in the body.
- `reinits`: `(state, rhs_ast)` for each `reinit(x, expr)` in the body.
"""
struct WhenClause
    condition::Any
    sample::Union{Nothing, Tuple{Float64, Float64}}
    assignments::Vector{Tuple{Any, Any}}
    reinits::Vector{Tuple{Any, Any}}
end

function function_call_name(call)
    func_name = call.func_name
    if func_name isa BaseModelicaIdentifier
        return func_name.name
    elseif func_name isa BaseModelicaComponentReference
        return join((r.name for r in func_name.ref_list), ".")
    end
    return ""
end

# The when-equation inside an equation list entry, or nothing.
# Julia parser: BaseModelicaAnyEquation(BaseModelicaSimpleEquation(lhs = BaseModelicaWhenEquation))
# ANTLR parser: bare BaseModelicaWhenEquation
function as_when_equation(eq)
    eq isa BaseModelicaWhenEquation && return eq
    if eq isa BaseModelicaAnyEquation && eq.equation isa BaseModelicaSimpleEquation &&
            eq.equation.lhs isa BaseModelicaWhenEquation
        return eq.equation.lhs
    end
    return nothing
end

body_list(body) = isa(body, AbstractArray) ? body : [body]

function inner_equation(eq)
    inner = eq isa BaseModelicaAnyEquation ? eq.equation : eq
    # The Julia parser wraps structured equations in a BaseModelicaSimpleEquation lhs
    if inner isa BaseModelicaSimpleEquation && isnothing(inner.rhs) &&
            inner.lhs isa Union{BaseModelicaIfEquation, BaseModelicaForEquation, BaseModelicaWhenEquation}
        return inner.lhs
    end
    return inner
end

function resolve_variable(ref::BaseModelicaComponentReference)
    name = Symbol(ref.ref_list[1].name)
    haskey(variable_map, name) || unsupported("unknown variable `$name` in when-equation")
    return variable_map[name]
end

function when_clauses(when_eq::BaseModelicaWhenEquation)
    length(when_eq.whens) == length(when_eq.thens) ||
        error("Malformed when-equation: $(length(when_eq.whens)) conditions but $(length(when_eq.thens)) bodies")
    clauses = WhenClause[]
    for (condition, body) in zip(when_eq.whens, when_eq.thens)
        assignments = Tuple{Any, Any}[]
        reinits = Tuple{Any, Any}[]
        for eq in body_list(body)
            inner = inner_equation(eq)
            if inner isa BaseModelicaSimpleEquation && inner.lhs isa BaseModelicaComponentReference &&
                    !isnothing(inner.rhs)
                push!(assignments, (resolve_variable(inner.lhs), inner.rhs))
            elseif inner isa BaseModelicaSimpleEquation && inner.lhs isa BaseModelicaFunctionCall &&
                    isnothing(inner.rhs)
                fname = function_call_name(inner.lhs)
                args = inner.lhs.args.args
                if fname == "reinit"
                    length(args) == 2 && args[1] isa BaseModelicaComponentReference ||
                        unsupported("reinit expects `reinit(state, expression)`")
                    state = resolve_variable(args[1])
                    is_continuous_variable(state) ||
                        unsupported("reinit target `$(symbol_name(state))` is not a continuous state")
                    push!(reinits, (state, args[2]))
                elseif fname == "assert"
                    continue
                else
                    unsupported("`$fname(...)` inside a when-equation is not supported")
                end
            elseif inner isa BaseModelicaSimpleEquation && inner.lhs isa AbstractVector
                unsupported("tuple assignments inside a when-equation are not supported")
            else
                unsupported("$(nameof(typeof(inner))) inside a when-equation is not supported")
            end
        end
        push!(clauses, WhenClause(condition, sample_args(condition), assignments, reinits))
    end
    return clauses
end

function sample_args(condition)
    condition isa BaseModelicaFunctionCall && function_call_name(condition) == "sample" ||
        return nothing
    args = condition.args.args
    length(args) == 2 || unsupported("sample() expects `sample(start, interval)`")
    return (Float64(eval_AST(args[1])), Float64(eval_AST(args[2])))
end

"""
    to_zero_crossing(cond)

Convert a symbolic Boolean condition into an expression that crosses zero upwards when the
condition becomes true.
"""
function to_zero_crossing(cond)
    inner = Symbolics.unwrap(cond)
    if !SymbolicUtils.iscall(inner)
        return cond - 0.5
    end
    op = SymbolicUtils.operation(inner)
    args = SymbolicUtils.arguments(inner)
    if op === (>=) || op === (>)
        return args[1] - args[2]
    elseif op === (<=) || op === (<)
        return args[2] - args[1]
    elseif op === (==)
        return args[1] - args[2]
    elseif op in (&, |, !, ~, ifelse)
        unsupported("compound when-condition `$cond`; only a single relation or Boolean variable is supported")
    else
        # Bare Boolean variable applied to time (e.g. u(t)): `when u` means rising edge
        return cond - 0.5
    end
end

when_crossing(clause::WhenClause) =
    to_zero_crossing(with_eval_mode(() -> eval_AST(clause.condition), :condition))

# Variables appearing under a time derivative in `eqs`: the continuous states.
function differentiated_variables(eqs)
    found = []
    function walk(x)
        x = Symbolics.unwrap(x)
        SymbolicUtils.iscall(x) || return
        if SymbolicUtils.operation(x) isa Symbolics.Differential
            arg = only(SymbolicUtils.arguments(x))
            any(isequal(arg), found) || push!(found, arg)
            return
        end
        foreach(walk, SymbolicUtils.arguments(x))
    end
    for eq in eqs
        walk(eq.lhs)
        walk(eq.rhs)
    end
    return found
end

# ── Backend interface ─────────────────────────────────────────────────────────

"""
Strategy for lowering discrete variables and `when` equations. See `MTKEventsBackend`.
"""
abstract type DiscreteBackend end

"""
    LoweredEvents

Result of `lower_when_clauses`: equations, events and initial conditions to add to the
`System`.
"""
Base.@kwdef struct LoweredEvents
    equations::Vector{Equation} = Equation[]
    continuous_events::Vector{Any} = Any[]
    discrete_events::Vector{Any} = Any[]
    initial_conditions::Vector{Pair} = Pair[]
    initialization_eqs::Vector{Equation} = Equation[]
end

# Symbol for a discrete variable called `name`.
function declare_discrete end
# Reference to discrete variable `sym` from a continuous equation.
function discrete_reference end
# Lower the when-clauses; `states` are the continuous states of the model.
function lower_when_clauses end
# Turn the assembled System into a simplified one.
function compile_system end
# Variable reference / `pre` inside clocked equations (SynchToolkit backend only).
function clocked_reference end
function clocked_pre end

"""
    MTKEventsBackend()

Lower `when` equations to ModelingToolkit symbolic events. Discrete variables are
`@discretes`; each `when` condition becomes a `SymbolicContinuousCallback` that fires on
the rising edge, `sample(start, interval)` becomes a periodic `SymbolicDiscreteCallback`.
Assignments and `reinit` become affect equations in which continuous variables read their
pre-event value (`Pre`).
"""
struct MTKEventsBackend <: DiscreteBackend end

declare_discrete(::MTKEventsBackend, name::Symbol) = only(@discretes($name(t)))
discrete_reference(::MTKEventsBackend, sym) = sym
compile_system(::MTKEventsBackend, sys) = mtkcompile(sys)

function lower_when_clauses(backend::MTKEventsBackend, clauses, states, discrete_starts)
    lowered = LoweredEvents()
    for (sym, start) in discrete_starts
        push!(lowered.initial_conditions, sym => start)
    end
    crossings, grouped = group_by_crossing(filter(c -> isnothing(c.sample), clauses))
    for clause in filter(c -> !isnothing(c.sample), clauses)
        clause.sample[1] == 0 ||
            unsupported("sample(start, interval) with start ≠ 0 needs discrete_backend = :synchtoolkit")
        affects, discretes = mtk_affect(backend, [clause], states)
        push!(
            lowered.discrete_events, ModelingToolkitBase.SymbolicDiscreteCallback(
                clause.sample[2], affects; discrete_parameters = discretes
            )
        )
    end
    for (crossing, group) in zip(crossings, grouped)
        affects, discretes = mtk_affect(backend, group, states)
        # `affect_neg = nothing`: fire only when the condition becomes true (rising edge).
        push!(
            lowered.continuous_events, ModelingToolkitBase.SymbolicContinuousCallback(
                Equation[crossing ~ 0], affects;
                affect_neg = nothing, discrete_parameters = discretes
            )
        )
    end
    return lowered
end

"""
    group_by_crossing(clauses)

Group zero-crossing clauses by their crossing function. Returns `(crossings, groups)`.
Clauses with the same crossing must share one event: separate callbacks with identical
roots do not all fire at the same instant.
"""
function group_by_crossing(clauses)
    crossings = Any[]
    grouped = Vector{Vector{WhenClause}}()
    for clause in clauses
        crossing = when_crossing(clause)
        idx = findfirst(c -> isequal(c, crossing), crossings)
        if isnothing(idx)
            push!(crossings, crossing)
            push!(grouped, [clause])
        else
            push!(grouped[idx], clause)
        end
    end
    return crossings, grouped
end

"""
    mtk_affect(backend, clauses, states)

Affect equations for `clauses`, which fire together. Returns `(affects, discrete_parameters)`.

Continuous variables are read through `Pre`, matching Modelica: inside an event they keep
their pre-event value, and `reinit` takes effect only after the event. Every state not
reinitialized is held with `x ~ Pre(x)`; MTK solves the affect together with the observed
equations of the model, and without these equations states that are not assigned are
treated as free unknowns of that system.
"""
function mtk_affect(::MTKEventsBackend, clauses, states)
    affects = Equation[]
    discretes = []
    reinit_targets = []
    with_eval_mode(:affect) do
        for clause in clauses
            for (var, rhs) in clause.assignments
                is_discrete_variable(var) ||
                    unsupported("assignment to `$(symbol_name(var))` in a when-equation; only discrete variables can be assigned")
                push!(affects, var ~ eval_AST(rhs))
                push!(discretes, var)
            end
            for (state, rhs) in clause.reinits
                any(isequal(state), reinit_targets) &&
                    unsupported("`$(symbol_name(state))` is reinitialized twice in the same event")
                push!(affects, state ~ eval_AST(rhs))
                push!(reinit_targets, state)
            end
        end
    end
    for state in states
        any(isequal(state), reinit_targets) || push!(affects, state ~ ModelingToolkit.Pre(state))
    end
    return affects, discretes
end

# ── Backend selection ─────────────────────────────────────────────────────────

"""
    synchtoolkit_backend()

Return the SynchToolkit discrete backend. The method is defined by the
`BaseModelicaSynchToolkitExt` extension, so it exists only when SynchToolkit.jl is loaded.
"""
function synchtoolkit_backend end

# `:auto` currently always selects the MTK backend: the SynchToolkit backend is opt-in while
# it has known gaps (see the extension). Loading SynchToolkit never changes results on its own.
function select_backend(backend)
    backend isa DiscreteBackend && return backend
    has_synch = applicable(synchtoolkit_backend)
    if backend === :auto
        return MTKEventsBackend()
    elseif backend === :mtk
        return MTKEventsBackend()
    elseif backend === :synchtoolkit
        has_synch ||
            error("discrete_backend = :synchtoolkit requires SynchToolkit.jl to be loaded (`using SynchToolkit`)")
        return synchtoolkit_backend()
    end
    return error("Unknown discrete_backend $(repr(backend)). Use :auto, :mtk or :synchtoolkit")
end
