# Solver examples

Each example uses the same Navokoj pipeline: define decisions, add hard rules
and preferences, compile, solve, hydrate, and verify.

| Problem / Benchmark Domain | Example File | Logical Vars | Encoded CNF Vars | Total CNF Clauses | Hard Satisfied | Feasibility | Key Feature Demonstrated |
|---|---|:---:|:---:|:---:|:---:|:---:|---|
| **Nurse Shift Roster** | [`shift_scheduling.d`](d/shift_scheduling.d) | 168 | 476 | **1,481** | **238 / 238** | **Feasible** | Native GF(2) XOR parity crew rotation + Direct `.d` CLI |
| **Quantum Qubit Routing** | [`quantum_qubit_routing.d`](d/quantum_qubit_routing.d) | 270 | 1,051 | **4,180** | **858 / 858** | **Feasible** | 2D spatial bijectivity, hardware gate adjacency, crosstalk avoidance |
| **Food Delivery VRPTW** | [`food_delivery_vrptw.d`](d/food_delivery_vrptw.d) | 16 | 12,374 | **48,890** | **84 / 84** | **Feasible** | Vehicle routing, interval overlap bounds, integer time windows |
| **Package Dependency Extreme** | [`package_dependency_extreme.d`](d/package_dependency_extreme.d) | 200 | 598 | **2,188** | **180 / 180** | **Feasible** | 40-package 5-level semver DAG, conflict exclusions & XOR audit |
| **Package Resolver 140-Pkg** | [`package_dependency_140pkg.d`](d/package_dependency_140pkg.d) | 1,120 | 3,350 | **18,624** | **8,709** | Anytime Partial | 140-package 8-level deep semver DAG, cross-conflicts & parity |
| **Nurse WCNF Roster** | [`nurse_wcnf_scheduling.d`](d/nurse_wcnf_scheduling.d) | 630 | 8,269 | **32,458** | **645 / 687** | Anytime Partial | WCNF soft preference optimization with 30-day shift constraints |
| **Factory 4-Shift Schedule** | [`factory_4shift_app.d`](d/factory_4shift_app.d) | 384 | 6,866 | **27,205** | **600 / 600** | **Feasible** | Scaled Order Encoding for multi-shift industrial labor laws |
| **Job Shop Scheduling** | [`jobshop_extreme.d`](d/jobshop_extreme.d) | 960 | 18,020 | **79,518** | **1,920 / 1,920** | **Feasible** | Multi-resource machine precedence & non-overlapping jobs |
| **Data Center Placement** | [`hard_benchmark_cnf.d`](d/hard_benchmark_cnf.d) | 192 | 403 | **403** | **403 / 403** | **Feasible** | Categorical placement, HA fault-domain isolation, AMK capacity |
| **Hospital Surgery Scheduling** | [`hospital_surgery_scheduling.d`](d/hospital_surgery_scheduling.d) | 138 | 138 | **138** | **138 / 138** | **Feasible** | OR room allocation with surgeon availability & equipment rules |
| **Fleet Routing** | [`fleet_routing.d`](d/fleet_routing.d) | 60 | 60 | **128** | **128 / 128** | **Feasible** | Multi-vehicle tour routing with depot return constraints |
| **Satellite Orbital Dispatch** | [`satellite_orbital_dispatch.d`](d/satellite_orbital_dispatch.d) | 48 | 25,043 | **100,104** | **99 / 99** | **Feasible** | 12-tick orbital battery SoC, SSD buffer, thermal non-overlap & science yield |
| **EV Fleet Grid Dispatch** | [`ev_fleet_grid_dispatch.d`](d/ev_fleet_grid_dispatch.d) | 1,152 | 7,117 | **24,181** | **23,989 / 23,989** | **Feasible** | 24-hr EV fleet ToU tariff, charger hardware concurrency, solar PV & battery protection |
| **5G Edge VNF Slice Placement** | [`5g_slice_vnf_placement.d`](d/5g_slice_vnf_placement.d) | 448 | 1,121 | **14,821** | **14,789 / 14,789** | **Feasible** | URLLC/eMBB/mMTC slice DAG chains, GPU hardware affinity & regional HA anti-affinity |
| **5G VNF Placement 10x Extreme** | [`5g_slice_vnf_placement_10x.d`](d/5g_slice_vnf_placement_10x.d) | **22,400** | **229,941** | **832,121** | **832,121 / 832,121** | **Optimal** | 160 MEC nodes, 16 regions, 40 slices, 140 VNF chains, 100% SAT in 2.76s |
| **DNA Oligo Barcode Assembly** | [`dna_barcode_assembly.d`](d/dna_barcode_assembly.d) | 64 | 2,525 | **11,777** | **9,990 / 9,990** | **Feasible** | Next-Gen Sequencing 8-mer DNA multiplex tags, Hamming distance $\ge 3$, GC-content & hairpin exclusion |
| **Nuclear Fusion Tokamak Dispatch** | [`fusion_tokamak_sensor_dispatch.d`](d/fusion_tokamak_sensor_dispatch.d) | 1,024 | 4,625 | **13,017** | **100% SAT** | **Feasible** | 100M-Kelvin burning plasma, 16 toroidal sectors, NBI shielding & GF(2) poloidal coil parity balance |
| **Space Debris Laser De-orbit** | [`space_debris_laser_deorbit.d`](d/space_debris_laser_deorbit.d) | 768 | 8,481 | **30,657** | **100% SAT** | **Feasible** | LEO space debris laser ablation, orbital LOS tracking, Kessler conjunction avoidance & GF(2) grid parity |

Build the D examples together with the compiler sources:

```bash
ldc2 examples/d/graph_coloring.d source/reify/*.d -Isource -of=build/graph-coloring-app
ldc2 examples/d/scheduling.d source/reify/*.d -Isource -of=build/scheduling-app
ldc2 examples/d/ramsey.d source/reify/*.d -Isource -of=build/ramsey-app
```

The data center benchmark calls the Navokoj backend directly via `app.solve()`,
so it pulls in `reify.navokoj.client` (a sub-module) and needs the `-i` flag
for transitive import resolution plus an API key in the environment:

```bash
ldc2 -i examples/d/hard_benchmark_cnf.d source/reify/package.d \
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
