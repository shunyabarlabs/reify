# Reify — Software Architecture

This document applies the canonical six-section template
(Requirements → Core Entities → API/Interface → Data Flow → High-Level Design →
Deep Dives) to the Reify codebase. Line-number references are to the working
copy under `source/reify/*.d` unless otherwise noted.

---

## 1. Requirements

### 1.1 Functional Requirements

| ID | Requirement | Source |
|----|-------------|--------|
| F-1 | Model a finite decision problem in D with Boolean, bounded-integer, and categorical variables. | `model.d:535` (`Model`) |
| F-2 | Express hard, medium, and soft constraints symbolically. | `model.d:853–901` |
| F-3 | Express `maximize` / `minimize` linear objectives with priority levels. | `model.d:960–966`, `model.d:1166–1195` |
| F-4 | Lower symbolic expressions to CNF / WCNF / Q-State and optionally native parity. | `compiler.d:115–148` |
| F-5 | Choose a solver backend based on problem topology and account limits. | `router.d:63–149`, `diagnostics.d` |
| F-6 | Submit the compiled artifact to a remote solver via HTTPS. | `navokoj/client.d:77–101` |
| F-7 | Hydrate the wire response back into domain-named assignments. | `result.d:508–788` |
| F-8 | Re-verify every constraint locally against the returned assignment. | `result.d:813–1002` |
| F-9 | Explain a chosen solution at the model level. | `explain.d` |
| F-10 | Parse raw DIMACS and OPB inputs into the same Model IR. | `dimacs.d`, `opb.d` |
| F-11 | Export compiled models as CNF, DIMACS, WCNF, OPB, or Navokoj IR with a verification manifest. | `exports.d` |
| F-12 | Execute selected local SAT/MaxSAT command backends with disk preflight and fallback. | `local/backend.d`, `app.d` |

### 1.2 Non-Functional Requirements

| ID | Requirement | How it is realized |
|----|-------------|--------------------|
| NF-1 | Zero managed-heap pressure during model construction. | `ExpressionNodePool` (`model.d:75–98`) — 16,384-node chunks |
| NF-2 | Bounded compile-time guarantees (no quadratic blow-up). | `CompileOptions.maxBddNodesPerConstraint = 500_000` (`compiler.d:46`) and BDD memoization (`compiler.d:1193–1237`) |
| NF-3 | Capability errors fail fast at compile time, never at the solver. | `CapabilityException` checks (`compiler.d:150–250`) |
| NF-4 | Credential leakage prevented at log/serialization time. | `RequestOptions` keeps the key out of the model JSON (`client.d:40–48`) |
| NF-5 | HTTP-timeout policy honors the solver-side timeout budget. | `ensureSolveTransportTimeout` (`client.d:561–613`) |
| NF-6 | Loopback-only allowance for non-HTTPS local testing. | `isLoopbackHttpUrl` (`client.d:503–559`) |
| NF-7 | Deterministic replays of native DIMACS clauses. | `addExactClause` (`compiler.d:1679–1709`) preserves literal order |

### 1.3 Current capability matrix

This is the user-facing inventory of what is shipped today. The lower-level
sections that follow describe the implementation details.

