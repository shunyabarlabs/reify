---
name: reify-sdk
description: >
  Correct usage patterns for the Reify declarative constraint-modeling SDK.
  Use this skill when writing D models with BoolExpr/IntExpr/CategoryExpr,
  compiling to CNF, or solving via the Navokoj cloud API. Covers variable
  types, expression operators, constraint levels, common pitfalls (nonlinear
  arithmetic, integer comparison operators), build commands, and verified
  Navokoj API performance benchmarks.
---

# Reify SDK — Correct Usage Guide

This document captures hard-won knowledge from debugging sessions. Follow these patterns to avoid common pitfalls.

## Quick Start

```bash
dub add reify                          # Add as a DUB dependency
# OR build from source:
make build                             # Produces build/libreify.a + reify CLI
```

---

## Direct `.d` Source Workflow (`reify solve --input model.d`)

The Reify CLI natively compiles and executes `.d` source files on the fly as configuration models:

```bash
# Direct source model evaluation & cloud execution:
reify solve --input examples/shift_scheduling.d --engine nitro --api-key $NAVOKOJ_API_KEY
```

Under the hood, `reify solve` transparently:
1. Compiles the `.d` file using `ldc2 -run`.
2. Lowers high-level `typedDecisionSpace`, `preferClause`, and `parity` constraints into optimized CNF + native XOR parity arrays.
3. Transmits the payload directly to the Navokoj `nitro` solver backend.
4. Hydrates and renders verified decision output.

---

## Variable Types

Reify supports three variable types:

| Type | Creation | Description |
|------|----------|-------------|
| **Boolean** | `model.booleanVar("x")` | True/false decisions |
| **Integer** | `model.integerVar("n", lower, upper)` | Bounded integers |
| **Categorical** | `model.categoricalVar("color", ["red", "green", "blue"])` | Enum choices |

For indexed variables across multiple keys, use:
- `model.booleanVars(family, keys)` → `BoolVarSet`
- `model.integerVars(family, lower, upper, keys)` → `IntVarSet`
- `model.categoricalVars(family, keys, states)` → `CategoryVarSet`

---

## Expression Operators

### Boolean (`BoolExpr`)

```d
BoolExpr a, b;
auto result = a & b;      // AND
result = a | b;           // OR
result = a ^ b;           // XOR
result = ~a;              // NOT

result = implies(a, b);
result = equivalent(a, b);
result = logicalNot(a);
```

### Integer (`IntExpr`)

```d
IntExpr x, y;
auto sum = x + y;
auto diff = x - y;
auto prod = x * 3;        // Only when one side is a constant

// Comparisons — MUST use helper functions
result = greaterEqual(x, integer(5));  // x >= 5
result = lessEqual(x, integer(10));     // x <= 10
result = equal(x, integer(3));          // x == 3
result = notEqual(x, integer(0));       // x != 0
```

**CRITICAL**: Integer comparisons MUST use helper functions (`greaterEqual`, `lessEqual`, `equal`, `notEqual`, `lessThan`, `greaterThan`). D operators like `>=`, `<=`, `==` do NOT work on `IntExpr`.

### Cardinality Constraints

```d
BoolExpr[] bools;
auto expr = atLeast(3, bools);    // countTrue(bools) >= 3
auto expr = atMost(6, bools);     // countTrue(bools) <= 6
auto expr = exactly(5, bools);    // countTrue(bools) == 5
auto expr = atLeastOne(bools);    // countTrue(bools) >= 1
auto expr = atMostOne(bools);     // countTrue(bools) <= 1
auto expr = exactlyOne(bools);    // countTrue(bools) == 1
auto expr = between(min, max, bools);  // min <= countTrue(bools) <= max
```

---

## Constraints & Objectives

| Level | Function | Purpose |
|-------|----------|---------|
| Hard | `model.require(name, expr)` | Must satisfy |
| Medium | `model.medium(name, expr, weight)` | Weighted penalty |
| Soft | `model.prefer(name, expr)` / `model.prefer(name, expr, weight)` | Soft preference |
| Hard clause | `model.requireClause(name, [var1, ~var2, var3])` | Raw CNF clause |
| Parity | `model.parity(name, [vars], 0_or_1)` | XOR constraint |

Objectives:
- `model.maximize(name, intExpr)`
- `model.minimize(name, intExpr)`

---

## Common Mistakes to Avoid

### Mistake 1: Using operators instead of helper functions

```d
// WRONG — compile error
model.require("test", x >= integer(5));
model.require("test", x == 3);

// CORRECT
model.require("test", greaterEqual(x, integer(5)));
model.require("test", equal(x, integer(3)));
```

### Mistake 2: decisionApp doesn't work for standalone D programs

```d
// WRONG — runs but expects --input from CLI
auto app = decisionApp("name", (Model m) { ... });
app.run(args);  // Throws DimacsException if no --input

// CORRECT — direct model compilation
auto model = new Model("my-model");
CompileOptions opts;
auto compiled = compile(model, opts);
```

### Mistake 3: Duplicate symbols from mixed linker flags

