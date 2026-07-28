# Navokoj — The Engine Behind Reify

Navokoj is the constraint-solving runtime that powers Reify. When you run `reify solve`, Navokoj is what does the heavy lifting. This doc explains what makes it different and why it enables real-time decision making.

---

## Speed That Changes What You Can Build

Navokoj solves constraints in milliseconds — not seconds or minutes. That shifts decision-making from a nightly batch job to something that happens in the UI, in real time.

- **3.7 ms median latency** on standard problems
- **90%+ complete-SAT rate** — most problems return a full satisfying assignment
- Scales to **100M+ clauses** for enterprise-sized problems

What does this mean in practice?

- A dispatcher drags a truck to a new route → the UI instantly recalculates and repairs the schedule
- A nurse swaps a shift → the system instantly confirms it works or explains why it doesn't
- A planner accepts an emergency order → the screen says *yes/no/why* before the click releases

---

## Built for Scale

Enterprise problems grow. A model that starts with 10K constraints becomes 10M once you model a real hospital, logistics network, or cloud region. Navokoj handles this:

- **116M clauses solved in under 5 minutes** with low memory footprint
- **Streaming architecture** — doesn't need to hold the entire problem in RAM
- **H100 GPU** for weighted optimization (WCNF), **CPU** for low-latency interactive use

---

## How Reify Uses Navokoj

Reify's router picks the right engine automatically:

| Problem | Navokoj Engine |
| :--- | :--- |
| Categorical / assignment | Q-State (GPU) |
| Large CNF | SUTRA (CPU) |
| Weighted / soft constraints | Nitro (GPU H100) |
| Parity-heavy | Hybrid (GPU) |

You write `import reify;` once. Reify handles the rest.

---

## Limitations (Honest)

Navokoj optimizes for *interactive completion* — finding a good answer fast. For the rare case where formal UNSAT proof is required (regulatory compliance, formal verification), Reify's architecture supports plugging in other backends. The router will route there automatically when appropriate.

---

## TL;DR

Navokoj turns optimization from a batch job into a real-time UX primitive. That's the capability Reify exposes — and why they work together.

See [`source/reify/router.d`](source/reify/router.d) for routing logic and [`source/reify/navokoj/`](source/reify/navokoj/) for the wire protocol.
