# function to convert "AST" to ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D
using DiffEqBase: BrownFullBasicInit

@data BaseModelicaRuntimeTypes begin
    RTRecord()
    RTClass()
    RTFunction()
    #built in classes
    RTReal()
    RTInteger()
    RTBoolean()
    RTString()
end

function modelica_type_to_julia(type_str::String)
    if type_str == "Integer"
        return Int
    elseif type_str == "Boolean"
        return Bool
    elseif haskey(enum_map, type_str)
        return Int
    else  # "Real" or other
        return Float64
    end
end

function eval_AST(expr::BaseModelicaExpr)
    return let f = eval_AST
        @match expr begin
            BaseModelicaNumber(val) => val
            BaseModelicaBool(val) => begin
                # val can be either a string "true"/"false" or a boolean true/false
                if isa(val, Bool)
                    val
                else
                    val == "true"
                end
            end
            BaseModelicaFactor(base, exp) => (f(base))^f(exp)
            BaseModelicaSum(left, right) => (f(left)) + (f(right))
            BaseModelicaMinus(left, right) => f(left) - f(right)
            BaseModelicaUnaryMinus(operand) => -f(operand)
            BaseModelicaProd(left, right) => f(left) * f(right)
            BaseModelicaDivide(left, right) => f(left) / f(right)
            BaseModelicaNot(relation) => ~f(relation)
            BaseModelicaAnd(left, right) => f(left) & f(right)
            BaseModelicaOr(left, right) => f(left) | f(right)
            BaseModelicaLEQ(left, right) => f(left) <= f(right)
            BaseModelicaGEQ(left, right) => f(left) >= f(right)
            BaseModelicaLessThan(left, right) => f(left) < f(right)
            BaseModelicaGreaterThan(left, right) => f(left) > f(right)
            BaseModelicaEQ(left, right) => f(left) == f(right)
            BaseModelicaNEQ(left, right) => f(left) != f(right)
            _ => nothing
        end
    end
end

function build_nested_ifelse(if_expr::BaseModelicaIfExpression, idx = 1)
    if idx > length(if_expr.conditions)
        return eval_AST(if_expr.expressions[end])
    end
    condition = eval_AST(if_expr.conditions[idx])
    then_value = eval_AST(if_expr.expressions[idx])
    else_value = build_nested_ifelse(if_expr, idx + 1)
    return ifelse(condition, then_value, else_value)
end

function eval_AST(if_expr::BaseModelicaIfExpression)
    return build_nested_ifelse(if_expr)
end

include("maps.jl")

function eval_AST(eq::BaseModelicaInitialEquation)
    inner_eq = eq.equation.equation
    # Skip tuple-return assignments like (a, b, , ) = func(...) — not supported
    inner_eq.lhs isa Vector && return Dict()
    lhs = eval_AST(inner_eq.lhs)
    isnothing(lhs) && return Dict()
    rhs = eval_AST(inner_eq.rhs)
    isnothing(rhs) && return Dict()
    return Dict(lhs => rhs)
end

function eval_AST(eq::BaseModelicaAnyEquation)
    equation = eval_AST(eq.equation)
    description = eq.description
    return equation
end

function eval_AST(annotation::BaseModelicaAnnotation)
    # Annotations are metadata and don't produce equations
    # For now, return nothing (they are parsed but ignored during evaluation)
    return nothing
end

# Helper function to extract a specific class modification value by name
function get_class_modification_value(modification, key_name::String)
    if isnothing(modification) || isempty(modification)
        return nothing
    end

    mod = modification[1]
    if isnothing(mod.class_modifications)
        return nothing
    end

    for arg in mod.class_modifications
        # Extract name string from BaseModelicaIdentifier
        arg_name = arg.name isa BaseModelicaIdentifier ? arg.name.name : arg.name
        if arg_name == key_name
            # If the arg has a modification with an expression, evaluate it
            if !isnothing(arg.modification) && !isnothing(arg.modification.expr) &&
                    !isempty(arg.modification.expr)
                return eval_AST(arg.modification.expr[end])
            end
        end
    end

    return nothing
end

