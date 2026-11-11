# BaseModelica.jl: events, parser fixes, user functions, Dyad/SynchToolkit path

Pipeline: Modelica → rumoca → Base Modelica (MCP-0031) → BaseModelica.jl → ModelingToolkit →
(DyadInterface.simplify_model) → OrdinaryDiffEq.

Branch: the factory task branch (`factory/5dc384ae-…`). The brief asked for
`bm-events-and-parser-fixes`, but the factory only collects commits from the task branch.
The head can push it under that name.

Environment:
- Julia 1.13.3. The suite started on 1.12.7, but the juliaup install changed during the
  task and 1.12.7 was removed.
- ModelingToolkit 11.45.5, ModelingToolkitBase 1.77.5, Symbolics 7.46.0, OrdinaryDiffEq 7.8.1.
- Dyad env: DyadInterface 7.5.1, SynchToolkit 0.5.2, SynchJulia 0.8.6. An earlier
  validation used 0.4.8 / 0.2.3.

## Commits (oldest first)

1. `4a7881d` Fix :julia parser dropping terms after a leading unary minus (fix 3)
2. `2ee6d8e` Make the :antlr backend throw on syntax errors (fix 4)
3. `81dbcae` Skip comments between tokens in the :julia parser (trailing `//` hang)
4. `2733180` Keep function-call statements and elsewhen branches in the :antlr AST (fix 1, parser part)
5. `638b3b1` Lower when-equations to MTK symbolic events with reinit and pre semantics
   (fixes 1 and 2, which share the refactor; also the `simplify`/`discrete_backend` API and
   experiment metadata)
6. `fcca725` Keep every equation of a when-branch body in the :julia parser
7. `0782f34` Support user functions, algorithm statements and array constructors (item 5)
8. `b567948` Add an experimental SynchToolkit discrete backend as a package extension
9. `9e782c7` README and outputs (this report, Dyad end-to-end script)
10. Validation on SynchToolkit 0.5.2 (logs, report, extension notes)

## Fixes

| # | Problem | Fix | Tests |
|---|---|---|---|
| 3 | `:julia` parser dropped the terms after a leading unary minus (`-'x' - 0.1*'v'` became `-'x'`) | `create_arithmetic_expression` applies the unary operator to the first term and keeps folding. A leading `+` is accepted too. | `test_julia_parser.jl`: arithmetic cases plus `UnaryMinusLeading.bmo` |
| 4 | `:antlr` printed syntax errors to stderr and returned a partial model | The default ANTLR listeners on lexer and parser are replaced by a collecting listener. Errors throw `BaseModelicaParseError` with every line/column, source context, and the filename when parsing a file. | `test_error_messages.jl` (ANTLR testset) |
| new | `:julia` parser: a trailing `// comment` made parsing fail, and with `NoCache` backtracking it hung for minutes | `spc` also skips `//` and `/* */` comments | `TrailingComments.bmo`, parsed in a subprocess with a 300 s timeout |
| 1 (part) | `:antlr` dropped function-call statements, so `reinit(...)` vanished; `elsewhen` bodies were merged into the first branch | Bare call statements are kept with an empty RHS. The when-equation children are walked per branch. | `test_events.jl` |
| 1 + 2 | `reinit` silently dropped (ball fell to -29 m with `Success`); `n = pre(n)+1` failed with `Symbol n(t) is not present` because discretes had no start value | New `src/events.jl`, described below | `test_events.jl` |
| new | `:julia` when-equation constructor kept only the first equation of each body | Collects all equations up to the next `elsewhen` | `test_events.jl` (initial-algorithm model with two assignments) |
| 5 | User functions, algorithm statements, `{...}` arrays; the `:julia` parser rejected indented algorithm statements and every `{...}`; arrays/`for` were sometimes silently wrong | Parsers and evaluator support described below. Everything still unsupported throws `UnsupportedFeatureError`. | `test_functions.jl`, `UserFunction.bmo` |
| API | Only compiled systems were returned, so Dyad's `simplify_model` and SynchToolkit's pass never ran | `simplify = true \| false \| f`; experiment annotation stored as system metadata (`experiment_settings(sys)`) | `test_events.jl`; `outputs/scripts/dyad_pipeline.jl` |

