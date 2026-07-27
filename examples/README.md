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
| Ramsey | [`ramsey.d`](ramsey.d) | Color every graph edge while forbidding monochromatic cliques |

Build the three D examples together with the compiler sources:

```bash
ldc2 examples/graph_coloring.d source/reify/*.d -Isource -of=build/graph-coloring-app
ldc2 examples/scheduling.d source/reify/*.d -Isource -of=build/scheduling-app
ldc2 examples/ramsey.d source/reify/*.d -Isource -of=build/ramsey-app
```

The examples are intentionally small. Interns should add input-driven builders,
capacity and time-window constraints, and independent domain checkers before
using them as benchmark claims.
