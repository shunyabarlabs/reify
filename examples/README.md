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