### Events design (fixes 1 and 2)

Each `when`/`elsewhen` branch is collected into a backend-independent `WhenClause`: the
condition, `v = expr` discrete assignments, and `reinit(x, expr)`. A `DiscreteBackend`
lowers the clauses.

The built-in `MTKEventsBackend` (the default) works as follows:
- Each distinct zero-crossing gets one `SymbolicContinuousCallback([c ~ 0], affects;
  affect_neg = nothing)`, which fires on the rising edge only. Clauses with the same
  crossing are merged: MTK fires only one of several callbacks that share a root.
- `sample(0, dt)` becomes a periodic `SymbolicDiscreteCallback`. A non-zero start throws,
  because MTK periodic callbacks have no phase.
- Affect equations follow Modelica semantics:
  - continuous variables read their pre-event value through `Pre`;
  - `pre(v)` becomes `Pre(v)`;
  - `reinit(x, e)` becomes `x ~ e`;
  - discrete assignments are passed as `discrete_parameters`.
- **Every state that is not reinitialized is held with `x ~ Pre(x)`.** MTK solves the
  affect together with the model's observed equations. Without the hold equations it
  treats unassigned states as free unknowns and corrupts them. Two examples verified in
  plain MTK:
  - with an observed `y ~ 2h + v`, the bouncing ball bounced once and then fell through;
  - updating `n` in `y ~ 2x + n` shifted `x` by -0.5.

  This looks like an upstream MTK issue worth reporting.
- Discrete variables get a start value, from the first available of: the `start`
  attribute; an initial equation `pre(v) = c` or `v = c`; an `initial algorithm`
  assignment; or the Modelica default 0.
- These now throw `UnsupportedFeatureError`: compound conditions (`a and b`), unknown
  functions, and anything in a when body other than assignments, `reinit` and `assert`.

### User functions, statements, arrays (item 5)

- **Parsers.** Both parsers produce the same new AST nodes: `BaseModelicaAlgorithmSection`,
  `BaseModelicaAssignment`, `BaseModelicaIfStatement`, `BaseModelicaForStatement`,
  `BaseModelicaUnsupportedStatement`, `BaseModelicaArrayConstructor` and
  `BaseModelicaUnsupportedExpression`.
- **`:julia` grammar fixes:**
  - statements tolerate whitespace;
  - `algorithm` is no longer accepted as a type name;
  - `function` class prefixes work.
  - `array_arguments` had a precedence bug: in Julia `|` and `+` share a precedence level,
    so every `{...}` required a for-index. When that failed, backtracking made the parser
    hang.
- **`:antlr` fixes:**
  - visitors for statements and algorithm sections (the latter had been ignored);
  - `{...}` is no longer a silent `0.0` placeholder;
  - function calls keep their full dotted name.
- **User functions are inlined symbolically** (`src/functions.jl`). The call's arguments
  are evaluated in the caller's context and bound to the inputs, with input defaults
  supported. The algorithm then runs on symbolic values:
  - `:=` assignments;
  - `if` becomes `ifelse`, or is folded when the condition is constant;
  - `for` over a constant range is unrolled.

  The result is a plain symbolic expression, so it needs no registration and is
  differentiable.
- **Throwing `UnsupportedFeatureError`:** `while`, `when` statements, multiple-output
  calls, external functions, recursion, and array variables inside functions.
- **Scalar `for`-equations** over constant ranges are unrolled.
- **Throwing in models:** array variables, multi-component clauses (`Real a, b;`, which
  used to lose `b` silently), matrix constructors, and algorithm sections.
- **`initial algorithm`** sections of plain assignments are supported. They run
  sequentially with `time` = experiment `StartTime`; `SimpleTriacCircuit.bmo` uses one.
- The generic expression evaluator now throws on unknown expression nodes instead of
  returning `nothing`.

### Dyad / unsimplified systems

- `parse_basemodelica(file; simplify = false)` returns the unsimplified `System`.
- `simplify = f` applies `f`, e.g. `DyadInterface.simplify_model`.
- `create_odeproblem(file; simplify = DyadInterface.simplify_model)` works.
- `experiment_settings(sys)` returns `(StartTime, StopTime, Tolerance, Interval)` and
  survives `mtkcompile`.

