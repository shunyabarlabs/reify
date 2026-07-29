# Reify

[![Dub version](https://img.shields.io/dub/v/reify.svg)](https://code.dlang.org/packages/reify)
[![Dub downloads](https://img.shields.io/dub/dt/reify.svg)](https://code.dlang.org/packages/reify)

![img](reify.png)

Reify is a declarative D SDK and compiler that turns what you *want* into a solved decision, automatically.

You describe the problem: "allocate acres to wheat, chickpeas, and rice", "schedule nurses across shifts", "place workloads on servers". Reify compiles that description into a solver, finds the best answer, verifies it, and gives you the result.

---

## Install

```bash
dub add reify
```

Or build from source:

```bash
ldc2 -i -Isource source/app.d -of=build/reify
```

---

## Quickstart

Describe what you want, get the best answer:

```d
import reify;

auto app = decisionApp("crop-allocation", (Model model) {
    auto crops = ["wheat", "chickpea", "rice"];
    auto acres = model.integerVars("acres", 0, 100, crops);

    // Hard rule: total acres cannot exceed 100
    model.require("field capacity",
        sumExpr(acres["wheat"], acres["chickpea"], acres["rice"]) <= 100);

    // Objective: maximize profit
    model.maximize("profit",
        30 * acres["wheat"] +
        22 * acres["chickpea"] +
        18 * acres["rice"]);
});

app.run(args);
```

That's it. No CNF. No solvers. No jargon. Just declare what you need.

---

## Why Reify?

**Write what you mean, not how to solve it.**

| Without Reify | With Reify |
| :--- | :--- |
| Write 500+ lines of clause encoding | 15 lines of declarative rules |
| Manually pick a solver | Auto-routed to best engine |
| Cross-check the answer yourself | Locally verified before return |
| Hardcode one solver forever | Swap backends without changing your model |

Reify handles the translation to solver formats (CNF, WCNF, OPB), picks the right engine based on your problem shape, runs it, maps the numbers back to names, and double-checks every constraint before giving you the answer.

---

## What You Can Model

- **Allocation**: Which server for which workload? Which acre for which crop?
- **Scheduling**: Which nurse for which shift? Which exam in which room?
- **Routing**: Which truck takes which route? What's the shortest path?
- **Planning**: Sequential tasks with durations, resources, and deadlines

Example problems in [`examples/`](examples/): crop allocation, nurse scheduling, vehicle routing, graph coloring, exam timetabling, Sudoku, data center placement, and more.

---

## CLI Commands

```bash
# Check what's possible with your account
reify capabilities

# Validate a model (local, no API call)
reify validate --input examples/json/crop-allocation.json

# See what the compiler produces
reify compile --input examples/json/crop-allocation.json

# Solve and get the answer
reify solve --input examples/json/crop-allocation.json --timeout 10

# Debug why a solution works
reify diagnose --input examples/json/crop-allocation.json
```

---

## More

- [Engineer's Guide](docs/ENGINEERING.md) — architecture, CLI reference, glossary
- [Examples](examples/) — full working models
- [Blog](https://open.substack.com/pub/shunyabarlabs/p/we-shipped-reify-the-decision-compiler) — the story behind Reify

---

## License

Boost Software License 1.0 — see [LICENSE](LICENSE).

ShunyaBar Labs.

![img](cta.png)