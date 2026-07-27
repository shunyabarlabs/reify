# Developer Guide — Reify SDK Lifecycle

This guide walks through every stage a developer encounters when using the
Reify SDK from D code, in the order they encounter them. Each stage has a
one-line summary, a code snippet, and the most common mistakes.

A runnable companion is [`examples/dev_lifecycle_walkthrough.d`](../examples/dev_lifecycle_walkthrough.d)
— a 4-node graph coloring that exercises every stage. Stages 1–5 work
without an API key; stages 7–11 require `NAVOKOJ_API_KEY` in the environment.

---

## Stage 0 — Install

```bash
export NAVOKOJ_API_KEY=nvkj_...
ldc2 -i source/app.d source/reify/*.d -Isource -of=build/reify
```

You can build and validate models without a key. Solving requires one.

---

## Stage 1 — Author

`decisionApp(name, modelBuilder, presenter)` packages everything an
application needs. The builder declares variables and constraints. The
presenter shapes the final domain output.

```d
auto app = decisionApp("my-app", (Model model) {
    auto v = model.booleanVar("x");
    model.require("non-trivial", v);
});
```

Two builder overloads exist:
- **Static** `(Model model) => { ... }` — model is fully defined in D, no input.
- **Dynamic** `(Model model, JSONValue input) => { ... }` — per-request input.

**Mistake:** calling `model.booleanVar(...)` outside a builder — variables
must be created inside the `Model` closure passed to `decisionApp`.

---

## Stage 2 — Build

`app.build(input)` runs the builder and returns the symbolic `Model`. Pure,
no HTTP, no credits.

```d
Model model = app.build(JSONValue());
```

**You usually don't call this directly.** `app.compile()` and `app.solve()`
call `build()` internally. Call it explicitly only when you want to inspect
the model between authoring and compilation.

---

## Stage 3 — Validate

`validateModel(model)` performs semantic checks: domain bounds, ALO/AMO
shape, Tseitin well-formedness, integer range sanity. No credits.

```d
try {
    validateModel(model);
} catch (ModelException e) {
    // structural problem — fix the builder before solving
}
```

**Mistake:** treating validation as a substitute for the local verifier.
Validation checks the *structure* of the model; the verifier (Stage 8)
checks the *assignment* against the model after solving.

---

## Stage 4 — Compile

`app.compile(input, options)` lowers the `Model` to a backend wire payload:
CNF, WCNF, hybrid CNF+XOR, or Q-State. The router picks the backend based on
topology. No credits.

```d
CompiledModel compiled = app.compile(JSONValue(), CompileOptions());
writeln(backendName(compiled.backend));   // "cnf" | "hybrid" | "qstate"
foreach (key; compiled.request.object.byKey) writeln(key);
```

`compiled.request` is the exact JSON the Navokoj API would receive. Useful
for debugging without spending credits.

**Mistake:** expecting `compile()` to call the API. It doesn't — it only
produces the payload.

---

## Stage 5 — Analyze

`analyzeModel(model)` returns a `TopologyAnalysis`: variable count, clause
count, α density (M/N), phase-transition flag, structure classification,
and routing recommendation. No credits.

```d
auto a = analyzeModel(model);
writeln(a.alpha, " ", a.structureClassification, " ", a.suggestedAction);
```

For per-variable explainability, build a `DecisionSpace` from the model and
call `explainLogical(space)` to get a `LogicalPlan`; call `.print()` for a
formatted report. For routing-aware details, `explainPhysical(model)` returns
a `PhysicalPlan`.

**Mistake:** trusting `α` as a perf predictor in isolation. It is one input
to the router; the topology classifier and parity density matter too.

---

## Stage 6 — Configure Solve

`AppSolveOptions` carries two fields:
- `compilation` — engine override, hardware hint, timeout budget
- `request` — API key, endpoint overrides

```d
AppSolveOptions options;
options.compilation.engine = "nitro";
options.request.apiKey = environment.get("NAVOKOJ_API_KEY", "");
```

The API key field is optional if `NAVOKOJ_API_KEY` is in the environment —
`solve()` reads it automatically.

**Mistake:** setting `options.compilation.engine = "auto"` and expecting
the router to always pick the cheapest path. The router does run, but
override when you have prior knowledge (e.g., always CNF-native for
millions of clauses).

---

## Stage 7 — Solve

`app.solve(input, options)` is the one call that does everything:
build → compile → query `/v1/capabilities` → dispatch → hydrate → verify.
Returns a `SolveResult`.

```d
SolveResult result = app.solve(JSONValue(), options);
writeln(result.status);     // RunStatus: feasible | partial | serverReportedInfeasible | noAssignment
writeln(result.feasible);   // shorthand for status == RunStatus.feasible
```

**Mistake:** assuming `result.solution` is non-null on infeasible status.
Always check `result.solution !is null` before iterating `solution.keys()`.

---