`outputs/scripts/dyad_pipeline.jl`, with its log in `dyad_pipeline.log`, runs
`.bmo` → unsimplified System → `DyadInterface.simplify_model` → `ODEProblem` → `Tsit5`,
plus `create_odeproblem(simplify = simplify_model)` and `TransientAnalysis(; model, stop)`.
On the MTK backend:
- every bouncing-ball path gives `Success`, 6 bounces, and min h ≈ 1e-17;
- for the counter, `y(0.25) = 0.5` and `y(1) = 3`, as expected.

### SynchToolkit (head's direction change): extension, opt-in, partly validated

**Packaging: a package extension**, `ext/BaseModelicaSynchToolkitExt.jl`, with SynchToolkit
as a weak dependency. BaseModelica is a SciML/General package, and SynchToolkit plus its
dependency SynchJulia exist only in the private DyadRegistry, so a hard dependency is
impossible. The extension uses only BaseModelica's backend interface
(`declare_discrete`, `discrete_reference`, `lower_when_clauses`, `compile_system`,
`clocked_reference`, `clocked_pre`). It can therefore move unchanged into a separate glue
package in DyadRegistry if General's AutoMerge rejects a weakdep that is not registered in
General. That is a risk to check before registering.

**Mapping:**

| Modelica | SynchToolkit |
|---|---|
| `when c then v = e` | `ZeroCrossing(c; down=false)` added to `continuous_events`, plus `EventClock(evt)` and `v(k) ~ e` |
| `sample(s, dt)` | `Clock(dt; phase=s)` |
| `pre(v)` | `v(k-1)`, with `v(k-1) ~ start` in `initialization_eqs` |
| a discrete read in continuous equations | `Hold(v)` |
| a continuous read in clocked equations | `Sample(clock)(x)` |
| `reinit(x, e)` | `Impulsive()(x) ~ e` on the clause's clock |

Clauses that contain only `reinit` stay plain MTK callbacks that are not linked to a
clock. This follows the scout's advice: an affect on a linked callback is swallowed.
Compilation is `mtkcompile(sys; additional_passes = [SynchToolkit.compile_lustre])`.
DyadInterface's `simplify_model` adds that pass itself.

**Validation on SynchToolkit 0.5.2** (SynchJulia 0.8.6, DyadInterface 7.5.1, MTK 11.45.5).
Logs: `outputs/scripts/synchtoolkit_probe_0.5.2.log` and `dyad_pipeline.log`.

| Model | Result |
|---|---|
| `BouncingBallCounter` (reinit via `Impulsive` plus a counter on the same `EventClock`) | correct: 6 bounces, the first at t = 0.4515 = √(2/g), min h ≈ 2e-17, counter 1…6 |
| `WhenElsewhen` (constant assignments, two clocks) | correct: a = 1 at t = 0.25, b = 2 at t = 0.75 |
| `DiscreteCounter` | ticks once at t = 0.5 with n = 1, and y(1) = 3 is correct |
| `BouncingBall` | identical to the MTK backend through `simplify_model`, `create_odeproblem` and `TransientAnalysis` |

The `DiscreteCounter` gap: the continuous observable `y = 2x + Hold(n)` cannot be
evaluated before n's first tick. `sol(0.25, idxs = y)` throws "Cannot access discrete
variable at time 0.25 before initial save 0.5", and `sol[y]` throws a `BoundsError`. The
MTK backend gives 0.5. SynchToolkit's own test suite marks the same pre-first-tick value
as broken.

Because of this gap, `discrete_backend = :auto` **still selects the MTK backend**, and
SynchToolkit runs only with `discrete_backend = :synchtoolkit`. This deviates from "must
go through SynchToolkit". Flip it in `select_backend` (`src/events.jl`) once
pre-first-tick holds work. Making the start value visible before the first tick may need
an `InitClock` tick or a SynchToolkit change.