function eval_AST(eq::BaseModelicaSimpleEquation)
    if eq.lhs isa BaseModelicaIfEquation
        return eval_AST(eq.lhs)
    end
    if isnothing(eq.rhs) && eq.lhs isa BaseModelicaFunctionCall
        # Function-call statement outside a when-equation: only assert is meaningful here
        fname = function_call_name(eq.lhs)
        fname == "assert" && return nothing
        unsupported("`$fname(...)` statement outside a when-equation is not supported")
    end
    lhs = eval_AST(eq.lhs)
    rhs = eval_AST(eq.rhs)

    # If either side is nothing (e.g., from assert or other non-equation statements),
    # return nothing to filter out this equation
    if isnothing(lhs) || isnothing(rhs)
        return nothing
    end

    return lhs ~ rhs
end

function eval_AST(if_eq::BaseModelicaIfEquation)
    # Convert if-equation to nested ifelse calls
    # Structure: ifs[i] contains condition, thens[i] contains a list of equations for that branch
    # If length(thens) > length(ifs), thens[end] is the else branch (no condition)

    has_else = length(if_eq.thens) > length(if_eq.ifs)

    # Collect tstops from time-based conditions (e.g. time < 1e-5)
    for cond in if_eq.ifs
        threshold = extract_time_threshold(cond)
        isnothing(threshold) || push!(tstops_collection, threshold)
    end

    # Helper to extract RHS for a specific variable from a branch's equation list
    function get_rhs_for_var(var_lhs, branch_equations)
        equations_to_check = isa(branch_equations, AbstractArray) ? branch_equations :
            [branch_equations]
        for eq in equations_to_check
            eq_obj = isa(eq, BaseModelicaAnyEquation) ? eval_AST(eq.equation) : eval_AST(eq)
            if !isnothing(eq_obj) && isa(eq_obj, Equation) && isequal(eq_obj.lhs, var_lhs)
                return eq_obj.rhs
            end
        end
        return nothing
    end

    # Collect all unique LHS variables across all branches
    lhs_vars = Set()
    for eq_list in if_eq.thens
        equations_to_check = isa(eq_list, AbstractArray) ? eq_list : [eq_list]
        for eq in equations_to_check
            eq_obj = isa(eq, BaseModelicaAnyEquation) ? eval_AST(eq.equation) : eval_AST(eq)
            if !isnothing(eq_obj) && isa(eq_obj, Equation)
                push!(lhs_vars, eq_obj.lhs)
            end
        end
    end

    # Build nested ifelse for each variable
    function build_ifelse_for_var(var_lhs, idx = 1)
        if idx > length(if_eq.ifs)
            # Past all conditions
            if has_else
                rhs = get_rhs_for_var(var_lhs, if_eq.thens[end])
                if isnothing(rhs)
                    error("Variable $var_lhs not assigned in else branch")
                end
                return rhs
            else
                error("If-equation has no else branch and exhausted all conditions for $var_lhs")
            end
        end

        condition = eval_AST(if_eq.ifs[idx])
        rhs = get_rhs_for_var(var_lhs, if_eq.thens[idx])

        if isnothing(rhs)
            error("Variable $var_lhs not assigned in branch $idx")
        end

        if idx == length(if_eq.ifs) && !has_else
            # Last conditional branch with no else clause
            # In well-formed Modelica, this should be elseif true (always true)
            return ifelse(condition, rhs, zero(rhs))
        else
            else_expr = build_ifelse_for_var(var_lhs, idx + 1)
            return ifelse(condition, rhs, else_expr)
        end
    end

    result_equations = []
    for var in lhs_vars
        ifelse_rhs = build_ifelse_for_var(var)
        push!(result_equations, var ~ ifelse_rhs)
    end

    return result_equations
end

# Names of variables assigned in when-equation bodies: these are discrete variables.
function collect_when_body_var_names(equations)
    names = Set{Symbol}()
    for eq in equations
        when_eq = as_when_equation(eq)
        isnothing(when_eq) && continue
        for body in when_eq.thens, body_eq in body_list(body)
            inner = inner_equation(body_eq)
            if inner isa BaseModelicaSimpleEquation &&
                    inner.lhs isa BaseModelicaComponentReference && !isnothing(inner.rhs)
                push!(names, Symbol(inner.lhs.ref_list[1].name))
            end
        end
    end
    return names
end

function eval_AST(x::String)
    return x
end

function eval_AST(x::BaseModelicaString)
    return x.string
end

function eval_AST(::Nothing)
    return nothing
end