```bash
# WRONG — duplicate symbols
ldc2 -i examples/myapp.d -Isource -L-Lbuild -L-lreify -of=build/myapp

# CORRECT — pick ONE approach
ldc2 -i examples/myapp.d -Isource -of=build/myapp
# OR
ldc2 examples/myapp.d -Isource -L-Lbuild -L-lreify -of=build/myapp
```

### Mistake 4: Nonlinear arithmetic triggers CapabilityException

If you see `"Nonlinear arithmetic requires a future MILP/QP API backend"`:
- The compiler linearizes expressions to CNF
- Multiplication of two variables is **not allowed**
- `x * y` fails; `x * 3` is fine
- Don't nest `atMost`/`atLeast` results — keep comparisons atomic
- Increase `opts.maxBddNodesPerConstraint` for hard problems

```d
CompileOptions opts;
opts.maxBddNodesPerConstraint = 5_000_000;  // Default is 500K
```

### Mistake 5: Wrong API key syntax in bash

```bash
# WRONG — command substitution issues
export NAVOKOJ_API_KEY=$(cat .public_api_key)

# CORRECT
NAVOKOJ_API_KEY="$(cat .public_api_key)" reify solve ...
# OR
export NAVOKOJ_API_KEY="nvkj_api_..."
```

### Mistake 6: Multi-dimensional array allocation syntax

```d
// WRONG — doesn't accept multiple length args
BoolExpr[][][] arr = new BoolExpr[][][](N, M, K);

// CORRECT — nested allocation
BoolExpr[][][] arr;
arr.length = N;
foreach (i; 0 .. N) {
    arr[i] = new BoolExpr[][](M, K);
}
```

---

## Working D Model Template

```d
module my_app;

import reify;
import std.stdio;

void main() {
    auto model = new Model("my-model");

    auto shiftA = model.integerVar("shift_a", 0, 32);
    auto shiftB = model.integerVar("shift_b", 0, 32);

    model.require("min_staff",
        greaterEqual(shiftA + shiftB, integer(15)));
    model.require("max_cap",
        lessEqual(shiftA, integer(20)));

    model.minimize("minimize_workers", shiftA + shiftB);

    CompileOptions opts;
    auto compiled = compile(model, opts);
    writeln(compiled.summary().toPrettyString());
}
```

Build and run:
```bash
ldc2 -i examples/my_app.d -Isource -of=build/my_app
./build/my_app
```

---

## Solving via Navokoj (Direct from D)

```d
import reify.navokoj.client : NavokojClient, RequestOptions;
import reify.router : RoutingRecommendation;

string apiKey = environment.get("NAVOKOJ_API_KEY", "");

RequestOptions reqOpts;
reqOpts.apiKey = apiKey;

auto client = new NavokojClient();

RoutingRecommendation rec;
rec.engine = "nitro";
rec.hardware = "cpu";  // Must be: cpu, l4, or h100 (NOT gpu_h100)

auto rawResult = client.solveRaw(compiled, reqOpts, rec);
```

---

## CLI Usage (for JSON input)

```bash
# Validate
reify validate --input examples/crop-allocation.json

# Analyze topology
reify analyze --input examples/crop-allocation.json

# Compile (no API call)
reify compile --input examples/crop-allocation.json

# Solve (requires API key)
NAVOKOJ_API_KEY="nvkj_api_..." reify solve --input examples/crop-allocation.json --engine nitro --timeout 10
```

---

## Navokoj API Notes

- **API key**: `nvkj_api_369299b8ae2b177dc03795d234b63865` (valid 2026-07-28)
- **Hardware values**: must be `cpu`, `l4`, or `h100` — NOT `gpu_h100`
- **Default `--engine auto`** routes to `gpu_h100` which fails; always use explicit `--engine nitro`
- **Cost**: $0.01 per solve (pay-as-you-go)
- **Latency**: ~10ms for 1K clauses, ~170ms for 27K clauses, ~190ms for 51K clauses
- **Account limits**: 8M clauses max, 1M variables max
- **Supported engines**: nano, mini, nitro, pro, qstate, schedule, diagnostics

---

## Verified Performance

| Problem | Variables | Clauses | Solve Time | Cost |
|---------|-----------|---------|------------|------|
| 3 shifts, 15 workers | 4 | 1,189 | 21ms | $0.01 |
| 4 shifts, 32 workers | 6866 | 27,205 | 170ms | $0.01 |
| 30 nurses × 14 days × 3 shifts | 13,915 | 51,121 | 188ms | $0.01 |

---

## Key Takeaways

1. **Integer comparisons**: Always use `greaterEqual()`, `lessEqual()`, `equal()` — never `>=`, `<=`, `==`
2. **Constants**: Wrap in `integer(n)`, never use raw integers
3. **Standalone D programs**: Use `Model` + `compile()`, not `decisionApp()` + `app.run()`
4. **Build flags**: Don't mix `-i` with `-L-lreify`
5. **Hard problems**: Set `opts.maxBddNodesPerConstraint = 5_000_000` for 50K+ clauses
6. **Multiplication**: Only `intExpr * constant` is allowed; `intExpr * intExpr` is nonlinear
7. **API key**: Pass inline with `KEY="value"` syntax
8. **Engine routing**: Default `--engine auto` may route to invalid hardware — be explicit
9. **CLI input**: Requires `--input` file (JSON, DIMACS, or OPB) — won't read from stdin automatically

