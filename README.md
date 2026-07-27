# Reify (`reify`)

**Reify** is a domain-neutral declarative D SDK, decision compiler, and CLI toolchain for high-performance constraint intelligence engines.

In programming language theory, to *reify* is to turn an abstract concept into a concrete, executable object. With **Reify**, a decision model declares symbolic variables, constraints, preferences, and objectives once. The compiler reifies possible problem worlds into concrete solver artifacts (`SolverArtifact`) — automatically selecting an optimal backend representation (CNF, WCNF, Hybrid CNF+XOR, Q-State, or OPB), querying account entitlements, submitting to the backend API or local solver, hydrating returned variable assignments, and locally verifying domain constraints.

Execution is vendor-neutral and extensible: `SolverBackend` owns solver execution, while `SolverResponseParser` owns response decoding. Reify ships with the reference `NavokojBackend` alongside support for OR-Tools, Z3, or custom solver backends without modifying domain models or SpaceTime policy definitions.

---

## Key Features

- **Declarative D SDK**: Clean import surface via `import reify;` (or custom backend extensions)
- **Vendor-Neutral Architecture**: Pluggable `SolverBackend` and `SolverResponseParser` interfaces decouple modeling from target solvers
- **Dynamic Capability Discovery**: Live runtime query of account tier limits (`maxVariables`, `maxClauses`, allowed engines, remaining credits, hardware access)
- **Multi-Format Ingestion & Export**: Direct support for declarative JSON model documents, DIMACS CNF, and linear OPB files or standard input streams
- **Rich Decision Types**: Boolean, categorical (one-hot), and order-encoded bounded-integer decision variables
- **SpaceTime Policy Framework**: Relational temporal projection over decision spaces with composable scheduling policies (`duration`, `within`, `nonOverlapping`, `capacity`) and transparent plan explainability (`explainPlan()`)
- **Automated Backend Routing**: Deterministic selection between Q-State, hybrid CNF+XOR, continuous MaxSAT manifolds, or linear OPB encodings
- **Local Verification & Auditability**: Every returned solver assignment is hydrated and independently verified against original domain constraints before presentation

---

## Developer Quickstart

### 1. Build the CLI Toolchain

Using **LDC2** (recommended):

```bash
# Navigate to the compiler directory
cd compiler

# Build the reify executable
ldc2 source/app.d source/reify/*.d -Isource -of=build/reify
```

Using **Dub**:

```bash
dub build --config=cli
```

### 2. Set Your API Key (Reference Backend)

```bash
export NAVOKOJ_API_KEY="nvkj_your_api_key_here"
```

### 3. Discover Account Entitlements

Query authoritative account limits and engine access:

```bash
# Using the Reify CLI
build/reify capabilities
```

### 4. Reify, Validate, & Solve a Model

Validate model document structure locally without consuming API credits:

```bash
build/reify validate --input examples/crop-allocation.json
```

Inspect compiled backend request payload:

```bash
build/reify compile --input examples/crop-allocation.json
```

Submit, solve, hydrate, and verify locally:

```bash
build/reify solve \
  --input examples/crop-allocation.json \
  --timeout 5
```

---

## API Capability Discovery

Before compiling or submitting large models, client applications can dynamically query account-specific entitlements via the capability discovery layer. This ensures the compiler respects authoritative real-time account policy rather than static assumptions.

### D SDK Capability API

```d
import reify;

void main() {
    auto backend = new NavokojBackend();
    
    // Discover account entitlements
    RequestOptions options;
    options.apiKey = "nvkj_your_api_key_here";
    
    Capabilities caps = backend.capabilities(options);
    
    import std.stdio : writeln;
    writeln("Account Tier: ", caps.tier);
    writeln("Allowed Engines: ", caps.engines);
    writeln("Max Variables: ", caps.maxVariables);
    writeln("Max Clauses: ", caps.maxClauses);
    writeln("Remaining Credits ($): ", caps.remainingCredits);
    writeln("Supports Space-Time: ", caps.supportsSpaceTime);
}
```

### CLI Output Example

```bash
$ build/reify capabilities
Tier: launch_pad
Engines: ["nano", "mini", "nitro", "pro"]
Max Variables: 1,000,000
Max Clauses: 8,000,000
Supports Hard Clause Mask: true
Supports Space-Time: true
Remaining Credits: $199.00
```

---

## D Modeling API

### 1. High-Level Declarative Model