function eval_AST(component::BaseModelicaComponentClause)
    #this mutates a dict
    #place holder to get simple equations working
    #also needs to account for "modifications"
    #also doesn't handle constants yet
    list = component.component_list
    type_prefix = component.type_prefix.dpc
    declaration = list[1].declaration
    name = Symbol(declaration.ident[1].name)
    if type_prefix == "parameter"
        component.type_specifier.type == "String" && return nothing
        julia_type = modelica_type_to_julia(component.type_specifier.type)
        variable_map[name] = only(@parameters($name::julia_type))

        # Extract parameter value from modification
        # Modifications can be:
        # 1. Simple assignment: = value
        # 2. Class modification with assignment: (attr1=val1, ...) = value
        # In case 2, expr has multiple elements; the value is the last element
        if !isnothing(declaration.modification) && !isempty(declaration.modification)
            modification = declaration.modification[1]
            if !isnothing(modification.expr) && !isempty(modification.expr)
                # Get the last element which should be the assigned value
                # If there's only one element, it's a simple assignment
                # If there are multiple elements, the last one is the value after class modifications
                value_expr = modification.expr[end]

                # Evaluate the expression to get the numeric value
                parameter_val_map[variable_map[name]] = eval_AST(value_expr)
            end
        end
        return variable_map[name]
    elseif isnothing(type_prefix)
        variable_map[name] = only(@variables($name(t)))
    end
end

function extract_time_threshold(cond_ast)
    is_time_ref(x) = x isa BaseModelicaComponentReference &&
        length(x.ref_list) == 1 &&
        x.ref_list[1].name == "time"
    if (cond_ast isa BaseModelicaLessThan || cond_ast isa BaseModelicaLEQ) &&
            is_time_ref(cond_ast.left) && cond_ast.right isa BaseModelicaNumber
        return Float64(cond_ast.right.val)
    elseif (cond_ast isa BaseModelicaGEQ || cond_ast isa BaseModelicaGreaterThan) &&
            is_time_ref(cond_ast.left) && cond_ast.right isa BaseModelicaNumber
        return Float64(cond_ast.right.val)
    end
    return nothing
end