| Area | Shipped capability | Notes / boundary |
|------|--------------------|------------------|
| Decision modeling | Boolean, bounded-integer, and categorical variables; scalar and family/block helpers | Variables are finite and named; models freeze after successful compilation. |
| Symbolic expressions | Boolean logic (`not`, `and`, `or`, `xor`, implication, equivalence), integer arithmetic with constants, comparisons, Boolean-to-integer conversion, and categorical equality/inequality | Multiplication is supported only when one side is constant. |
| Constraints | Hard, weighted medium, weighted soft, exact native CNF clauses, XOR/parity, cardinality (`atMost`, `atLeast`, `exactly`, `between`), `allDifferent`, and reusable relational group constraints | Soft/medium semantics are preserved in WCNF and hosted weighted requests. |
| Objectives | Linear `maximize` / `minimize` objectives with non-negative priority levels | Nonlinear MILP/QP objectives are not available. |
| Relational builders | Cartesian decision spaces, typed dimensions, filtering, grouping, exactly-one / at-most-one / at-least-one, parity, soft preferences, and logical/physical plan explanations | `builders.d` lowers relational operations into the normal Model IR. |
| Temporal scheduling | SpaceTime ordered time dimensions, durations, horizon fit, availability windows, precedence (`before`), non-overlap, capacity, value preferences, composable recipes, and explain plans | SpaceTime is a finite scheduling vocabulary, not a general modal-logic engine. |
| Compilation | CNF, WCNF, Q-State categorical lowering, optional native parity, order encoding for bounded integers, pseudo-Boolean BDD lowering, provenance, and compile-size guards | Q-State requires a compatible hard categorical model; native parity is optional. |
| Standard formats | JSON model documents, raw DIMACS CNF, and OPB input; exports for CNF JSON, DIMACS, WCNF, OPB, and Navokoj IR | CNF, DIMACS, and OPB exports reject soft semantics; export WCNF for weighted models. |
| Hosted execution | HTTPS solve, diagnose, and capabilities calls through the Navokoj client; injectable `HttpTransport` for tests or alternate transports | Credentials stay in request options, outside the model artifact. |
| Local execution | DIMACS adapters: Kissat, Glucose, MiniSat, CaDiCaL, CryptoMiniSat. WCNF adapters: Open-WBO, Loandra, MaxHS, RC2, UWrMaxSat, Pacose, WMaxCDCL, MaxCDCL, EvalMaxSAT | Standard command-line protocols are supported. RC2 and unusual CLIs may need a wrapper or custom arguments. |
| Routing | Topology analysis, Q-State/Nitro/hybrid hosted routing, hardware and account-limit reconciliation, exact/feasible/anytime route contracts, explicit backend selection, and ordered fallbacks | Exactness is reported only when the selected solver explicitly certifies optimum; every assignment is locally verified. |
| Resource protection | BDD, pseudo-Boolean, encoded-variable, encoded-clause, DIMACS, OPB, and formula limits; local artifact disk-space preflight; local fallback to hosted execution when credentials exist | A local subprocess currently relies on solver-specific timeout arguments; HTTP transport timeout is enforced separately. |
| Results and trust | Domain-named hydration, missing/inconsistent decision states, score/objective evaluation, partial-result preservation, hard/soft verification, semantic-operation provenance, decision explanations, and verification manifests | Raw solver literals are not the public solution surface. |
| CLI lifecycle | `validate`, `compile`, `analyze`, `diagnose`, `solve`, and `capabilities`; JSON/DIMACS/OPB input auto-detection; engine/backend/hardware/timeout/threshold controls | `--backend` selects a local adapter; `--engine` selects or constrains the hosted engine. |

### 1.4 Out-of-Scope (current version)

- Nonlinear integer arithmetic (`encodeLinearComparison` throws
  `CapabilityException` for `*` of two variable forms — `compiler.d:1576–1589`).
- Native MILP / QP objective backends.
- Complete modal-logic operators such as □ and ◇; SpaceTime is a finite
  temporal scheduling vocabulary.
- Automatic installation or normalization of third-party solver binaries.
  The shipped local adapter expects a standard command-line executable or a
  caller-provided wrapper/configuration.

---

## 2. Core Entities

These are the conceptual nouns that flow through the entire pipeline. They
appear as D structs / classes in the source tree.

### 2.1 Model (`model.d:535`)
The symbolic, domain-neutral decision graph. Holds:

- `DomainVariable[] _variables` — declared variables with name, kind, bounds.
- `NamedConstraint[] _constraints` — symbolic Boolean expressions with a level.
- `NamedObjective[] _objectives` — `IntExpr` plus `ObjectiveSense`.
- `ParityConstraint[] _parityConstraints` — XOR-of-Boolean variables.
- `NamedModelClause[] _nativeClauses` — exact DIMACS-compatible literals.
- `SemanticOperation[] _semanticOperations` — provenance stack for explain.

An arena pool (`ExpressionNodePool`) is owned by the model so every node is
GC-quiet.

### 2.2 ExpressionNode (`model.d:62`)
The AST node. `kind` is one of `ExpressionKind` (23 values, `model.d:21–43`).
Pure functional — mutating a node is not part of the public contract.

### 2.3 BoolExpr / IntExpr / CategoryExpr (`model.d:233–374`)
The user-facing expression handles. They wrap `ExpressionNode` and add D
operator overloads (`&`, `|`, `^`, `~`, `+`, `-`, `*` with constants).

### 2.4 CompileOptions (`compiler.d:35`)
Compile-time budget knobs: domain limits, BDD ceiling, native-parity
preference, diagnostic mode. Defensive defaults are explicit.

### 2.5 CompiledModel (`compiler.d:75`)
The artifact produced by `compile()`. Carries:

