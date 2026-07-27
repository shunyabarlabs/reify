# Solver examples

Each example uses the same Navokoj pipeline: define decisions, add hard rules
and preferences, compile, solve, hydrate, and verify.

| Problem | Example | What it teaches |
|---|---|---|
| SAT | [`pigeonhole-3-2.cnf`](pigeonhole-3-2.cnf) | Exact hard-clause satisfiability and DIMACS ingestion |
| MaxSAT | [`service-selection.json`](service-selection.json) | Hard implications plus weighted preferences |
| TSP | [`vehicle_routing.d`](vehicle_routing.d) | One vehicle, one tour, distance minimization |
| VRP | [`vehicle_routing.d`](vehicle_routing.d) | Routing decisions are the starting point for capacity/time-window extensions |
| Graph Coloring | [`graph_coloring.d`](graph_coloring.d) | One-hot color decisions and edge inequality |
| Scheduling | [`scheduling.d`](scheduling.d) | Assignment variables, coverage, and non-overlap rules |
| SpaceTime scheduling | [`spacetime_surgery.d`](spacetime_surgery.d) | Typed dimensions, temporal recipes, WCNF export, and verification provenance |
| SpaceTime API solve | [`spacetime_surgery_api.d`](spacetime_surgery_api.d) | Sends the typed SpaceTime model through the real Navokoj API and locally verifies the response |
| List coloring | [`list_coloring.d`](list_coloring.d) | List-restricted vertex/color relation with exactly-one and edge inequality constraints |
| Hard SpaceTime benchmark | [`spacetime_exam_timetabling.d`](spacetime_exam_timetabling.d) | Exam × room × slot list-coloring with availability, conflicts, capacity, and soft preferences |
| Data Center Placement | [`hard_benchmark_cnf.d`](hard_benchmark_cnf.d) | Categorical placement, channeling, AMK capacity, and WCNF preferences — 24 workloads across 8 servers in 4 fault domains |
| Ramsey | [`ramsey.d`](ramsey.d) | Color every graph edge while forbidding monochromatic cliques |
| Lifecycle walkthrough | [`dev_lifecycle_walkthrough.d`](dev_lifecycle_walkthrough.d) | Exercises every SDK stage (author → build → validate → compile → analyze → configure → solve → inspect → explain → present → diagnose) on a small graph coloring. Pairs with [`docs/DEVELOPER.md`](../docs/DEVELOPER.md). |

Build the D examples together with the compiler sources:

```bash
ldc2 examples/graph_coloring.d source/reify/*.d -Isource -of=build/graph-coloring-app
ldc2 examples/scheduling.d source/reify/*.d -Isource -of=build/scheduling-app
ldc2 examples/ramsey.d source/reify/*.d -Isource -of=build/ramsey-app
```

The data center benchmark calls the Navokoj backend directly via `app.solve()`,
so it pulls in `reify.navokoj.client` (a sub-module) and needs the `-i` flag
for transitive import resolution plus an API key in the environment:

```bash
ldc2 -i examples/hard_benchmark_cnf.d source/reify/package.d \
    source/reify/errors.d source/reify/model.d source/reify/compiler.d \
    source/reify/formula.d source/reify/dimacs.d source/reify/opb.d \
    source/reify/result.d source/reify/backend.d source/reify/transport.d \
    source/reify/diagnostics.d source/reify/router.d source/reify/app.d \
    source/reify/document.d source/reify/builders.d source/reify/spacetime.d \
    source/reify/exports.d source/reify/explain.d \
    -Isource -of=build/hard-benchmark-cnf

export NAVOKOJ_API_KEY=$(cat .public_api_key)
./build/hard-benchmark-cnf
```

The examples are intentionally small. Interns should add input-driven builders,
capacity and time-window constraints, and independent domain checkers before
using them as benchmark claims.

---

### Reify: Technical Introduction

Reify is a D SDK and compiler that turns a declarative decision model into a solver artifact. You declare variables, constraints, and preferences once. The compiler lowers to CNF/WCNF/Hybrid CNF+XOR/Q-State/OPB, selects a backend via `router.d`, queries `/v1/capabilities` for tier limits, dispatches, hydrates assignments, and locally re-verifies all hard constraints before returning.

The SDK is `import reify;`. Backend execution is pluggable via `SolverBackend` and `SolverResponseParser`. The reference backend is `NavokojBackend`.

#### Example: Data Center Workload Placement — 24 workloads, 8 servers, 4 fault domains

