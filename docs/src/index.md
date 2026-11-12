# BaseModelica.jl: BaseModelica Importers for ModelingToolkit.jl

BaseModelica.jl is an interface for the SciML open source software organization for importing
BaseModelica, a new standard from the Modelica association for lowered Modelica code. As such,
it makes it easy to import Modelica models into ModelingToolkit.

## Installation

To install BaseModelica.jl, use the Julia package manager:

```julia
using Pkg
Pkg.add("BaseModelica")
```

## API

```@docs
parse_basemodelica
parse_experiment_annotation
create_odeproblem
experiment_settings
BaseModelica.UnsupportedFeatureError
```

## Constants and parameters

How declarations map to ModelingToolkit, and what `remake` can change afterwards:

| BaseModelica | ModelingToolkit | changeable after loading? |
|---|---|---|
| `constant Real c = 9.81` | inlined: every reference becomes `9.81` | no; `c` is not in the system |
| `parameter Real p = 2.0` | tunable parameter with initial value `2.0` | yes |
| `parameter Real r = p*q` | parameter with binding `r = p*q` | no; recomputed from `p` and `q` |
| `parameter Integer n = 3 annotation(Evaluate = true)` | non-tunable parameter | not reliably, see below |

- **Constants** are inlined. ModelingToolkit's `@constants` only marks a parameter
  `tunable = false`, which `remake` can still change; a Modelica constant cannot change.
  The value of a constant is not available as `prob.ps[c]`. A constant whose value is not
  a number (no binding, say) stays a non-tunable parameter.
- **Dependent bindings** become ModelingToolkit bindings, so
  `remake(prob; p = [sys.p => 5.0])` recomputes `r`, and so does every parameter bound to
  `r`. A bound parameter cannot be set itself: `remake(prob; p = [sys.r => 7.0])` throws.
  Bindings are listed by `ModelingToolkit.bound_parameters(sys)`, not by `parameters(sys)`.
- **`Evaluate = true` parameters** were evaluated by the tool that wrote the file, which may
  have used their value to size an array, unroll a `for` loop, pick an `if` branch or remove
  a conditional component. They become parameters with `tunable = false`, and a binding
  such as `k = 2*n` is evaluated to a number. Their description reads
  `parameter 'n' was evaluated at translation (Evaluate=true); recompile to change it`.
  ModelingToolkit has no metadata that makes `remake` or `setp` reject a parameter, so
  changing one is not an error; loading such a model warns once, listing them. Change the
  value in the Modelica source and translate again instead.
- **Inert parameters**, which no equation, binding, start value or other attribute
  references, were most likely used at translation by a tool that did not mark them
  `Evaluate = true`. Loading the model warns once, listing them: changing them has no
  effect.

## Discrete backends

How discrete variables and `when` equations are lowered is pluggable. BaseModelica
evaluates them into a symbolic [`BaseModelica.DiscreteModel`](@ref) and passes it to a
backend. The built-in backend, `:mtk`, uses ModelingToolkit symbolic events. Other packages
provide backends by subtyping [`BaseModelica.AbstractDiscreteBackend`](@ref) and calling
[`BaseModelica.register_discrete_backend!`](@ref) from `__init__`. For example,
SynchToolkit.jl registers `:synchtoolkit` from its `SynchToolkitBaseModelicaExt` extension,
so `discrete_backend = :synchtoolkit` works after `using SynchToolkit`.

```@docs
BaseModelica.AbstractDiscreteBackend
BaseModelica.register_discrete_backend!
BaseModelica.unregister_discrete_backend!
BaseModelica.lower_discrete
BaseModelica.declare_discrete
BaseModelica.compile_system
BaseModelica.DiscreteModel
BaseModelica.WhenBlock
BaseModelica.LoweredDiscrete
BaseModelica.MTKEventsBackend
```

## Contributing

  - Please refer to the
    [SciML ColPrac: Contributor's Guide on Collaborative Practices for Community Packages](https://sciml.github.io/ColPrac/stable/)
    for guidance on PRs, issues, and other matters relating to contributing to SciML.

  - See the [SciML Style Guide](https://github.com/SciML/SciMLStyle) for common coding practices and other style decisions.
  - There are a few community forums:
    
      + The #diffeq-bridged and #sciml-bridged channels in the
        [Julia Slack](https://julialang.org/slack/)
      + The #diffeq-bridged and #sciml-bridged channels in the
        [Julia Zulip](https://julialang.zulipchat.com/#narrow/stream/279055-sciml-bridged)
      + On the [Julia Discourse forums](https://discourse.julialang.org)
      + See also [SciML Community page](https://sciml.ai/community/)

## Reproducibility

```@raw html
<details><summary>The documentation of this SciML package was built using these direct dependencies,</summary>
```

```@example
using Pkg # hide
Pkg.status() # hide
```

```@raw html
</details>
```

```@raw html
<details><summary>and using this machine and Julia version.</summary>
```

```@example
using InteractiveUtils # hide
versioninfo() # hide
```

```@raw html
</details>
```

```@raw html
<details><summary>A more complete overview of all dependencies and their versions is also provided.</summary>
```

```@example
using Pkg # hide
Pkg.status(; mode = PKGMODE_MANIFEST) # hide
```

```@raw html
</details>
```

```@eval
using TOML
using Markdown
version = TOML.parse(read("../../Project.toml", String))["version"]
name = TOML.parse(read("../../Project.toml", String))["name"]
link_manifest = "https://github.com/SciML/" * name * ".jl/tree/gh-pages/v" * version *
                "/assets/Manifest.toml"
link_project = "https://github.com/SciML/" * name * ".jl/tree/gh-pages/v" * version *
               "/assets/Project.toml"
Markdown.parse("""You can also download the
[manifest]($link_manifest)
file and the
[project]($link_project)
file.
""")
```