- `Backend` — `cnf` | `hybrid` | `qstate`
- `JSONValue request` — the wire payload
- `DomainAtom[][] atoms` — per-variable value→literal map
- `int[][] integerOrderLiterals` — order-encoding threshold literals
- `EncodedClause[] clauses` — final CNF
- `size_t generatedVariableCount` — number of SAT variables produced
- `warnings[]` — e.g. parity lowering under explicit engine selection

### 2.6 EncodedClause (`compiler.d:60`)
A single clause with provenance: literals, name, level, weight, structural
flag, priority level, semantic-operation IDs.

### 2.7 DomainAtom (`compiler.d:55`)
One value of one variable's domain, paired with the SAT literal that selects
it.

### 2.8 RoutingRecommendation (`router.d:21`)
The output of the router. Carries backend family, hosted engine, hardware,
target endpoint, correctness guarantee (`exact`, `feasible`, or `anytime`),
ordered fallback backends, and cost/time estimates. `refused = true` is the
refusal sentinel for over-sized models or when the live account advertises no
compatible engine.

### 2.9 Capabilities (`backend.d:13`)
The server-side envelope: engines, max variables / clauses, hardware access,
tier, credits.

### 2.10 NormalizedResponse (`result.d:159`)
Server response, parsed defensively: success, satisfiable, assignment,
satisfaction rate, solve time, request id, engine used.

### 2.11 Solution (`result.d:92`)
Hydrated result keyed by domain variable name. Each value is a `DecisionValue`
(`result.d:21`) with status `assigned` / `missing` / `inconsistent`.

### 2.12 VerificationReport (`result.d:237`)
Local re-evaluation of every constraint. Counts hard-satisfied, hard-violated,
medium-violated, soft-violated, plus matched constraint names with messages.

### 2.13 SolveResult (`result.d:299`)
The final envelope handed back to the caller: status, solution, score,
verification, objectives, server telemetry, semantic operations.

### 2.14 Exceptions (`errors.d`)
- `NavokojException` — base
- `UnsupportedDomainException` — router-recognized domain boundary, such as
  large hardware-BMC logic that should use an offline CDCL solver
- `ModelException` — invalid model
- `CapabilityException` — cannot be represented by any current backend
- `BackendException` — local solver startup or result failure
- `DiskSpaceException` — local artifact staging cannot fit the filesystem
- `ApiException` — transport / API failure, with `deliveryState`
- `ProtocolException` — wire contract violation

---

## 3. API / Interface

### 3.1 Library API (D)

The `reify` umbrella module (`package.d`) re-exports:

| Symbol | Purpose | Source |
|--------|---------|--------|
| `Model` | Decision graph | `model.d:535` |
| `BoolExpr`, `IntExpr`, `CategoryExpr` | Expression wrappers | `model.d:233–374` |
| `boolean()`, `integer()`, `booleanVar()`, `integerVar()`, `categoricalVar()` | Construction helpers | `model.d:1217+`, `model.d:728+` |
| `atLeast`, `atMost`, `exactly`, `between`, `allDifferent`, `implies`, `equivalent` | Cardinality / logical helpers | `model.d:1353–1411` |
| `compile`, `validateModel`, `CompiledModel`, `Backend`, `backendName` | Lowering API | `compiler.d:115`, `compiler.d:150` |
| `CompileOptions` | Compile budget | `compiler.d:35` |
| `NavokojClient`, `RequestOptions`, `defaultBaseUrl` | Wire client | `navokoj/client.d` |
| `NavokojBackend` | `SolverBackend` adapter | `navokoj/backend.d` |
| `CommandSolverBackend`, `createLocalBackend`, `solveLocal` | Local DIMACS/WCNF command adapters | `local/backend.d` |
| `NavokojApp`, `decisionApp` | High-level orchestration | `app.d:45` |
| `NavokojException`, `CapabilityException`, `ModelException`, `ApiException`, `ProtocolException` | Errors | `errors.d` |
| `BuildSolution`, `BuildStatus`, `DecisionStatus`, `Score`, `VerificationReport`, `SolveResult` | Result types | `result.d` |
| `TopologyAnalysis`, `analyzeModel`, `analyzeCompiled` | Diagnostics | `diagnostics.d` |
| `RoutingRecommendation`, `recommendRoute` | Router | `router.d:21`, `router.d:63` |
| `DocumentParser` (via `documentApp`) | JSON model ingest | `document.d` |
| `HttpTransport`, `CurlTransport` | Pluggable HTTP | `transport.d` |
| `reify.opb.*`, `reify.dimacs.*` | Standard format I/O | `opb.d`, `dimacs.d` |
| `ExportArtifact`, `emit`, `verificationManifest` | Portable solver artifacts and provenance manifests | `exports.d` |
| `reify.spacetime.*` | Temporal recipes | `spacetime.d` |
| `reify.explain.*` | Audit trail | `explain.d` |