function eval_AST(
        model::BaseModelicaModel; backend::DiscreteBackend = MTKEventsBackend(),
        simplify = true
    )
    empty!(variable_map)
    empty!(parameter_val_map)
    empty!(discrete_variable_names)
    empty!(free_parameter_names)
    empty!(tstops_collection)
    empty!(bool_comparison_names)
    CURRENT_BACKEND[] = backend

    class_specifier = model.long_class_specifier

    composition = class_specifier.composition

    components = composition.components
    equations = composition.equations
    initial_equations = composition.initial_equations
    parameter_equations = composition.parameter_equations

    # Pre-scan when-equation bodies to find variables that should be discrete parameters.
    # These variables only change at events and must not have continuous ODE equations.
    union!(discrete_variable_names, collect_when_body_var_names(equations))

    # Two-pass approach for components:
    # Pass 1: Create all symbols in variable_map (without evaluating parameter values)
    # Pass 2: Evaluate parameter values (now all symbols exist for cross-references)

    vars = Num[]
    pars = Num[]
    declaration_eqs = []
    # Collects stateSelect values keyed by variable name, populated in Pass 2.
    # Keyed by name (Symbol) rather than the symbol itself so the final state_priorities
    # dict can be built after Pass 3.5 when variable_map symbols are fully resolved.
    state_select_raw = Dict{Symbol, Int}()

    # Pass 1: Create all variables and parameters in variable_map
    for comp in components
        name = Symbol(comp.component_list[1].declaration.ident[1].name)
        type_prefix = comp.type_prefix.dpc

        if type_prefix == "parameter" || haskey(enum_map, comp.type_specifier.type)
            comp.type_specifier.type == "String" && continue
            julia_type = modelica_type_to_julia(comp.type_specifier.type)
            variable_map[name] = only(@parameters($name::julia_type))
            push!(pars, variable_map[name])
        elseif type_prefix == "constant"
            comp.type_specifier.type == "String" && continue
            julia_type = modelica_type_to_julia(comp.type_specifier.type)
            variable_map[name] = only(@parameters($name::julia_type))
            push!(pars, variable_map[name])
        elseif type_prefix == "discrete"
            # Explicitly declared discrete variables — treat same as when-body discretes.
            union!(discrete_variable_names, [name])
            variable_map[name] = declare_discrete(backend, name)
        elseif isnothing(type_prefix)
            if name in discrete_variable_names
                # Discrete variables only change at events; the backend decides how they
                # are represented (MTK discretes or SynchToolkit clocked variables).
                variable_map[name] = declare_discrete(backend, name)
            elseif comp.type_specifier.type == "Boolean"
                # Bool comparison vars (e.g. `off = s < 0`) become discrete parameters.
                # They hold their value between events and are updated by a zero-crossing
                # callback. ImperativeAffect is used (not discrete_parameters), so dotted
                # names like `Ideal.off` are fine — Symbolics wraps them in var"..." in
                # generated code, avoiding any parse issues.
                push!(bool_comparison_names, name)
                disc_sym = only(@discretes($name(t)::Bool))
                # Apply start value if declared (sets the initial discrete state)
                start_val = get_class_modification_value(
                    comp.component_list[1].declaration.modification, "start"
                )
                default_val = !isnothing(start_val) ? start_val : false
                disc_sym = ModelingToolkitBase.setdefault(disc_sym, default_val)
                variable_map[name] = disc_sym
                # Don't push to vars — discrete parameters appear in all_pars
            else
                variable_map[name] = only(@variables($name(t)))
                push!(vars, variable_map[name])
            end
        end
    end

    # Start values of discrete variables (the value of `pre(v)` at the first event).
    # Modelica's default start value is zero (false for Booleans).
    discrete_starts = Dict{Symbol, Any}()

    # Pass 2: Evaluate parameter values and handle start/fixed for variables
    for comp in components
        type_prefix = comp.type_prefix.dpc
        name = Symbol(comp.component_list[1].declaration.ident[1].name)
        declaration = comp.component_list[1].declaration

        if name in discrete_variable_names
            start_value = get_class_modification_value(declaration.modification, "start")
            discrete_starts[name] = something(
                start_value, comp.type_specifier.type == "Boolean" ? false : 0.0
            )
            continue
        elseif name in bool_comparison_names
            # Bool-comparison vars are handled separately; skip pass-2 processing.
            continue
        end

        if type_prefix == "parameter" || type_prefix == "constant" ||
                haskey(enum_map, comp.type_specifier.type)
            comp.type_specifier.type == "String" && continue
            # Check for fixed = false (parameter to be solved during initialization)
            fixed_value = get_class_modification_value(declaration.modification, "fixed")
            is_free = !isnothing(fixed_value) && fixed_value === false

            if is_free
                push!(free_parameter_names, name)
                # start value is an initial guess, not a default
                start_value = get_class_modification_value(declaration.modification, "start")
                if !isnothing(start_value)
                    variable_map[name] = ModelingToolkitBase.setguess(variable_map[name], start_value)
                end
            else
                # Collect into parameter_val_map; setdefault is applied in pass 3 below.
                # We cannot call setdefault here because setdefault returns a NEW symbol
                # object. A forward reference (e.g. V.signalSource.startTime = V.startTime
                # where V.startTime is declared later) would embed the OLD stale symbol in
                # the expression — MTK cannot resolve it. Pass 3 substitutes all references
                # to concrete values first, then setdefault is called once with clean values.
                if !isnothing(declaration.modification) && !isempty(declaration.modification)
                    modification = declaration.modification[1]
                    if !isnothing(modification.expr) && !isempty(modification.expr)
                        value_expr = modification.expr[end]
                        parameter_val_map[variable_map[name]] = eval_AST(value_expr)
                    end
                end
            end
        elseif isnothing(type_prefix)
            # This is a variable - check for start and fixed attributes
            start_value = get_class_modification_value(declaration.modification, "start")
            fixed_value = get_class_modification_value(declaration.modification, "fixed")

            var = variable_map[name]
            if !isnothing(start_value)
                # If fixed=true, use setdefault for initial condition
                # Otherwise use setguess for guess value
                is_fixed = !isnothing(fixed_value) &&
                    (fixed_value === true || fixed_value == true)
                if is_fixed
                    variable_map[name] = ModelingToolkitBase.setdefault(var, start_value)
                else
                    variable_map[name] = ModelingToolkitBase.setguess(var, start_value)
                end
            else
                # No explicit start: set a default guess of 0.0 so that all variables
                # have numeric guesses. Without this, MTK's initialization problem can
                # end up with symbolic (cyclic) guesses when missing_guess_value is not
                # forwarded through SCCNonlinearProblem → NonlinearProblem.
                variable_map[name] = ModelingToolkitBase.setguess(var, 0.0)
            end
            idx = findfirst(v -> SymbolicIndexingInterface.getname(v) == name, vars)
            !isnothing(idx) && (vars[idx] = variable_map[name])

            # stateSelect attribute: StateSelect.never/avoid/default/prefer/always → Int 1–5
            ss_value = get_class_modification_value(declaration.modification, "stateSelect")
            if !isnothing(ss_value) && ss_value isa Int
                state_select_raw[name] = ss_value
            end

            # Check for declaration equation (e.g. Boolean 'y' = time >= 0.5)
            # A direct expression in the modification (not a named class attribute) is a
            # binding equation that must become an explicit MTK equation.
            if !isnothing(declaration.modification) && !isempty(declaration.modification)
                mod = declaration.modification[1]
                if !isnothing(mod.expr) && !isempty(mod.expr)
                    decl_val = eval_AST(mod.expr[end])
                    if !isnothing(decl_val)
                        push!(declaration_eqs, variable_map[name] ~ decl_val)
                    end
                end
            end
        end
    end

    # Pass 3: Substitute parameter cross-references to get concrete values.
    # e.g. V.signalSource.startTime = V.startTime, V.startTime = 1.0
    # After substitution: V.signalSource.startTime = 1.0
    # TODO: this could probably be replaced with the bindings system?
    for (param, value) in parameter_val_map
        parameter_val_map[param] = substitute(value, parameter_val_map)
    end

    # Pass 3.5: Apply concrete parameter values via setdefault.
    # Done after pass 3 so we always call setdefault with a resolved concrete value,
    # never with an expression containing a stale pre-setdefault symbol reference.
    for name in collect(keys(variable_map))
        sym = variable_map[name]
        val = get(parameter_val_map, sym, nothing)
        if !isnothing(val)
            variable_map[name] = ModelingToolkitBase.setdefault(sym, val)
        end
    end

    # Build state_priorities from stateSelect attributes collected in Pass 2.
    # variable_map is now fully resolved (after Pass 3.5), so symbol keys are stable.
    state_priorities = Dict(
        variable_map[name] => val
            for (name, val) in state_select_raw
            if haskey(variable_map, name) && val != Int(StateSelectDefault)
    )

    # Split equations into when-equations (→ events) and regular equations.
    when_equation_list = []
    regular_equations = []
    for eq in equations
        when_eq = as_when_equation(eq)
        isnothing(when_eq) ? push!(regular_equations, eq) : push!(when_equation_list, when_eq)
    end

    # Flatten regular equations - some (like if-equations) return lists
    eqs = []
    for eq in regular_equations
        eq_obj = eval_AST(eq)
        if isa(eq_obj, Vector)
            # If-equations return a vector of equations
            append!(eqs, eq_obj)
        elseif !isnothing(eq_obj)
            push!(eqs, eq_obj)
        end
    end

    when_clause_list = WhenClause[]
    for when_eq in when_equation_list
        append!(when_clause_list, when_clauses(when_eq))
    end

    #vars_and_pars = merge(Dict(vars .=> vars), Dict(pars .=> pars))
    #println(vars_and_pars)
    #eqs = [substitute(x,vars_and_pars) for x in eqs]

    # Apply initial equations:
    # When free parameters are present, ALL initial equations must go into initialization_eqs
    # so they collectively constrain the initialization system that solves for the free params.
    # When no free parameters exist, regular variables use setdefault (simpler, more efficient).
    # Derivative LHS like der(x) always go to initialization_eqs (can't be setdefault).
    initialization_eqs = Equation[]
    has_free_params = !isempty(free_parameter_names)
    # `pre(v) = value` / `v = value` for a discrete v sets the start value of v
    initial_equations = filter(initial_equations) do eq
        name = discrete_initial_target(eq)
        isnothing(name) && return true
        discrete_starts[name] = eval_AST(eq.equation.equation.rhs)
        return false
    end
    for dictionary in [eval_AST(eq) for eq in initial_equations]
        for (var, value) in dictionary
            found = false
            for (name, sym) in variable_map
                if isequal(sym, var)
                    found = true
                    if has_free_params
                        push!(initialization_eqs, sym ~ value)
                    else
                        new_sym = ModelingToolkitBase.setdefault(sym, value)
                        variable_map[name] = new_sym
                        idx = findfirst(v -> isequal(v, sym), vars)
                        !isnothing(idx) && (vars[idx] = new_sym)
                    end
                    break
                end
            end
            if !found
                # LHS not in variable_map (e.g. der(x)) → initialization constraint
                push!(initialization_eqs, var ~ value)
            end
        end
    end

    # Pass 4: Apply explicit guess values from parameter equations.
    for param_eq in parameter_equations
        name = Symbol(param_eq.component_reference.ref_list[1].name)
        var = variable_map[name]
        value = eval_AST(param_eq.expression)
        variable_map[name] = ModelingToolkitBase.setguess(var, value)
        idx = findfirst(v -> SymbolicIndexingInterface.getname(v) == name, vars)
        !isnothing(idx) && (vars[idx] = variable_map[name])
    end

    # Build discrete callbacks for Bool comparison variables (e.g. `off = s < 0`).
    # `off` is a discrete parameter (constant between events) so the Jacobian is
    # smooth between events — no Dirac delta at the switching point.
    # The callback detects s=0 crossings and updates `off`:
    #   s goes positive→negative: off becomes true  (affect, diode starts blocking)
    #   s goes negative→positive: off becomes false (affect_neg, diode starts conducting)
    # The sanitized name (dots → underscores) avoids an MTK codegen bug where
    # dotted parameter names produce invalid Julia like `Ideal.offₜ₋₁`.
    bool_crossing_callbacks = ModelingToolkitBase.SymbolicContinuousCallback[]
    filtered_eqs = Equation[]
    for eq in eqs
        lhs_name = try
            SymbolicIndexingInterface.getname(eq.lhs)
        catch
            nothing
        end
        if isa(eq, Equation) && lhs_name in bool_comparison_names
            off_sym = eq.lhs
            crossing = try
                to_zero_crossing(eq.rhs)
            catch
                nothing
            end
            if !isnothing(crossing)
                # Use ImperativeAffect to bypass ImplicitDiscreteFunction codegen,
                # which has a bug with discrete parameter names containing subscripts.
                affect = ModelingToolkitBase.ImperativeAffect(
                    (m, o, ctx, integ) -> (; off = true);
                    modified = (; off = off_sym)
                )
                affect_neg = ModelingToolkitBase.ImperativeAffect(
                    (m, o, ctx, integ) -> (; off = false);
                    modified = (; off = off_sym)
                )
                cb = ModelingToolkitBase.SymbolicContinuousCallback(
                    Equation[crossing ~ 0],
                    affect;
                    affect_neg = affect_neg,
                    reinitializealg = BrownFullBasicInit(),
                )
                push!(bool_crossing_callbacks, cb)
            else
                # Not a comparison expression — treat as a constant Bool assignment.
                concrete_val = try
                    b = Symbolics.value(eq.rhs)
                    b isa Bool ? b : nothing
                catch
                    nothing
                end
                if !isnothing(concrete_val)
                    variable_map[lhs_name] =
                        ModelingToolkitBase.setdefault(off_sym, concrete_val)
                end
                # Either way, don't add to filtered_eqs: `off` is a discrete parameter.
            end
            # Omit the definition equation: `off` is updated by the callback, not by
            # an algebraic equation in the DAE.
        else
            push!(filtered_eqs, eq)
        end
    end
    eqs = filtered_eqs

    real_eqs = Equation[declaration_eqs..., eqs...]

    # Collect all parameters from variable_map after all passes have applied defaults.
    # Both regular @parameters and @discretes symbols have PARAMETER type, so this
    # captures them all — including discrete variables that only appear in callbacks
    # and would be missed by auto-detection from equations.
    all_pars = Num[sym for (_, sym) in variable_map if ModelingToolkitBase.isparameter(sym)]

    # Build bindings for free parameters (fixed=false): p => missing signals MTK to
    # solve for p during initialization using initialization_eqs.
    bindings = [variable_map[name] => missing for name in free_parameter_names]

    # Lower when-equations through the discrete backend.
    discrete_start_pairs = [variable_map[name] => value for (name, value) in discrete_starts]
    lowered = lower_when_clauses(
        backend, when_clause_list, differentiated_variables(real_eqs), discrete_start_pairs
    )
    append!(real_eqs, lowered.equations)

    # Discrete variables that the backend represents as (clocked) unknowns
    for name in discrete_variable_names
        sym = variable_map[name]
        ModelingToolkitBase.isparameter(sym) || push!(vars, sym)
    end

    @named sys = System(
        real_eqs, t, vars, all_pars;
        continuous_events = vcat(lowered.continuous_events, bool_crossing_callbacks),
        discrete_events = lowered.discrete_events,
        initialization_eqs = vcat(initialization_eqs, lowered.initialization_eqs),
        initial_conditions = Dict(lowered.initial_conditions),
        bindings = bindings,
        state_priorities = state_priorities,
    )
    experiment = parse_experiment_annotation(composition.annotation)
    if !isnothing(experiment)
        sys = SymbolicUtils.setmetadata(sys, ExperimentAnnotation, experiment)
    end
    if simplify === true
        return compile_system(backend, sys)
    elseif simplify === false
        return sys
    else
        return simplify(sys)
    end
