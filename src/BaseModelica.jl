module BaseModelica

import CondaPkg
using DiffEqBase: BrownFullBasicInit
using MLStyle: @data, @match
import ModelingToolkit
using ModelingToolkitBase: @discretes, @named, @parameters, System, equations, mtkcompile
import ModelingToolkitBase
using ParserCombinator:
    @E_str, @e_str, @p_str, @with_names, Debug, Delayed, Drop, Lookahead, NoCache, Not, Plus,
    Space, Star, make, once
import ParserCombinator
using PrecompileTools: @compile_workload, @setup_workload
const set_name = ParserCombinator.set_name
using PythonCall: Py, pyconvert, pydict, pyexec, pyhasattr, pyimport, pylen
using SciMLBase: ODEProblem
import SymbolicIndexingInterface
using SymbolicUtils: substitute
import SymbolicUtils
using Symbolics: @variables, Equation, Num
import Symbolics

include("ast.jl")
include("julia_parser.jl")
include("antlr_parser.jl")
include("events.jl")
include("evaluator.jl")
include("parameters.jl")
include("functions.jl")

"""
    parse_basemodelica(filename::AbstractString; parser::Symbol = :antlr,
                       discrete_backend = :auto, simplify = true)

Parse a BaseModelica source file into a ModelingToolkit system.

## Arguments
- `filename::AbstractString`: Path to a BaseModelica source file.

## Keyword Arguments
- `parser::Symbol = :antlr`: Parsing backend. `:antlr` uses the bundled ANTLR grammar;
  `:julia` uses the ParserCombinator implementation.
- `discrete_backend = :auto`: How discrete variables and `when` equations are lowered: the
  name of a registered backend, or an [`AbstractDiscreteBackend`](@ref) instance. `:mtk`
  (built in) uses ModelingToolkit symbolic events (`@discretes` updated by callback
  affects). Other packages register further backends with
  [`register_discrete_backend!`](@ref); for example `:synchtoolkit` (clocked variables
  compiled by SynchToolkit.jl) is available after `using SynchToolkit`. `:auto` selects the
  registered backend that opted in to automatic selection, and `:mtk` if none did.
- `simplify = true`: `true` returns the system compiled by the backend's
  [`compile_system`](@ref) (`mtkcompile`, plus any compiler passes the backend needs).
  `false` returns the unsimplified system, for example to pass to
  `DyadInterface.simplify_model`. A function `f` returns `f(system)`.

## Returns
- A `ModelingToolkitBase.System` representing the equations, variables, parameters,
  and events in `filename`.

## Errors
- Throws an error when `parser` is neither `:antlr` nor `:julia`, or when the selected parser
  cannot parse `filename`.
- Throws an `ArgumentError` when no backend is registered under `discrete_backend`.

## Examples

```julia
using BaseModelica

filename = joinpath(pkgdir(BaseModelica), "test", "testfiles", "NewtonCoolingBase.bmo")
system = parse_basemodelica(filename)
@assert !isnothing(system)
```
"""
function parse_basemodelica(
        filename::AbstractString; parser::Symbol = :antlr, discrete_backend = :auto,
        simplify = true
    )
    package = parse_package(filename, parser)
    return baseModelica_to_ModelingToolkit(package; discrete_backend, simplify)
end

function parse_package(filename::AbstractString, parser::Symbol)
    filename = String(filename)
    if parser == :antlr
        return parse_file_antlr(filename)
    elseif parser == :julia
        return parse_file_julia(filename)
    end
    return error("Unknown parser: $parser. Use :julia or :antlr")
end