### 3.2 CLI Interface (`app.d:9`, `app.d:248`)

The executable `reify` is the `navokoj-app` lifecycle.

```
reify <command> [options]

commands:
  validate       Build + validate, no wire request.
  compile        Build + validate + lower; print request JSON.
  analyze        Build + topology + recommendation.
  diagnose       Compile + DEFEKT diagnostic call.
  solve          Build + compile + submit + hydrate + verify.
  capabilities   Probe live account envelope.
```

| Option | Meaning |
|--------|---------|
| `--input <file>` | JSON, DIMACS, or OPB; auto-detected |
| `--format <auto|json|dimacs|opb>` | Force input format |
| `--output <file>` | Write JSON instead of stdout |
| `--api-key <token>` | Bearer key; default `NAVOKOJ_API_KEY` env |
| `--base-url <url>` | Override endpoint |
| `--engine <name>` | Solver engine (default `auto` → router) |
| `--backend <name>` | Local SAT/MaxSAT command backend; `auto` keeps hosted routing |
| `--hardware <name>` | Hardware target |
| `--timeout <seconds>` | Solver budget |
| `--min-satisfaction <0..1>` | Stop at threshold |
| `--min-weighted-satisfaction <0..1>` | WCNF threshold |
| `--transport-timeout <sec>` | HTTP timeout (default 60) |
| `--max-bdd-nodes <count>` | Override BDD ceiling |
| `--pretty` | Pretty-print summary |
| `--help` | Usage |

### 3.3 JSON Wire Contract

The application-level JSON model document is parsed by `document.d`. The
submission payload is built by `CnfCompiler.buildRequest` (`compiler.d:1924`)
and contains:

- `num_vars` — generated SAT-variable count
- `clauses` — array of literal arrays
- `weights` — present iff the model has any non-hard constraint
- `hard_clause_mask` — parallel boolean array to enforce hard semantics
- `timeout_budget_seconds`, `min_satisfaction`, `min_weighted_satisfaction`
- `engine`, `hardware`
- `xor_constraints` and `strategy = "auto"` (only when `useNativeParity`)

The Q-State path emits `num_vars`, `num_states`, and `constraints` (eq / neq /
in / all_diff objects — see `compileQState` at `compiler.d:353`).

### 3.4 Internal Solver-Backend Interface (`backend.d:94–109`)

```d
interface SolverBackend {
    string id() const;
    BackendResponse execute(CompiledModel compiled, BackendOptions options);
}

interface SolverResponseParser {
    string id() const;
    SolveResult parse(CompiledModel compiled, BackendResponse response);
}
```

`NavokojBackend` (`navokoj/backend.d:28`) and
`CommandSolverBackend` (`local/backend.d:315`) are the shipped implementations.
Adapter authors can implement the same interface for another solver or service.

### 3.5 Transport Interface (`transport.d:33–41`)

```d
interface HttpTransport {
    HttpResponse postJson(
        string url,
        string bearerToken,
        string body,
        Duration connectTimeout,
        Duration operationTimeout
    );
}
```

`CurlTransport` is the Phobos-libcurl default; tests inject their own.

---

## 4. Data Flow

### 4.1 Build phase

```
D source ──► Model.* methods ──► ExpressionNode (allocated from arena) ──►
      Model._constraints / _objectives / _parityConstraints / _nativeClauses
```

Every `model.require(name, expr)` validates the expression belongs to the
receiving model (`model.d:1075`), then stores a `NamedConstraint`. The
expression tree is built once and shared (immutable by convention).

### 4.2 Compile phase

```
Model ──► validateModel ──► CompileOptions.maxIntegerDomain / maxBddNodesPerConstraint
       ──► supportsQState?
              yes ──► compileQState ──► Backend.qstate
              no  ──► CnfCompiler.run ──► Backend.cnf | Backend.hybrid
       ──► model.freeze()
```

Inside `CnfCompiler.run` (`compiler.d:503`):

1. **Domain atom allocation** — `allocateDomainAtoms` assigns SAT variables to
   every Boolean atom, every categorical state, and every integer threshold.