end

# The discrete variable named by the left-hand side of an initial equation `pre(v) = ...`
# or `v = ...`, or nothing if the equation does not initialize a discrete variable.
function discrete_initial_target(eq::BaseModelicaInitialEquation)
    inner = eq.equation.equation
    inner isa BaseModelicaSimpleEquation || return nothing
    lhs = inner.lhs
    if lhs isa BaseModelicaFunctionCall && function_call_name(lhs) == "pre"
        lhs = only(lhs.args.args)
    end
    lhs isa BaseModelicaComponentReference || return nothing
    name = Symbol(lhs.ref_list[1].name)
    return name in discrete_variable_names ? name : nothing
end

function eval_AST(package::BaseModelicaPackage; kwargs...)
    empty!(enum_map)
    # Register built-in StateSelect enumeration so StateSelect.prefer etc. resolve correctly.
    enum_map["StateSelect"] = Dict(
        :never => Int(StateSelectNever),
        :avoid => Int(StateSelectAvoid),
        :default => Int(StateSelectDefault),
        :prefer => Int(StateSelectPrefer),
        :always => Int(StateSelectAlways),
    )
    for class_def in package.class_defs
        if class_def isa BaseModelicaClassDefinition && class_def.class isa BaseModelicaEnumeration
            enum = class_def.class
            enum_map[enum.name] = Dict(Symbol(v) => i for (i, v) in enumerate(enum.values))
        end
    end
    model = package.model
    return eval_AST(model; kwargs...)