"""
    parse_experiment_annotation(annotation::Union{BaseModelicaAnnotation, Nothing})

Extract simulation settings from a parsed BaseModelica experiment annotation.

This is a developer-level API for code that already owns a BaseModelica AST. It does not parse
BaseModelica text and the AST representation is not a supported extension interface for ordinary
package users. Use [`create_odeproblem`](@ref) to apply experiment settings while importing a
model.

## Arguments
- `annotation::Union{BaseModelicaAnnotation, Nothing}`: A parsed AST annotation. Pass `nothing`
  when the imported model has no annotation.

## Returns
- `nothing` when no experiment annotation is present or the annotation has no experiment block.
- A named tuple with `StartTime`, `StopTime`, `Tolerance`, and `Interval` otherwise. Missing
  fields use the Modelica defaults `0.0`, `1.0`, and `1e-4`; `Interval` remains `nothing` when
  unspecified.

## Examples

```julia
using BaseModelica

parse_experiment_annotation(nothing)
# output
nothing
```
"""
function parse_experiment_annotation(annotation::Union{BaseModelicaAnnotation, Nothing})
    if isnothing(annotation)
        return nothing
    end

    annotation_content = annotation.annotation_content

    # Default values
    start_time = 0.0
    stop_time = 1.0
    tolerance = 1.0e-4
    interval = nothing

    # Both parsers now produce BaseModelicaModification structure
    if annotation_content isa BaseModelicaModification
        # annotation_content is the class_modification which contains the experiment(...) structure

        # The class_modifications should contain a single arg for "experiment"
        # which itself has nested class_modifications for the parameters
        if !isnothing(annotation_content.class_modifications) && !isempty(annotation_content.class_modifications)
            # Find the "experiment" argument
            experiment_arg = nothing
            for arg in annotation_content.class_modifications
                if arg isa BaseModelicaClassModificationArg && arg.name.name == "experiment"
                    experiment_arg = arg
                    break
                end
            end

            if !isnothing(experiment_arg) && !isnothing(experiment_arg.modification)
                # The experiment's modification contains the parameters

                exp_mod = experiment_arg.modification
                if !isnothing(exp_mod.class_modifications) && !isempty(exp_mod.class_modifications)
                    for param_arg in exp_mod.class_modifications
                        if param_arg isa BaseModelicaClassModificationArg
                            param_name = param_arg.name.name

                            # Extract value from the parameter's modification
                            if !isnothing(param_arg.modification) && !isnothing(param_arg.modification.expr) && !isempty(param_arg.modification.expr)
                                value_expr = param_arg.modification.expr[end]
                                if value_expr isa BaseModelicaNumber
                                    value = value_expr.val

                                    if param_name == "StartTime"
                                        start_time = value
                                    elseif param_name == "StopTime"
                                        stop_time = value
                                    elseif param_name == "Tolerance"
                                        tolerance = value
                                    elseif param_name == "Interval"
                                        interval = value
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    else
        return nothing
    end

    return (StartTime = start_time, StopTime = stop_time, Tolerance = tolerance, Interval = interval)
end

"""
    ExperimentAnnotation

Metadata key under which the settings of a model's `annotation(experiment(...))` are stored
on the system returned by [`parse_basemodelica`](@ref). Read them with
[`experiment_settings`](@ref).
"""
struct ExperimentAnnotation end

"""
    experiment_settings(sys)

Return the experiment annotation settings of a system created by [`parse_basemodelica`](@ref)
as a named tuple `(StartTime, StopTime, Tolerance, Interval)` (see
[`parse_experiment_annotation`](@ref)), or `nothing` if the model has no experiment
annotation. Available on both simplified and unsimplified systems.

## Examples

```julia
using BaseModelica

filename = joinpath(pkgdir(BaseModelica), "test", "testfiles", "Experiment.bmo")
experiment_settings(parse_basemodelica(filename; simplify = false)).StopTime
# output
2.0
```
"""
experiment_settings(sys) = SymbolicUtils.getmetadata(sys, ExperimentAnnotation, nothing)