2. **Native clauses** — `addExactClause` keeps source DIMACS intact.
3. **Symbolic constraints** — `encodeBoolean` walks the AST, memoizing
   subexpressions; emits structural CNF (Tseitin-style via
   `encodeAnd / encodeOr / encodeXor / encodeIte`).
4. **Parity** — either preserved natively (`xor_constraints` on the request)
   or lowered to CNF.
5. **Objectives** — `encodeObjectives` emits one soft clause per positive
   coefficient contribution, with weighted priority levels.
6. **Soft-consolidation** — `consolidateEquivalentSoftClauses` sums identical
   literals.
7. **Weight normalization** — `finalizeWeights` reduces per-level weights to
   their GCD ratio and applies lexicographic scaling.
8. **Request building** — JSON serialization with optional mask / parity.

### 4.3 Submission phase

```
CompiledModel.request ──► NavokojClient.solveRaw
       ──► validateRequestOptions
       ──► applyRecommendation (overrides engine/hardware/path)
       ──► transport.postJson (Bearer auth, JSON body)
       ──► JSON response ──► propagateRequestId
```

`ensureSolveTransportTimeout` widens the HTTP transport timeout to
`budget + connect + 5 s` so a long solve cannot be cut off by the transport.

### 4.4 Hydration and verification phase

```
JSON assignment ──► normalizeResponse ──► hydrate (per-backend)
                                      ──► verify (model.constraints + native clauses + parity)
                                      ──► calculateScore
                                      ──► evaluateObjectives
                                      ──► SolveResult
```

`hydrateCnf` (`result.d:576`) reverses the order encoding by counting the
leading true thresholds and projecting them back to
`lowerBound + trueThresholds`. Categorical atoms are matched by literal.

`verify` (`result.d:813`) re-evaluates every symbolic expression against the
hydrated values. Native clauses are checked with a polarity-merge optimization
that flips the result to `satisfied` as soon as both `x` and `¬x` literals
appear in a clause.

### 4.5 End-to-end picture

```
D source ──► Model ──► CompiledModel ──► HTTP POST ──► JSON ──►
       SolveResult (Solution + VerificationReport + Score)
```

---

## 5. High-Level Design

### 5.1 Layered architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  Application boundary                                            │
│  source/app.d, NavokojApp (app.d), decisionApp (app.d:210)       │
├──────────────────────────────────────────────────────────────────┤
│  Modeling surface                                                │
│  Model, BoolExpr/IntExpr/CategoryExpr, helpers (model.d)         │
│  SpaceTime (spacetime.d), Builders (builders.d)                  │
│  DocumentParser (document.d), OPB/DIMACS adapters               │
├──────────────────────────────────────────────────────────────────┤
│  Lowering core                                                   │
│  validateModel → compileQState (compiler.d:353)                  │
│               → CnfCompiler.run (compiler.d:503)                 │
│  EncodedClause, atoms, order literals                            │
├──────────────────────────────────────────────────────────────────┤
│  Diagnostics & routing                                           │
│  TopologyAnalysis (diagnostics.d), RoutingRecommendation (router.d)│
│  Recommend-by-topology + apply-account-limits                    │
├──────────────────────────────────────────────────────────────────┤
│  Solver backend interface                                        │
│  SolverBackend, SolverResponseParser (backend.d)                 │
│  NavokojBackend (navokoj/backend.d)                              │
├──────────────────────────────────────────────────────────────────┤
│  HTTP transport                                                  │
│  HttpTransport, CurlTransport (transport.d)                      │
├──────────────────────────────────────────────────────────────────┤
│  Result processing                                               │
│  NormalizedResponse, hydrate*, verify, calculateScore,            │
│  evaluateObjectives, buildSolveResult (result.d)                 │
└──────────────────────────────────────────────────────────────────┘
```

### 5.2 Component responsibilities

| Component | Responsibility |
|-----------|----------------|
| **Modeling** (`model.d`) | Author-time symbolic API. Owns the arena. |
| **SpaceTime** (`spacetime.d`) | Temporal recipes layered on top of `Model`. |
| **Lowering** (`compiler.d`) | Validate options; pick backend; produce wire-ready JSON. |
| **Diagnostics** (`diagnostics.d`) | Topology metrics: α, phase-transition band, XOR density. |
| **Router** (`router.d`) | Deterministic engine/hardware selection with account reconciliation. |
| **Backend interface** (`backend.d`) | Adapter contract. |
| **Navokoj client** (`navokoj/`) | Reference HTTPS adapter, response parser. |
| **Transport** (`transport.d`) | Pluggable HTTP, libcurl default. |
| **Result** (`result.d`) | Hydrate, verify, score, evaluate objectives. |
| **App / CLI** (`app.d`, `source/app.d`) | Lifecycle orchestration. |
| **Explain** (`explain.d`) | Logical / physical plans from a `Model`. |

### 5.3 Pipeline diagram

```
                ┌───────────────────────────────────────────────┐
                │   Declarative D source / JSON model document  │
                └────────────┬──────────────────────────────────┘
                             │
                    Model + ExpressionNode arena
                             │
              ┌──────────────┴───────────────┐
              │                              │
       validateModel                  TopologyAnalysis
              │                              │
              ▼                              ▼
   compile(model, opts)            recommendRoute(topology, caps)
              │                              │
   ┌──────────┴───────────┐                  │
   │                      │                  │
   ▼                      ▼                  │