This example is `examples/hard_benchmark_cnf.d`. 155 LoC, down from 325 LoC after migrating from raw clause APIs to the high-level surface. It models realistic placement: anti-affinity, co-location, HA fault-domain isolation, capacity, conditional, affinity, and revenue-weighted tier preferences.

Full source is in the repo. Key patterns:

**1. Categorical placement with automatic ALO+AMO**
Each workload picks exactly one server. No manual at-most-one encoding.

```d
CategoryExpr[24] place;
foreach (i; 0.. N)
    place[i] = model.categoricalVar(format("place[%s]", wk[i]), servers);
```

`categoricalVar` guarantees exactly-one server. The compiler emits one-hot with verified ALO+AMO, not user-written clauses.

**2. Channeling for capacity only where needed**
Boolean indicators are needed only for capacity `≤6/server`, which genuinely requires clause-level AMK. Channeling is explicit via `equivalent()`:

```d
on[i][s] = model.booleanVar(...);
model.require(..., equivalent(on[i][s], place[i].equals(servers[s])));
```

**3. Hard constraints via high-level relations**

```d
place[a].different(place[b]) // anti-affinity, separation
place[6].same(place[4]) // co-location
~(waOnRack & wbOnRack) // HA isolation: no two in HA group share rack
implies(place[22].onRackD, place[21].onRackD)
```

HA isolation expands to pairwise rack exclusions. No manual `-1 2 0` DIMACS. Intent is preserved in `LogicalPlan` for `explainPlan()`.

Capacity uses `requireClause` — the one place it's justified:

```d
// sliding-window AMK ≤6
foreach (s; 0..S) foreach (start; 0..N-6) {
    BoolExpr[] window; foreach (j; start..start+7) window ~= ~on[j][s];
    model.requireClause(format("cap[%s,w%d]", servers[s], start), window);
}
```

**4. Medium and Soft**

```d
model.medium("home[w00,r0]", place[0].equals("s0") | place[0].equals("s1"), 5.0);
model.prefer("aff[w00,w01]", place[0].same(place[1]), 15.0);
model.prefer("reliable", place[0].equals("s0") | place[0].equals("s1"), revenue[0]/2.0);
model.preferClause("diversity", rackLits, 20.0); // big disjunction, needs clause-level
```

`require` = hard, `medium` = penalty, `prefer` = weighted MaxSAT. `preferClause` only for rack diversity disjunction.

#### Compilation and Routing

`reify.compile()` Tseitin-transforms non-clause AST nodes, order-encodes bounded ints, preserves native XOR when `preferNativeParity` allows, and routes via `router.d` based on topology — categorical+all-different → qstate, massive CNF → SUTRA C micro-kernel, heavy WCNF → Nitro Riemannian MaxSAT, hybrid XOR → hybrid with Gaussian elimination.

For this model: 24 categoricals → 192 booleans + channeling, 403 hard clauses after Tseitin, weighted WCNF for 25 softs. Router selects `nitro` CPU Native (SUTRA) — `<100k` clauses, low-latency path.

#### Result

```
Solve Time: 223 ms
Hard: 403 / 403 (0 violations) — locally re-verified in result.d
Medium Violated: 12 (rack-home preferences)
Soft Violated: 13 (affinity/revenue trade-offs)
Satisfaction: 99.95%
```

Placement:
```
Rack-A (s0,s1): w01, w08, w09, w11, w12, w16, w20, w21 → 8 workloads
Rack-B (s2,s3): w03, w04, w05, w06, w15, w17 → 6 (w04+w06 co-located ✓)
Rack-C (s4,s5): w02, w10, w14, w18, w19, w22 → 6
Rack-D (s6,s7): w00, w07, w13, w23 → 4
```

Verification: HA isolation ✓, anti-affinity `[0][3],[6][11],[12][23],[7][18]` ✓, co-location w04↔w06 ✓, separation w02↔w18 ✓, capacity ≤6/server ✓, conditional w22→w21 rack-D ✓.

All hard constraints are re-verified locally against the original `Model` — solver output is not trusted. `ExecutionTrace` contains `selectedEngine`, `solveTimeMs`, billing, and routing.

This is the high-level surface: `categoricalVar`, `.same()/.different()/.equals()`, `implies`, `equivalent`, `require/prefer/medium`. `requireClause/preferClause` exist only for AMK capacity and large disjunctions where clause-level is genuinely required.