## Stage 8 — Inspect Result

`SolveResult` exposes four sibling fields:

| Field | Purpose |
|---|---|
| `result.status` | `RunStatus` enum |
| `result.solution` | Hydrated `Solution` — `DecisionValue` per named variable |
| `result.verification` | `VerificationReport` — hard/medium/soft counts and per-constraint matches |
| `result.score` | `Score` — `hardViolations`, penalties, feasibility |

```d
auto v = result.verification;
writeln("Hard: ", v.hardSatisfied, " / ", v.hardSatisfied + v.hardViolated);
writeln("Medium violated: ", v.mediumViolated);
writeln("Soft violated: ", v.softViolated);

foreach (match; v.matches)
    if (match.level == ConstraintLevel.hard && match.state == MatchState.violated)
        writeln("  FAIL: ", match.name);
```

`result.solution.get(name)` returns a `DecisionValue` with a `kind`
(`boolean`, `categorical`, `integer`) and a typed accessor (`.booleanValue`,
`.categoricalValue`, `.integerValue`). Always check `.status` first.

**Mistake:** reading the solver's "SAT" answer as proof. The local verifier
re-proves the hard constraints against the hydrated assignment; the solver's
"SAT" only says *some* assignment exists.

---

## Stage 9 — Explain

`explainExecution(result)` reads already-present runtime fields and returns
an `ExecutionTrace`:

```d
ExecutionTrace trace = explainExecution(result);
writeln("Engine: ", trace.selectedEngine);
writeln("Solve time: ", trace.solveTimeMs, " ms");
writeln("Billing: $", trace.billingAmount);
```

For per-variable causality, `explainDecision(result, model, variableName)`
returns a `DecisionExplanation` that walks from a specific assignment back
to the constraints that shaped it.

For static analysis (pre-solve), `explainLogical(space)` and
`explainPhysical(model)` return `LogicalPlan` and `PhysicalPlan` — both
have `.print()` for formatted output.

---

## Stage 10 — Present

`app.present(input, result)` returns a `JSONValue` envelope. If you supplied
a presenter in `decisionApp(name, builder, presenter)`, the envelope carries
your domain output under the `domain_output` key.

```d
JSONValue envelope = app.present(JSONValue(), result);
JSONValue domain = envelope["domain_output"];
```

Use the presenter when your output is domain-shaped (a schedule, a
placement, a color assignment) rather than the raw hydration map.

**Mistake:** presenting before verifying. The presenter always runs on
whatever was hydrated; always inspect `result.verification.feasible` first
if the presenter assumes a feasible assignment.

---

## Stage 11 — Diagnose

`app.diagnose(input, options)` returns a `JSONValue` with the compiled model
plus a physics-informed diagnostic block (Chebyshev bias, Betti numbers,
bottleneck warnings).

```d
JSONValue diag = app.diagnose(JSONValue(), options);
foreach (key; diag.object.byKey) writeln(key);
```

Use it when a model is unexpectedly slow or failing — the diagnostic flags
phase-transition proximity, XOR cycle density, and categorical entropy that
the regular solver may not surface in its response.

---

## Stage 12 — Failure Modes

| Stage | Failure type | What to do |
|---|---|---|
| Author | `ModelException` from builder | Builder threw — check variable/constraint calls |
| Validate | `ModelException` from `validateModel` | Fix model structure before proceeding |
| Compile | `ModelException` from compile | Encoding overflow — check integer bounds, ALO/AMO size |
| Solve | `ProtocolException` | HTTP error — check API key, capabilities, network |
| Solve | Timeout (status = `noAssignment`) | Solver found nothing in budget — relax constraints or increase timeout |
| Verify | `verification.feasible = false` | The local re-verifier rejected the solver's assignment — report a bug |

**The local verifier is your last line of defense.** If `verification.feasible`
is false, the solver returned an assignment that doesn't satisfy your own
hard constraints. Don't trust the solver; trust `verification.feasible`.

---

## End-to-End

[`examples/dev_lifecycle_walkthrough.d`](../examples/dev_lifecycle_walkthrough.d)
runs all 11 stages against a 4-node graph coloring problem. Build it with:

```bash
ldc2 -i examples/dev_lifecycle_walkthrough.d source/reify/package.d \
    source/reify/errors.d source/reify/model.d source/reify/compiler.d \
    source/reify/formula.d source/reify/dimacs.d source/reify/opb.d \
    source/reify/result.d source/reify/backend.d source/reify/transport.d \
    source/reify/diagnostics.d source/reify/router.d source/reify/app.d \
    source/reify/document.d source/reify/builders.d source/reify/spacetime.d \
    source/reify/exports.d source/reify/explain.d \
    -Isource -of=build/dev-lifecycle-walkthrough
```

Run without a key to see stages 1–6; with `NAVOKOJ_API_KEY` set, stages
7–11 execute live against the Navokoj backend.