compileQState        CnfCompiler.run          │
(Backend.qstate)     (Backend.cnf/hybrid)     │
   │                      │                  │
   └──────────┬───────────┘                  │
              │                              │
              ▼                              │
       CompiledModel ── request JSON ────────┘
              │
              ▼
       NavokojClient.solveRaw ── HttpTransport.postJson
              │
              ▼
        Server response JSON
              │
              ▼
       buildSolveResult
       ├── normalizeResponse
       ├── hydrate
       ├── verify
       ├── calculateScore
       └── evaluateObjectives
              │
              ▼
           SolveResult
```

### 5.4 Configuration and safety boundaries

- **Compile-time safety** — `validateModel` rejects integer-domain overflow,
  BDD-limit under-provisioning, negative priorities, and incompatible options
  *before* a single clause is allocated.
- **Wire-time safety** — `validateRequestOptions` refuses to send a Bearer
  token over plain HTTP, except for explicit loopback URLs.
- **Runtime safety** — `deliveryState` on `ApiException` distinguishes
  `notSent`, `acceptanceUnknown`, `responseReceived`. Callers can choose
  whether to retry (only safe when idempotent).

---

## 6. Deep Dives

### 6.1 Symbolic IR and arena allocation (`model.d`)

The `ExpressionNodePool` (`model.d:75–98`) pre-allocates fixed-size chunks of
`ExpressionNode` objects. A chunk is created the first time the pool is
empty or when the index reaches the chunk length. `alloc()` does not perform
heap allocation; it returns a recycled object whose fields are reset. This
keeps long model-construction passes GC-quiet — verified during the
enterprise scheduling run that produced 5,400 logical / 142,561 encoded
variables without measurable GC pause.

Operator handlers (`unaryNode`, `binaryNode` — `model.d:100–219`) do constant
folding for fully-attached integer and Boolean operators. This is why
`integer(1) + integer(2)` works without an owning model — it folds to
`integer(3)` without ever touching the arena.

### 6.2 Order encoding for bounded integers (`compiler.d:750–768`)

For an integer variable with domain `[L, U]`, the compiler allocates
`U − L` SAT variables (`integerOrderLiterals[logicalIndex]`). Literal `i`
asserts `x ≥ L + i + 1`. Adjacent thresholds are chained by structural
clauses:

```
(¬ord[i] ∨ ord[i − 1])    // monotonicity
```

Integer comparisons are then normalized to a `LinearForm` (constant plus a
sparse `long[size_t]` coefficient map) and turned into a pseudo-Boolean
constraint via `encodePseudoBooleanAtMost`.

### 6.3 Pseudo-Boolean BDD lowering (`compiler.d:1152–1237`)

The pseudo-Boolean encoder builds a recursive decision tree that counts true
literals and rejects branches that already exceed the capacity. A memoization
dictionary (`int[string] memo`) and a pre-computed suffix-weight array keep
the complexity bounded. The `nodes` counter is checked against
`maxBddNodesPerConstraint` (default 500K) — raising this is the standard way
to compile hard integer workloads (the 550K-clause run used 50M).

### 6.4 Linear-form extraction (`compiler.d:1505–1626`)

`linearize` returns a `LinearForm { long constant; long[size_t] coefficients }`
or `valid = false`. The encoder explicitly rejects variable × variable
multiplication by checking that at most one operand has any coefficient
(`compiler.d:1584–1589`). When the model uses linearization-fragile
expressions (nested `atMost(atLeast(...))` for instance), the compiler throws
`CapabilityException` with a clear "future MILP/QP backend" message rather
than emitting an exponential blow-up.

### 6.5 Weighted-MaxSAT weight normalization (`compiler.d:1777–1922`)

Weights are normalized in three passes:

1. **Per-level GCD reduction** (`normalizeLevelWeights`) — IEEE-754 weights
   are decomposed into significand and exponent, brought to a common exponent,
   and divided by their GCD. This produces exact integer ratios.
2. **Lexicographic scaling** (`finalizeWeights`) — for each priority level,
   `scales[level] = 1 + Σ_{higher} totals × scales`. The cumulative cap is
   checked against `options.maximumEncodedWeight` (default `9 × 10¹⁵`).
3. **Structural clause weight** — set to `lowerMaximum + 1` so hard clauses
   always dominate.

This is what makes WCNF encodings safe to send to engines that interpret
weights as cost rather than dominance.

### 6.6 Engine selection algorithm (`router.d`)

`recommendRouteByTopology` is a capability-aware policy decision:

1. Build symbolic topology facts, including encoded size, parity, explicit
   objectives, and weighted constraints (soft/medium constraints count even
   when no explicit objective is declared).
2. Select the representation family: Q-State for eligible all-categorical
   hard models, native parity for eligible hard XOR models, and CNF/WCNF for
   the remaining models.
3. Keep small weighted models on CPU Nitro. Reserve H100 for genuinely large
   encodings or many weighted terms; objective count alone does not justify a
   GPU route.
4. Attach a correctness guarantee and fallback chain. Weighted routes expose
   Open-WBO/MaxHS/RC2; hard XOR routes expose CryptoMiniSat/Kissat/CaDiCaL;
   hard CNF routes expose Kissat/CaDiCaL/MiniSat.
5. Reconcile the route against the live account envelope. If an advertised
   engine list exists, it is authoritative: use a compatible advertised
   engine or refuse explicitly.

`applyAccountLimits` then either:

- **Refuses** (sets `refused = true`) when the model exceeds
  `caps.maxVariables` or `caps.maxClauses`, or when no compatible advertised
  engine exists.
- **Downgrades** GPU→CPU when the account's `hardwareAccess` does not include
  the recommended hardware. The empty list is treated as "unknown" and the
  topology choice stands.

`NavokojApp.solveAuto` analyzes the symbolic model, fetches capabilities,
selects the route, and only then compiles. This prevents the compiler from
emitting Q-State or native XOR for an account that cannot execute that
representation. It performs a second size reconciliation after lowering,
because integer and categorical encodings can expand substantially.

### 6.6.1 Local backend selection and disk fallback

`CompileOptions.backend` (or CLI `--backend`) selects a local command adapter:

```text
WCNF:   openwbo (open-wbo), loandra, maxhs (max-hs), rc2, uwrmaxsat,
        pacose, wmaxcdcl, maxcdcl, evalmaxsat
