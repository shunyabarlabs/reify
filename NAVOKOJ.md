# Why Navokoj?

Navokoj is the constraint-solving runtime that ships behind `Reify` as the
reference `SolverBackend`. It is what powers the `/v1/solve` calls that the
Reify CLI submits when you run `reify solve`. This page is the blunt answer
to the question: *why would anyone use it instead of OR-Tools, Gurobi, or
Z3?*

Short version: it is an anytime completion monster with a streaming
architecture the others don't have. That changes what software you can build
on top of it.

---

## The Latency Moat Is Real

Across 5,140 paired CNF benchmarks on a SUTRA build:

- **3.7 ms median latency** (vs 23.9 ms for the open-source V3 streaming
  engine running on the same corpus).
- **4,633 complete SAT assignments** out of 5,140 — a **90.1% complete-SAT
  rate**, meaning 9 out of 10 instances close with a 100% satisfying
  assignment, not a 99.9% "best effort."
- **263× faster than OR-Tools CP-SAT** on planted 3-SAT
  (31 ms vs 8.15 s).
- **40.5× faster** on list coloring.
- **>322× time-to-feasible** on Random 4-SAT and 1000×10 list coloring,
  where CP-SAT returned `UNKNOWN` after 10 s while SUTRA returned a verified
  SAT assignment in milliseconds.

That is not "a heuristic that gets stuck at 99%." That is an anytime
completion engine that actually closes the instance 90.1% of the time, at
local-search latencies. The two were supposed to be a tradeoff. Navokoj
breaks the tradeoff.

---

## The Scale Moat Is Disgusting

Enterprise constraint models do not stay at 10K clauses. They grow to
10M–100M+ once you encode a real hospital, logistics network, or cloud
region. At that scale traditional CDCL solvers OOM and die.

NitroSAT V3 was built for exactly this regime:

- **116,161,300 clauses solved in 4m48s** on **10.7 MiB of peak RSS**.
- **37.44M-clause streaming timetable solved in ~34s**.
- The v2→v3 leap moved from NAdam to WAdam (Wasserstein-Flow), taking an
  80M-clause enterprise timetable from 5.2 hours down to **73 seconds**
  (a **250× speedup**).

The trick: V3 converts CNF to a binary stream and scans it. State stays
bounded. You trade a little raw in-memory speed for the ability to actually
finish the job. Traditional CDCL cannot do this; it has to hold the whole
clause set in RAM and explore it.

---

## Why This Matters Product-Wise

OR-Tools is a batch job. You click "Optimize," a spinner appears, you wait
8–30 seconds (or minutes), and you get an answer once a day.

SUTRA at 3.7 ms is a different category. It lets you put constraint solving
**on the UI request path**:

- A dispatcher drags a truck to a new route, and the UI instantly
  recalculates the 50 violated constraints and repairs them in real time.
- A nurse swaps a shift, and the system instantly confirms whether it
  violates a labor law.
- A planner accepts an emergency order, and the screen says *yes/no/why*
  before the click resolves.

You are not selling "better math." You are selling **Google Docs-level
interactivity for enterprise planning**. That is a UX paradigm shift, not
a benchmark delta.

---

## The Honest Bear Case (and Why It Doesn't Matter)

Navokoj is not a universal formal-proof generator:

1. **Exact UNSAT classification.** SUTRA plateaus at ~99.9% on truly
   unsatisfiable instances. CP-SAT or Z3 will formally prove UNSAT in
   milliseconds.
2. **Heavy XOR / parity reasoning.** Random XOR, Tseitin-encoded parity
   formulas — CP-SAT's home turf.
3. **Extreme expander graphs.** At 100K+ vars with high expansion, Navokoj
   caps near 90% satisfaction.

This is exactly *why* the Reify architecture exists. `reify.router`
classifies the topology and routes:

- **SUTRA / NitroSAT** for the 90.1% interactive-feasibility regime.
- **H100 GPU anytime** for heavy WCNF / soft-constraint instances.
- **Hybrid Gaussian elimination** for XOR-heavy formulas.
- **A future `ORToolsBackend` or `Z3Backend`** for the small slice where a
   formal UNSAT proof is actually required for compliance.

The user writes `import reify;` once. They never need to know which engine
fired. That is the entire point of the abstraction.

---

## TL;DR

Navokoj is the engine that lets Reify turn optimization from a nightly
batch job into a real-time UX primitive. That is the wedge, that is the
moat, and that is why it exists beneath the compiler instead of competing
with it.

See `source/reify/router.d` for the topology-driven engine selection and
`source/reify/navokoj/` for the wire-protocol adapter.