```d
import reify;

auto app = decisionApp(
    "crop-allocation",
    (Model model) {
        auto crops = ["wheat", "chickpea", "rice"];
        auto acres = model.integerVars("acres", 0, 100, crops);

        IntExpr[] planted;
        foreach (crop; crops) {
            planted ~= acres[crop];
        }

        // Hard capacity constraint
        model.require(
            "field capacity",
            lessEqual(sumExpr(planted), integer(100))
        );

        // Linear profit objective
        model.maximize(
            "expected profit",
            30 * acres["wheat"] +
            22 * acres["chickpea"] +
            18 * acres["rice"]
        );
    }
);

int main(string[] args) {
    return app.run(args);
}
```

### 2. SpaceTime Scheduling Policies

```d
import reify;

alias PatientDim  = Dimension!("patient", Patient);
alias DoctorDim   = Dimension!("doctor", Doctor);
alias ActivityDim = Dimension!("activity", Activity);
alias SlotDim     = TimeDimension!("slot", Slot);

auto spaceTime = model
    .spaceTime!(PatientDim, DoctorDim, ActivityDim, SlotDim)("surgery")
    .dimension!PatientDim(patients)
    .dimension!DoctorDim(doctors)
    .dimension!ActivityDim(activities)
    .time!SlotDim(slots)
    .build();

spaceTime.duration!ActivityDim(Activity.preop, 1);
spaceTime.duration!ActivityDim(Activity.surgery, 2);

auto noDoctorCollision = nonOverlapping!DoctorDim().within(timeWindow(workingHours));
auto surgeryPolicy = exactlyOnePer!(PatientDim, ActivityDim)()
    .and(noDoctorCollision)
    .and(capacity(DoctorDim.name, 1))
    .and(prefer!DoctorDim(Doctor.master, 20));

spaceTime.apply(surgeryPolicy);
spaceTime.before("preop", "surgery", "patient");

// Inspect transparent execution and logical plans
auto logicalPlan  = spaceTime.explainPlan();
auto physicalPlan = spaceTime.explainPhysical();
```

### 3. Low-Level CNF Formula Builder

For formula generators and direct SAT encodings:

```d
import reify;

auto formula = new CnfFormula("service-selection");
const gateway  = formula.newVariable("gateway");
const database = formula.newVariable("database");

formula.addClause([-gateway, database], "gateway needs database");
formula.addClause([gateway, database], "keep one entry point available");

auto compiled = formula.compile();
```

---

## Universal Model Document Format

Models can be submitted directly as JSON documents:

```json
{
  "name": "crop-allocation",
  "variables": [
    {"name": "wheat", "type": "integer", "lower": 0, "upper": 100},
    {"name": "chickpea", "type": "integer", "lower": 0, "upper": 100}
  ],
  "constraints": [
    {
      "name": "land capacity",
      "level": "hard",
      "expression": {
        "op": "le",
        "left": {"op": "sum", "args": ["wheat", "chickpea"]},
        "right": 100
      }
    }
  ],
  "objectives": [
    {
      "name": "expected profit",
      "sense": "maximize",
      "expression": {
        "op": "sum",
        "args": [
          {"op": "mul", "left": 30, "right": "wheat"},
          {"op": "mul", "left": 22, "right": "chickpea"}
        ]
      }
    }
  ]
}
```

The complete document JSON schema is defined at [`schema/navokoj-model.schema.json`](schema/navokoj-model.schema.json).

---

## Backend Selection & Routing

Solver backend selection is automatic and deterministic based on problem characteristics:

| Model Characteristics | Selected Engine / Backend | Description |
|---|---|---|
| Categorical + Equality/All-Different | **Q-State** | Direct N-ary state satisfaction on continuous manifolds |
| Hard parity / XOR constraints | **Hybrid CNF+XOR** | Continuous relaxation paired with Gaussian parity elimination |
| Weighted CNF / Pseudo-Boolean | **Nitro / Mini / Pro** | Continuous Riemannian MaxSAT manifold solvers |

---

## Testing & Verification

Run unit test suites:

Using LDC2:
```bash
make test
```

Using Dub:
```bash
dub run --config=test
```

The test runner covers:
- Boolean/Tseitin compilation & Q-State hydration
- Pseudo-Boolean arithmetic truth tables & indexed cardinality
- OPB parser/serializer & BigInt normalization
- Dynamic capability discovery deserialization
- HTTP transport failure modes & partial solution verification

---

## License

The **Reify** D compiler project is distributed under the **Boost Software License 1.0** (`BSL-1.0`); see [`LICENSE`](LICENSE).