DIMACS: kissat, glucose, minisat, cadical, cryptominisat
```

The adapter stages the expanded artifact only after checking
`getAvailableDiskSpace(tempDirectory)` against a conservative size estimate
plus a reserve. A write failure is treated as disk pressure. The selected
backend's fallback chain is tried next; if all local staging attempts fail for
disk reasons and an API key is available, `NavokojApp` returns to the hosted
router instead of leaving the request unsolved.

Executables can be configured without shell interpolation using environment
variables such as `REIFY_OPENWBO_PATH`, `REIFY_KISSAT_PATH`, and
`REIFY_CRYPTOMINISAT_PATH`. The parser accepts the standard `s`, `v`, and `o`
solver lines, plus MiniSat's bare status/result-file format. It only marks a
result `optimal` when the solver explicitly reports `OPTIMUM FOUND`. Every
assignment still passes Reify's local hard constraint verifier. API callers can
override command arguments with `{input}` and `{output}` placeholders; the
MiniSat adapter supplies a result-file path automatically when omitted.

### 6.7 Transport timeout reconciliation (`client.d:561–613`)

If the compiled request carries a `timeout_budget_seconds`, the client widens
the HTTP `transportTimeout` to `budget + connect + 5s`. This is the safety
net that prevents the solver being killed by the wire transport right when it
is about to return a result. The check rejects budgets that exceed
`long.max / 1000` seconds to avoid integer overflow.

### 6.8 Hydration correctness (`result.d:576–720`)

`hydrateCnf` validates three things during integer reconstruction:

1. **Monotonicity** — true thresholds must come before any false threshold.
   Violation → `DecisionValue.inconsistent`.
2. **Completeness** — every threshold literal must be present. Missing →
   `DecisionValue.missing`.
3. **Single-selection for atoms** — exactly one selected atom per Boolean /
   categorical variable. Violation → `DecisionValue.inconsistent`.

`hydrateNamedObject` (`result.d:722–788`) handles the alternative server
response format that maps names directly to values. Categorical variables
accept either a state string or an integer index.

### 6.9 Local verification (`result.d:813–1002`)

`verify` walks every constraint and every native clause:

- Symbolic expressions are evaluated with `evaluateBoolean` /
  `evaluateInteger` against the hydrated values.
- Native clauses are checked with a polarity-merge map (`ubyte[size_t]
  polarities`) so an `(x ∨ ¬x)` clause is reported as satisfied even when one
  of the literals is missing.
- Parity constraints fold XOR with a single accumulator.

Aggregate counters always cover the entire formula; only actionable
(violated / unknown) matches are retained in `matches` (capped at 1,000 for
native clauses; excess counted as `omittedMatches`). This keeps large
diagnostic reports bounded.

### 6.10 Native-parity vs CNF parity (`compiler.d:693–714`)

The `useNativeParity` flag is set only when:

- `preferNativeParity` is true,
- `engine == "auto"` and `hardware == ""`,
- the model has no objectives,
- every clause and constraint is hard.

When the user pins an explicit engine or hardware, parity is lowered to CNF
and a warning is added to `CompiledModel.warnings`. This keeps the
`xor_constraints` request field reserved for the router-driven path where
the server knows the parity is exact.

### 6.11 Q-State special-case (`compiler.d:252–483`)

When every variable is categorical, every constraint is hard, and the only
operators used are `eq`, `neq`, `in`, and `allDifferent`, the compiler emits a
Q-State request directly:

- `num_vars`, `num_states`
- `constraints` with `eq`, `neq`, `in`, `all_diff`

This bypasses CNF entirely. The hydration path for Q-State uses
`qstateVariableOrder` and re-maps state indices back to category names
(`hydrateQState` at `result.d:528–574`).

### 6.12 Error taxonomy (`errors.d`)

```
NavokojException
├── ModelException         — modeling mistake (caught at build / validate)
├── CapabilityException    — valid model, no backend can represent it
├── ApiException           — wire/transport failure
│     └── carries deliveryState (notSent / acceptanceUnknown / responseReceived)
└── ProtocolException      — server response shape is wrong
```

This shape gives the caller a precise contract for retries. Only
`ApiException` with `deliveryState == notSent` or `responseReceived` may be
retried safely; `acceptanceUnknown` requires an idempotency guarantee.

---

## Appendix A — Module line counts

| Module | Lines |
|--------|------:|
| `model.d` | 1,421 |
| `compiler.d` | 2,078 |
| `opb.d` | 2,505 |
| `result.d` | 1,332 |
| `app.d` | 735 |
| `navokoj/client.d` | 680 |
| `formula.d` | 2,006 |
| `spacetime.d` | 1,135 |
| `document.d` | 937 |
| `dimacs.d` | 711 |
| `explain.d` | 613 |
| `builders.d` | 506 |
| `exports.d` | 354 |
| `router.d` | 341 |
| `diagnostics.d` | 166 |
| `transport.d` | 89 |
| `errors.d` | 123 |
| `backend.d` | 118 |
| `navokoj/backend.d` | 61 |
| `local/backend.d` | 531 |
| `package.d` | 52 |
| `navokoj/response_parser.d` | 37 |
| `app.d` (entry) | 10 |
| **Total** | **16,541** |

## Appendix B — Verified performance characteristics

From `examples/test_scaling.d` and earlier problem instances:

| Logical Variables | Encoded Variables | Clauses | Solve Time | Engine / Hardware |
|------------------:|------------------:|--------:|-----------:|-------------------|
| 4 | ~600 | 1,189 | 21 ms | nitro / cpu |
| 12 | 6,866 | 27,205 | 170 ms | nitro / cpu |
| 1,260 | 13,915 | 51,121 | 188 ms | nitro / cpu |
| 4,800 | ~124K | 487,241 | ~1.4 s | nitro / cpu |
| **5,400** | **142,561** | **550,651** | **1.84 s** | **nitro / cpu** |

The enterprise-sized (100 × 30 × 4) instance deterministically fails compile
with `CapabilityException: Nonlinear arithmetic requires a future MILP/QP API
backend`, demonstrating that the compile-time gate works as designed.