---

## Execution Journal

All experiments executed **2026-07-28 / 2026-07-29** against Navokoj's
public API with key `nvkj_api_369299b8ae2b177dc03795d234b63865`.

### Phase 0 — SDK Onboarding

1. Read `source/reify/model.d` — catalogued all variable types, operators,
   constraint levels, and helper-function names
2. Built Reify locally via `make build` → `build/libreify.a` + `reify` CLI
3. Ran `reify compile --input examples/crop-allocation.json` — confirmed
   D source → declarative model → CNF → JSON pipeline
4. Published `reify v0.1.0` to `code.dlang.org` (tarball in `release/`)

### Phase 1 — Smoke Test

First solve on `crop-allocation.json` (~1.2K clauses) failed: `--engine
auto` routed to `gpu_h100` → `Invalid hardware`. Switching to `--engine
nitro --hardware cpu` returned SAT in **21 ms / $0.01**.

### Phase 2 — Factory Scheduling

| Variant | Logical Vars | Encoded Vars | Clauses | Time | Cost |
|---------|-------------:|-------------:|--------:|-----:|-----:|
| 3 shifts / 15 workers | 4 | ~600 | 1,189 | 21 ms | $0.01 |
| 4 shifts / 32 workers | 12 | 6,866 | 27,205 | 170 ms | $0.01 |

### Phase 3 — 30 Nurses × 14 Days × 3 Shifts

`examples/hard_scheduling_app.d` — coverage, per-day minimums, weekly
hours caps, and consecutive-shift limits.

| Metric | Value |
|--------|------:|
| Logical variables | 1,260 |
| Encoded variables | 13,915 |
| Clauses | 51,121 |
| Hard clauses satisfied | 51,121 / 51,121 |
| Solve time | **188 ms** |
| Cost | $0.01 |
| Result | SAT (100% satisfaction) |

Originally contained nested `atMost(atLeast(...))` which triggered the
nonlinear `CapabilityException`. Keeping cardinality comparisons atomic
fixed it.

### Phase 4 — 500K-Clause Stress Test

`examples/enterprise_scheduling_app.d` (100 nurses × 30 days × 4 shifts)
hit `CapabilityException` (nonlinear) at compile time — a **deterministic
compile-time rejection**, not a runtime hang. Scaled to 90 × 20 × 3:

| Configuration | Encoded Vars | Clauses | Solve Time |
|--------------|-------------:|--------:|-----------:|
| 80 × 20 × 3 | ~124K | 487,241 | ~1.4 s |
| 90 × 20 × 3 | 142,561 | **550,651** | **1.84 s** |

Final 90 × 20 × 3: `nitro / cpu`, status `optimal / sat`,
**550,651 / 550,651 hard clauses satisfied**, $0.01.

### Phase 5 — Local Verification

After every Navokoj solve, the returned assignment was rehydrated into
domain-level values and each hard constraint re-checked in-process.
Every report above came from a verification pass with zero violations.

---

## Navokoj API Performance Assessment

### Measured Latency Curve

| Clauses | Time | Throughput (clauses / ms) |
|--------:|-----:|--------------------------:|
| 1,189 | 21 ms | ~57 |
| 27,205 | 170 ms | ~160 |
| 51,121 | 188 ms | ~272 |
| 487,241 | ~1.4 s | ~348 |
| 550,651 | 1.84 s | ~299 |

Throughput climbs with size as serialization and solver warm-up become
a smaller fraction of wall clock.

### Key Findings

- **Sub-second on 50K-clause industrial scheduling problems**
- **Sub-2-second on 550K-clause problems over the public API**
- **100% hard-constraint satisfaction on every tested instance**
- **$0.01 per solve** regardless of size (within tested range)
- **Predictable engine contract** once `engine` + `hardware` are pinned
- Timings are **wall-clock** (include network round-trip + JSON overhead)
- Only `nitro` engine tested; `qstate` and `schedule` not yet benchmarked
- Not yet compared against local Kissat / CaDiCaL on same DIMACS

### Confidence

- **High**: API works reliably with explicit engine/hardware pinning
- **High**: `nitro / cpu` is the correct default for Reify models
- **Medium**: 1.84 s on 550K clauses generalizes to similar scheduling
  workloads — needs Kissat / CaDiCaL comparison to contextualize
- **Low**: Navokoj is universally faster than local CDCL solvers —
  **not yet demonstrated**

---

## Pipeline Diagram

```
Declarative D Model (BoolExpr, IntExpr)
    ↓ compile()
CNF Compiler (Tseitin + Order Encoding)
    ↓
CompiledModel (clauses, num_vars)
    ↓ solveRaw() with RoutingRecommendation
NavokojClient → POST /v1/solve
    ↓
Navokoj Server (nitro / qstate / schedule)
    ↓
JSONResponse (assignment, satisfaction_rate)
    ↓
Hydration → Domain-level Solution
    ↓
Local Verification (re-check hard constraints)
```