"""
    create_odeproblem(filename::AbstractString; parser::Symbol = :antlr, u0 = [],
                      discrete_backend = :auto, simplify = true, kwargs...)

Parse a BaseModelica source file and create an ODE problem with experiment settings.

If the model has an `annotation(experiment(...))` block, its `StartTime` and `StopTime` become
the problem time span, `Tolerance` becomes `reltol`, and `Interval` becomes `saveat`. Explicit
keyword arguments override those annotation-derived defaults.

## Arguments
- `filename::AbstractString`: Path to a BaseModelica source file.
- `u0`: Initial conditions forwarded to `SciMLBase.ODEProblem`.

## Keyword Arguments
- `parser::Symbol = :antlr`: Parsing backend, either `:antlr` or `:julia`.
- `discrete_backend = :auto`: See [`parse_basemodelica`](@ref).
- `simplify = true`: How the system is simplified before building the problem: `true` for
  the default `mtkcompile`, or a function such as `DyadInterface.simplify_model`.
- `kwargs...`: Keyword arguments forwarded to `SciMLBase.ODEProblem`. `reltol` and `saveat`
  override values read from an experiment annotation.

## Returns
- A `SciMLBase.ODEProblem` constructed from the imported ModelingToolkit system.

## Errors
- Throws an error when the parser cannot read `filename` or an unsupported parser is requested.

## Examples

```julia
using BaseModelica

filename = joinpath(pkgdir(BaseModelica), "test", "testfiles", "Experiment.bmo")
prob = create_odeproblem(filename)
prob.tspan
# output
(0.0, 2.0)
```
"""
function create_odeproblem(
        filename::AbstractString; parser::Symbol = :antlr, u0 = [], discrete_backend = :auto,
        simplify = true, kwargs...
    )
    simplify === false &&
        throw(ArgumentError("create_odeproblem needs a simplified system; pass `simplify = true` or a function"))
    package = parse_package(filename, parser)

    # Convert to ModelingToolkit
    sys = baseModelica_to_ModelingToolkit(package; discrete_backend, simplify)

    # Collect tstops from time-based if-equation conditions (e.g. `if time < 1e-5`)
    # so the ODE solver stops exactly at each discontinuity.
    model_tstops = isempty(tstops_collection) ? nothing : sort!(collect(tstops_collection))

    # Experiment settings travel with the system as metadata
    exp_params = experiment_settings(sys)

    # Create ODEProblem with appropriate time span and tolerance
    if !isnothing(exp_params)
        tspan = (exp_params.StartTime, exp_params.StopTime)

        # Build kwargs with annotation defaults, but allow user overrides
        # Check if reltol or saveat are already in kwargs
        kwargs_keys = keys(kwargs)

        # Start with annotation values
        annotation_kwargs = NamedTuple()
        if !(:reltol in kwargs_keys)
            annotation_kwargs = merge(annotation_kwargs, (reltol = exp_params.Tolerance,))
        end
        if !(:saveat in kwargs_keys) && !isnothing(exp_params.Interval)
            annotation_kwargs = merge(annotation_kwargs, (saveat = exp_params.Interval,))
        end

        # Merge annotation defaults with user kwargs (user kwargs take precedence)
        prob = ODEProblem(sys, u0, tspan; missing_guess_value = ModelingToolkitBase.MissingGuessValue.Constant(0.0), annotation_kwargs..., kwargs...)
        return prob
    else
        # Default time span if no annotation
        tspan = (0.0, 1.0)
        prob = ODEProblem(sys, u0, tspan; missing_guess_value = ModelingToolkitBase.MissingGuessValue.Constant(0.0), kwargs...)
        return prob
    end
end

include("precompilation.jl")

export parse_basemodelica, create_odeproblem, parse_experiment_annotation,
    experiment_settings

# The discrete backend interface is public but not exported (`public` needs Julia 1.11).
@static if VERSION >= v"1.11"
    eval(
        Meta.parse(
            "public AbstractDiscreteBackend, MTKEventsBackend, DiscreteModel, WhenBlock, " *
                "LoweredDiscrete, lower_discrete, declare_discrete, compile_system, " *
                "register_discrete_backend!, unregister_discrete_backend!, UnsupportedFeatureError"
        )
    )
end

end