SynchToolkit 0.4.8 results are kept for reference in `synchtoolkit_probe_0.4.8.log`:
- `Hold` showed the post-tick value before the first tick;
- constant assignments gave NaN;
- `Impulsive` on an event clock failed with `UndefVarError: typ`.

**How 0.5.2 was installed.** The package server answered 401: Pkg reads `auth.toml` only
from the first depot (`Pkg.depots1()`), which is the writable clone-local one. The local
DyadRegistry snapshot also stopped at SynchJulia 0.8.4. What worked, with no credential
handling:
- `Pkg.Registry.add(url = "https://github.com/JuliaComputing/DyadRegistry")` into the
  writable depot;
- then `Pkg.add` with `JULIA_PKG_USE_CLI_GIT=true` and `GIT_TERMINAL_PROMPT=0`, so private
  packages are cloned by the box's CLI git;
- `JULIA_DEPOT_PATH = <clone>/.julia-depot:~/.julia`.

## Test results

Full Core suite (`GROUP=Core julia --project=. -e 'using Pkg; Pkg.test()'`, Julia 1.13.3):

```
Test Summary:             | Pass  Total
Julia Parser Tests        |   85     85
ANTLR Parser Tests        |  138    138
Error Message Tests       |   35     35
Event Tests               |   56     56   (new file)
Function Tests            |   36     36   (new file)
Precompile Workload Tests |    1      1
     Testing BaseModelica tests passed
```
That is 351 passing tests, against 239 before the branch.

Key behavioural checks inside these tests:
- **Bouncing ball, both parsers:**
  - min h > -1e-6;
  - at least 3 velocity sign flips from down to up;
  - rebound speed at the first impact equals e·g·t₁ within 1e-3.
- **Counter:** `n` goes 0 → 1, and `x`/`y = 2x + n` stay exact across the event.
- **`elsewhen`:** both branches fire.
- **Discrete start values** from initial equations and initial algorithms.
- **User functions** match analytic results.
- **Unsupported constructs** throw.

The QA group (`GROUP=QA`, i.e. `SciMLTesting.run_qa`) errored before running any check,
for an environmental reason: `SystemError: opening file
".../.julia/packages/NonlinearSolveBase/.../Project.toml": Read-only file system`, because
`~/.julia` is read-only in this sandbox. Aqua was run separately; see below.

`Aqua.test_all(BaseModelica)` (Aqua 0.8.18, scratch env) passes all eight checks:
method ambiguity, unbound type parameters, undefined exports, Project/test Project
consistency, stale dependencies, compat bounds (4/4), piracy and persistent tasks. JET was
not run.

Other verification runs (scripts in the scratch env, outputs in `outputs/scripts/*.log`):
- `dyad_pipeline.jl`: MTK and SynchToolkit backends through `simplify_model`,
  `create_odeproblem` and `TransientAnalysis`.
- `synchtoolkit_probe.jl`: the SynchToolkit behaviour listed above, with logs for 0.5.2
  and 0.4.8.

## Remaining gaps

- **Array variables** (`Real x[3]`, `x[i]` references, array equations), matrix
  constructors, array comprehensions. These now throw instead of being silently wrong;
  the next step would be scalarizing declarations into `x[1]…x[n]` together with the
  `for` unrolling that already exists.
- **Functions:** `while`, multiple outputs `(a, b) := f(x)`, records, external functions,
  recursion, and arrays inside functions.
- **Algorithm sections in models** (non-initial).
- **Events:**
  - compound conditions (`a and b`), `edge`/`change`/`initial()`/`terminal()`;
  - Modelica `elsewhen` priority: branches are independent callbacks, which matters only
    when two branches trigger at the same instant;
  - `sample` with a non-zero start on the MTK backend;
  - `terminate()`.
- Models with **no continuous states** (e.g. `WhenEquation.bmo`) build, but Tsit5 cannot
  solve an empty state vector. This was already the case before this branch.
- **Integer discretes** are represented as `Real`, so `n` holds `1.0`.
- **SynchToolkit backend:** experimental and opt-in. It fails when a continuous
  observable reads a discrete variable before that variable's first tick (0.5.2).
- **Possible upstream MTK issue:** affects on systems with observed equations need
  explicit holds for unassigned states.