end

function eval_AST(function_args::BaseModelicaFunctionArgs)
    args = function_args.args
    return eval_AST.([args...])
end

function eval_AST(function_call::BaseModelicaFunctionCall)
    if function_call.func_name isa BaseModelicaComponentReference
        function_name = Symbol(function_call.func_name.ref_list[1].name)
    else
        function_name = Symbol(function_call.func_name.name)
    end

    # Skip assert calls - they are verification statements, not equations
    if function_name == :assert
        return nothing
    end

    if function_name == :pre
        arg = with_eval_mode(() -> eval_AST(only(function_call.args.args)), :raw)
        return apply_pre(arg)
    end

    haskey(function_map, function_name) ||
        unsupported("function `$function_name` is not supported")
    args = eval_AST(function_call.args)
    return function_map[function_name](args)
end

function eval_AST(comp_reference::BaseModelicaComponentReference)
    #will need to eventually account for array references and dot references...
    #for now only does direct references to variables
    ref_name = Symbol(comp_reference.ref_list[1].name)

    # Handle special built-in variables
    if ref_name == :time
        return t  # Map Modelica 'time' to ModelingToolkit 't'
    end
    if ref_name == :AssertionLevel
        return nothing
    end

    # Handle enum value references: EnumType.ValueName → integer
    if length(comp_reference.ref_list) >= 2
        type_name = comp_reference.ref_list[1].name
        value_name = Symbol(comp_reference.ref_list[2].name)
        if haskey(enum_map, type_name) && haskey(enum_map[type_name], value_name)
            return enum_map[type_name][value_name]
        end
    end

    sym = get(variable_map, ref_name, nothing)
    return isnothing(sym) ? nothing : apply_reference_mode(sym)
end

"""
    baseModelica_to_ModelingToolkit(package; discrete_backend = :auto, simplify = true)

Convert a parsed `BaseModelicaPackage` into a ModelingToolkit `System`. See
[`parse_basemodelica`](@ref) for the keyword arguments.
"""
function baseModelica_to_ModelingToolkit(
        package::BaseModelicaPackage; discrete_backend = :auto, simplify = true
    )
    return eval_AST(package; backend = select_backend(discrete_backend), simplify)
end
