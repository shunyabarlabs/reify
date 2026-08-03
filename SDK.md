# Reify SDK Reference

The Reify SDK is a D library (`reify` package) that turns a declarative model of
a finite decision problem into a solved, locally-verified assignment. It
compiles to multiple solver formats, runs locally or against the Navokoj hosted
engine, and re-hydrates solver output back to domain-named values.

This document is the **public API reference**. It mirrors the re-exports in
`source/reify/package.d`. For the architecture and design rationale, see
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## Table of contents

- [Getting started](#getting-started)
- [Modules at a glance](#modules-at-a-glance)
- [`reify.model` — the decision IR](#reifymodel--the-decision-ir)
- [`reify.formula` — symbolic expressions](#reifyformula--symbolic-expressions)
- [`reify.compiler` — lowering to CNF/WCNF/OPB/Q-State](#reifycompiler--lowering-to-cnfwcnfopbq-state)
- [`reify.exports` — portable artifacts](#reifyexports--portable-artifacts)
- [`reify.backend` — the solver interface](#reifybackend--the-solver-interface)
- [`reify.navokoj.client` — hosted execution](#reifynavokojclient--hosted-execution)
- [`reify.navokoj.backend` — hosted `SolverBackend` adapter](#reifynavokojbackend--hosted-solverbackend-adapter)
- [`reify.local.backend` — local SAT/MaxSAT adapters](#reifylocalbackend--local-satmaxsat-adapters)
- [`reify.transport` — pluggable HTTP](#reifytransport--pluggable-http)
- [`reify.router` — topology-driven routing](#reifyrouter--topology-driven-routing)
- [`reify.diagnostics` — topology analysis](#reifydiagnostics--topology-analysis)
- [`reify.result` — hydration and verification](#reifyresult--hydration-and-verification)
- [`reify.explain` — decision audit trail](#reifyexplain--decision-audit-trail)
- [`reify.builders` — relational decision DSL](#reifybuilders--relational-decision-dsl)
- [`reify.spacetime` — temporal scheduling](#reifyspacetime--temporal-scheduling)
- [`reify.document` — JSON model ingest](#reifydocument--json-model-ingest)
- [`reify.dimacs` — raw DIMACS I/O](#reifydimacs--raw-dimacs-io)
- [`reify.opb` — raw OPB I/O](#reifyopb--raw-opb-io)
- [`reify.app` — CLI and orchestration](#reifyapp--cli-and-orchestration)
- [`reify.errors` — exception hierarchy](#reifyerrors--exception-hierarchy)
- [End-to-end example](#end-to-end-example)
- [Solver adapter quick reference](#solver-adapter-quick-reference)

---

## Getting started

```d
import reify;
```

`reify` is an umbrella module — `public import` of every public sub-module. You
can also import sub-modules individually (`reify.model`, `reify.compiler`, …) if
you prefer narrower dependencies.

Add the dependency via Dub:

```bash
dub add reify
```

Or build the CLI from source:

```bash
ldc2 -i -Isource source/app.d -of=build/reify
```

---

## Modules at a glance

| Module | Purpose |
|--------|---------|
| `reify.model` | The decision IR: variables, constraints, objectives, parity, semantic provenance |
| `reify.formula` | Symbolic expression builders, binary mappings, pseudo-Boolean helpers |
| `reify.compiler` | Lowers a `Model` into a `CompiledModel` (clauses, atoms, variable numbering) |
| `reify.exports` | Emit a `Model` as CNF, DIMACS, WCNF, OPB, or Navokoj IR with a verification manifest |
| `reify.backend` | The `SolverBackend` interface that all execution paths implement |
| `reify.navokoj.client` | HTTPS client for the hosted Navokoj solver |
| `reify.navokoj.backend` | `SolverBackend` adapter wrapping `NavokojClient` |
| `reify.local.backend` | Local DIMACS/WCNF command-line adapters with disk preflight and hosted fallback |
| `reify.transport` | `HttpTransport` interface + `CurlTransport` implementation |
| `reify.router` | Topology-aware routing to a hosted engine/hardware combination |
| `reify.diagnostics` | Topology analysis of a model or compiled artifact |
| `reify.result` | `SolveResult`, `Score`, `VerificationReport`, named hydration |
| `reify.explain` | Logical plan, physical plan, execution trace, decision blame |
| `reify.builders` | Relational decision-space DSL: exactly-one, at-most-one, parity, preference |
| `reify.spacetime` | Temporal scheduling vocabulary on top of `Model` |
| `reify.document` | Parse JSON model documents into `Model` |
| `reify.dimacs` | Read and write raw DIMACS CNF |
| `reify.opb` | Read and write raw OPB |
| `reify.app` | `NavokojApp` orchestrator, `decisionApp` factory, `runNavokojApp` CLI entry |
| `reify.errors` | Exception hierarchy |

---

## `reify.model` — the decision IR

The IR is the central object. You build a `Model`, add variables, constraints,
and objectives, then hand it to the compiler.

### Enums

```d
enum VariableKind { boolean, categorical, integer }
enum ExpressionKind { /* see source — node kinds */ }
enum ConstraintLevel { hard, medium, soft }
enum ObjectiveSense { maximize, minimize }
```

### Value types

```d
struct BoolExpr     // symbolic Boolean expression
struct IntExpr      // symbolic integer expression
struct CategoryExpr // symbolic categorical expression
struct DomainVariable {
    string name;
    VariableKind kind;
    long lowerBound, upperBound; // integer
    string[] states;             // categorical
}
struct NamedConstraint {
    string name;
    BoolExpr expression;
    ConstraintLevel level;
    double weight;
    string sourceFile;
    size_t sourceLine;
    string semanticOperationId;
}
struct NamedObjective {
    string name;
    IntExpr expression;
    ObjectiveSense sense;
    int priority;
    string semanticOperationId;
}
struct ParityConstraint {
    string name;
    size_t[] variableIndices;
    int target;        // 0 or 1
    string semanticOperationId;
}
struct ModelClauseLiteral {
    size_t variableIndex;
    bool negated;
}
struct NamedModelClause {
    string name;
    ModelClauseLiteral[] literals;
    ConstraintLevel level;
    double weight;
    string sourceFile;
    size_t sourceLine;
    string semanticOperationId;
}
struct SemanticOperation {
    string id, parentId, semanticDomain, kind, label;
    string[] dimensions;
    string[string] attributes;
    string sourceFile;
    size_t sourceLine;
}
```

### Variable set helpers

```d
struct BoolVarSet     // family of Boolean variables, indexed by string key
struct IntVarSet      // family of integer variables
struct CategoryVarSet // family of categorical variables
```

Each set supports `opIndex(string key)` to look up an `IntExpr`/`BoolExpr`/`CategoryExpr`.

### `class Model`

```d
this(string name = "decision-model")
@property string name()
@property void name(string value)

bool frozen() const
DomainVariable[] variables()
NamedConstraint[] constraints()
NamedObjective[] objectives()
ParityConstraint[] parityConstraints()
NamedModelClause[] nativeClauses()
SemanticOperation[] semanticOperations()

// Variable creation
BoolExpr     booleanVar(string name)
IntExpr      integerVar(string name, long lowerBound, long upperBound)
CategoryExpr categoricalVar(string name, const(string)[] states)

BoolVarSet     booleanVars(string family, const(string)[] keys)
IntVarSet      integerVars(string family, const(string)[] keys,
                           long lowerBound, long upperBound)
CategoryVarSet categoricalVars(string family, const(string)[] keys,
                               const(string)[] states)

// Hard / weighted constraints
void require(string name, BoolExpr expression,
             string sourceFile = __FILE__, size_t sourceLine = __LINE__)
void medium (string name, BoolExpr expression, double weight = 1.0, …)
void prefer (string name, BoolExpr expression, double weight = 1.0, …)

// Exact native CNF clauses
void requireClause(string name, BoolExpr[] literals, …)
void mediumClause (string name, BoolExpr[] literals, double weight = 1.0, …)
void preferClause (string name, BoolExpr[] literals, double weight = 1.0, …)

// Built-in relational constraints
void atMost   (string name, BoolExpr[] variables, size_t maxCount)
void atLeast  (string name, BoolExpr[] variables, size_t minCount)
void exactly  (string name, BoolExpr[] variables, size_t count)
void between  (string name, BoolExpr[] variables, size_t min, size_t max)
void allDifferent(string name, IntExpr[] variables)

// Parity / XOR
void parity        (string name, BoolExpr[] variables, int target)
void requireParity (string name, BoolExpr[] variables, int target = 0)

// Objectives
void maximize(string name, IntExpr expression, int priority = 0)
void minimize(string name, IntExpr expression, int priority = 0)

// Semantic provenance
string registerSemanticOperation(
    string semanticDomain, string kind, string label,
    string[] dimensions = null, string[string] attributes = null,
    string sourceFile = __FILE__, size_t sourceLine = __LINE__)
void enterSemanticOperation(string operationId)
void leaveSemanticOperation()

// Variable lookup
bool   hasVariable(string name) const
size_t variableIndex(string name) const
```

After `compile()` succeeds, the model is frozen — mutating methods throw.

---

## `reify.formula` — symbolic expressions

The expression wrappers (`BoolExpr`, `IntExpr`, `CategoryExpr`) overload D
operators so you can write constraints directly:

```d
auto b = m.booleanVar("x");
auto i = m.integerVar("count", 0, 10);

m.require("example", b && !b || (i > 5));
m.require("domain",  i >= 0 && i <= 10);
m.require("guard",   m.booleanVar("y") || i < 3);
```

### Categories

```d
auto c = m.categoricalVar("color", ["red", "green", "blue"]);
m.require("not_red", c.differs("red"));
m.require("either",  c.equals("red") || c.equals("green"));
```

### Free helpers (operator overloads)

| Operation | D syntax | Notes |
|-----------|----------|-------|
| Not | `!e` | |
| And | `e1 && e2` | n-ary via parens |
| Or  | `e1 \|\| e2` | |
| Xor | `e1 ^ e2` | |
| Implies / equivalent | overloaded ops on `BoolExpr` | |
| Add / subtract | `i1 + i2`, `i1 - i2` | |
| Negate | `-i` | |
| Multiply | `i * 5` (constant-side only) | `*` of two variables throws `CapabilityException` |
| Comparisons | `<`, `<=`, `>`, `>=`, `==`, `!=` | |
| Bool→Int | `booleanAsInteger(b)` | |
| Cast helpers | `b.asInteger()` | |

### Pseudo-Boolean compatibility

```d
enum LinearRelation { less, lessEqual, equal, notEqual, greaterEqual, greater }
struct WeightedLiteral { long coefficient; int literal; }  // DIMACS literal
```

### Binary mapping policy

```d
enum BinaryValueBase : size_t { zero = 0, one = 1 }
enum BinaryBitOrder { mostSignificantFirst, leastSignificantFirst }

struct BinaryMappingOptions {
    BinaryValueBase valueBase = BinaryValueBase.zero;
    BinaryBitOrder  bitOrder  = BinaryBitOrder.mostSignificantFirst;
    bool enforceDeclaredRange = false;

    static BinaryMappingOptions standard();
    static BinaryMappingOptions cnfgenCompatible();
    static BinaryMappingOptions legacyOneBased();
}
```

### Formula resource limits

```d
struct FormulaLimits {
    size_t maxVariables = 1_000_000;
    size_t maxClauses = 5_000_000;
    size_t maxLiterals = 50_000_000;
    size_t maxIndexedTuples = 1_000_000;
    size_t maxIndexArity = 64;
    size_t maxPseudoBooleanTerms = 10_000;
}
```

`CnfFormula`, `VariableBlock`, and `IndexedVariableGroup` exist for advanced
formula-generator use cases that need direct clause-level access.

---

## `reify.compiler` — lowering to CNF/WCNF/OPB/Q-State

```d
enum Backend {
    cnf, wcnf, opb, qState, nativeParity
}

struct CompileOptions {
    string engine = "auto";   // hosted engine hint
    string hardware = "";     // hosted hardware hint
    string backend  = "auto"; // local backend hint
    bool preferQState = false;
    bool preferNativeParity = false;
    FormulaLimits limits = FormulaLimits.init;
    // … size/budget/timeout fields
}

struct CompiledModel {
    Model model;
    Backend backend;
    EncodedClause[] clauses;
    DomainAtom[] atoms;
    size_t generatedVariableCount;
    string[] warnings;
    // wire form for hosted transport
    JSONValue request;
    string summary();
}

struct EncodedClause { /* lowered clause representation */ }
struct DomainAtom    { /* variable / atom interpretation */ }

string backendName(Backend backend)
void   validateModel(Model model, CompileOptions options = CompileOptions())
CompiledModel compile(Model model, CompileOptions options = CompileOptions())
```

The `Backend` enum is the lowering strategy. The router picks one
automatically; `compile()` defaults to the first compatible option.

`EncodedClause.clauses` (accessible as `.clauses` on the compiled model) carries
`.literals`, `.level` (`ConstraintLevel`), `.weight`, `.structural`, and
`.priorityLevel` for downstream format emission.

---

## `reify.exports` — portable artifacts

```d
struct CNF        {}   // marker
struct WCNF       {}   // marker
struct DIMACS     {}   // marker
struct OPB        {}   // marker
struct NavokojIR  {}   // marker

struct ExportArtifact {
    string format;              // "cnf" | "dimacs" | "wcnf" | "opb" | "navokoj-ir"
    string payload;             // the serialized text
    JSONValue verificationManifest;
}

// Type-directed export
ExportArtifact emit(Target)(Model model, CompileOptions options = CompileOptions());

JSONValue verificationManifest(CompiledModel compiled);
```

### Targets and constraints

| Target | Accepts soft? | Notes |
|--------|---------------|-------|
| `CNF` | No (throws `CapabilityException`) | JSON-wrapped CNF |
| `DIMACS` | No | Raw DIMACS CNF text |
| `WCNF` | Yes | Weighted CNF; soft-weight sum checked for overflow |
| `OPB` | No | Pseudo-Boolean format |
| `NavokojIR` | Yes | Wire format sent to the hosted engine |

`emit!WCNF` is the recommended export when the model contains `medium` /
`prefer` constraints. Attempting to export a soft model to CNF/DIMACS/OPB
throws `CapabilityException` with a clear message pointing at WCNF.

`verificationManifest` returns a JSON document with model name, backend,
variable count, every semantic operation, every variable, and every clause
(literal, level, weight, structural flag, priority level, source provenance).
It is the manifest used to hydrate and verify raw assignments independently.

---

## `reify.backend` — the solver interface

```d
struct Capabilities {
    // engine / hardware / feature inventory
}

struct BackendOptions {
    // per-call options: timeout, limits, etc.
}

struct BackendResponse {
    // normalized solver response (status, decisions, score, certificate)
}

interface SolverBackend {
    BackendResponse solve   (CompiledModel compiled, BackendOptions options);
    BackendResponse diagnose(CompiledModel compiled, BackendOptions options);
    Capabilities    capabilities();
}

interface SolverResponseParser {
    BackendResponse parse(string raw);
}
```

Two implementations are shipped: `NavokojBackend` (hosted) and
`CommandSolverBackend` (local). Adapter authors implement these two interfaces.

---

## `reify.navokoj.client` — hosted execution

```d
struct RequestOptions {
    string apiKey;                  // or NAVOKOJ_API_KEY env
    string baseUrl = defaultBaseUrl;
    Duration transportTimeout;
    // … retry / id header fields
}

const string defaultBaseUrl;

class NavokojClient {
    this(HttpTransport transport = null);

    SolveResult solve   (CompiledModel compiled, RequestOptions options,
                         RoutingRecommendation recommendation);
    JSONValue   solveRaw(CompiledModel compiled, RequestOptions options,
                         RoutingRecommendation recommendation);
    JSONValue   diagnose(CompiledModel compiled, RequestOptions options);
    Capabilities capabilities(RequestOptions options);
}
```

`solve()` returns a fully-hydrated `SolveResult` (named decisions, score,
verification report). `solveRaw()` returns the wire JSON for debugging.

If `RequestOptions.apiKey` is empty, the client reads `NAVOKOJ_API_KEY` from
the environment. The base URL is validated to be HTTPS unless it is a
loopback address (for local testing).

---

## `reify.navokoj.backend` — hosted `SolverBackend` adapter

```d
class NavokojBackend : SolverBackend {
    this(HttpTransport transport = null);

    override BackendResponse solve   (CompiledModel compiled, BackendOptions options);
    override BackendResponse diagnose(CompiledModel compiled, BackendOptions options);
    override Capabilities    capabilities();
}
```

Wraps `NavokojClient` and implements the `SolverBackend` interface. Use this
when you want a uniform adapter across hosted and local paths.

---

## `reify.local.backend` — local SAT/MaxSAT adapters

```d
class CommandSolverBackend : SolverBackend {
    this(string id, string executable = "");

    override BackendResponse solve   (CompiledModel compiled, BackendOptions options);
    override BackendResponse diagnose(CompiledModel compiled, BackendOptions options);
    override Capabilities    capabilities();
}

CommandSolverBackend createLocalBackend(string id, string executable = "");

BackendResponse executeLocalWithFallback(
    CompiledModel compiled,
    BackendOptions options,
    RequestOptions hostedOptions   // for hosted fallback if available
);

SolveResult solveLocal(
    CompiledModel compiled,
    BackendOptions options = BackendOptions()
);
```

`createLocalBackend` looks up the id in the bundled adapter table. Recognized
ids include:

| Category | Adapters |
|----------|----------|
| DIMACS SAT | `kissat`, `glucose`, `minisat`, `cadical`, `cryptominisat` |
| WCNF MaxSAT | `open-wbo`, `loandra`, `maxhs`, `rc2`, `uwrmaxsat`, `pacose`, `wmaxcdcl`, `maxcdcl`, `evalmxsat` |

Before staging the artifact, the backend checks free disk space and throws
`DiskSpaceException` if there is not enough room. `executeLocalWithFallback`
falls back to the hosted engine (if credentials are present) when the local
subprocess fails.

---

## `reify.transport` — pluggable HTTP

```d
struct HttpResponse {
    int statusCode;
    string body;
    string[string] headers;
}

interface HttpTransport {
    HttpResponse request(string method, string url, string[string] headers,
                         string body, Duration timeout);
}

class CurlTransport : HttpTransport {
    this();
    override HttpResponse request(string method, string url,
                                  string[string] headers, string body,
                                  Duration timeout);
}
```

Pass any `HttpTransport` to `NavokojClient` or `NavokojBackend` to substitute
the HTTP layer (tests, custom proxies, etc.).

---

## `reify.router` — topology-driven routing

```d
struct RoutingRecommendation {
    string engine;    // "auto" | "nitro" | "qstate" | "hybrid" | …
    string hardware;  // "cpu" | "gpu" | …
    // … backend selection fields
}

RoutingRecommendation recommendRoute        (Model model);
RoutingRecommendation recommendRouteByTopology(TopologyAnalysis analysis);
```

The router inspects model topology (constraint kinds, variable counts, soft
weights) and returns an engine/hardware pair appropriate for the model shape.
You can override individual fields when constructing a `RequestOptions`.

---

## `reify.diagnostics` — topology analysis

```d
struct TopologyAnalysis {
    bool hasCategorical;
    bool hasInteger;
    bool hasParity;
    bool hasCardinality;
    bool hasWeightedSoft;
    size_t variableCount;
    size_t clauseCount;
    // … more fields
}

TopologyAnalysis analyzeModel   (Model model);
TopologyAnalysis analyzeCompiled(CompiledModel compiled);
```

The router consumes this. It is also useful for printing a model summary
before solving.

---

## `reify.result` — hydration and verification

The `SolveResult` is what execution paths return. It carries the named
decisions, the score, and a verification report that re-evaluates every
constraint against the returned assignment.

```d
enum DecisionStatus { assigned, unassigned, inconsistent }

struct DecisionValue {
    string name;
    DecisionStatus status;
    // … typed value
}

enum RunStatus { optimal, feasible, infeasible, timeout, error, unknown }

struct SolveResult {
    RunStatus status;
    DecisionValue[] decisions;
    Score score;
    VerificationReport verification;
    string[] warnings;
    string[] constraintNames;  // any domain-named constraints the solver broke
}

struct Score { /* objective value(s) */ }
struct ObjectiveResult { /* per-objective result */ }
struct VerificationReport {
    bool hardConstraintsSatisfied;
    bool softConstraintsSatisfied;
    ConstraintMatch[] matches;
}
struct ConstraintMatch { string name; MatchState state; }
enum MatchState { satisfied, violated, unknown }

struct NormalizedResponse { /* raw wire form */ }
```

Every assignment returned by the SDK is **re-verified locally** before it
leaves the result struct. The verification report is the trust boundary; raw
solver literals are not exposed as the public solution surface.

---

## `reify.explain` — decision audit trail

```d
struct DimensionInfo   { string name; size_t cardinality; }
struct ConstraintRecord{ string name; string expression; }
struct LogicalPlan {
    string[] dimensions;
    ConstraintRecord[] constraints;
    string[] objectiveNames;
}
struct PhysicalPlan {
    string engine;
    string hardware;
    size_t variableCount, clauseCount;
    double[] objectiveWeights;
}
struct SemanticImpact { string operationId; size_t clauseCount; }
struct ExecutionTrace { string[] steps; SemanticImpact[] impacts; }
struct VariableBlame   { string variable; string reason; }
struct DecisionExplanation {
    string variableName;
    VariableBlame[] blames;
    string[] violatedConstraints;
}

PhysicalPlan        explainPhysical(Model model);
ExecutionTrace      explainExecution(ref SolveResult result);
DecisionExplanation explainDecision(ref SolveResult result, Model model,
                                    string variableName);
LogicalPlan         explainLogical(DecisionSpace space);
```

Tie the audit trail to the model via `registerSemanticOperation` /
`enterSemanticOperation` / `leaveSemanticOperation` so the same operation id
threads from model → compiled clauses → solver trace → decision explanation.

---

## `reify.builders` — relational decision DSL

The builders module lets you describe a decision as a cartesian product of
typed dimensions, then add relational constraints at the space level instead of
at the variable level.

```d
struct DecisionCandidate { string[] tuple; }
struct DecisionGroup     { string[] keys; }

class DecisionSpace {
    void exactlyOne();
    void atMostOne();
    void atLeastOne();
    void between(size_t minCount, size_t maxCount);
    void atMost(size_t maxCount);
    void parityEven();
    void parityOdd();
    void preferAtLeastOne(double weight = 1.0);
    void preferAtMostOne (double weight = 1.0);
    void maximize(double weight = 1.0);
    void minimize(double weight = 1.0);
}

class TypedDecisionSpaceBuilder {
    // typed dimension registration; returns the builder for chaining
}

DecisionSpace          decisionSpace        (Model m, string spaceName);
TypedDecisionSpaceBuilder typedDecisionSpace(Model m, string spaceName);
```

Example:

```d
auto space = decisionSpace(m, "shift");
space.exactlyOne();

auto typed = typedDecisionSpace(m, "assignment")
    .addDimension("nurse", nurseKeys)
    .addDimension("shift", shiftKeys);
typed.exactlyOne();
```

---

## `reify.spacetime` — temporal scheduling

A finite temporal scheduling vocabulary on top of `Model`. The module is
intentionally scoped — it is a finite scheduling DSL, not a general
modal-logic engine.

```d
struct Dimension(string dimensionName_, ValueType_) { … }
struct TimeDimension(string dimensionName_, ValueType_) { … }
struct TimeWindow { long start, end; }
struct ConstraintRecipe { /* composable constraint */ }

// Recipe constructors
TimeWindow timeWindow(R)(R values);

ConstraintRecipe exactlyOnePer (string[] dimensions…);
ConstraintRecipe exactlyOnePer (Dimensions…)(…);
ConstraintRecipe nonOverlapping(string resourceDimension);
ConstraintRecipe nonOverlapping(ResourceDimension)(…);
ConstraintRecipe capacity     (string resourceDimension, size_t limit);
ConstraintRecipe capacity     (ResourceDimension)(long limit);
ConstraintRecipe prefer       (string value, double weight = 1.0);
ConstraintRecipe prefer       (string[] values, double weight = 1.0);
ConstraintRecipe prefer       (DimensionType)(…);

SpaceTime spaceTime(Model model, string name);
```

Recipes can be combined: each recipe lowers into the underlying `Model` as
hard/medium/soft constraints with semantic provenance attached.

---

## `reify.document` — JSON model ingest

```d
NavokojApp documentApp(string name, JSONValue document);
```

Parses a JSON model document (the same format `documentApp` accepts) and
returns a `NavokojApp` whose builder reflects that model. Used internally by
the `validate`, `compile`, `solve` CLI subcommands.

---

## `reify.dimacs` — raw DIMACS I/O

```d
struct DimacsLimits { /* size guards */ }
struct DimacsSerializeOptions { /* format flags */ }
class DimacsException : NavokojException { … }

struct DimacsInstance {
    size_t variableCount;
    long[][] clauses;
    // …
}

DimacsInstance   readDimacs  (string path, DimacsLimits limits = …);
DimacsInstance   parseDimacs (string text,  DimacsLimits limits = …);
void             writeDimacs (string path, DimacsInstance instance,
                             DimacsSerializeOptions options = …);
string           serializeDimacs(DimacsInstance instance,
                                 DimacsSerializeOptions options = …);
```

Use this when you need to ingest raw DIMACS or hand-craft a CNF for a known
benchmark — independent of the model IR.

---

## `reify.opb` — raw OPB I/O

```d
struct OpbLimits   { … }
struct OpbSerializeOptions { … }
class OpbException : NavokojException { … }

enum OpbRelation { ge, le, eq, gt, lt, ne }   // <,<=,=,!=,>=,>
enum OpbObjectiveSense { minimize, maximize }

struct OpbTerm      { long coefficient; int literal; }
struct OpbObjective { OpbObjectiveSense sense; OpbTerm[] terms; long constant; }
struct OpbConstraint{ OpbRelation relation; OpbTerm[] lhs; long rhs; }
struct OpbHeader    { size_t variables; … }
struct OpbInstance  { OpbHeader header; OpbConstraint[] constraints; OpbObjective objective; }

OpbInstance readOpb  (string path, OpbLimits limits = …);
OpbInstance parseOpb (string text,  OpbLimits limits = …);
void        writeOpb (string path, OpbInstance instance,
                     OpbSerializeOptions options = …);
string      serializeOpb(OpbInstance instance,
                         OpbSerializeOptions options = …);
```

OPB is the format for pseudo-Boolean constraints. Use it when a benchmark is
distributed in OPB or when you need to emit a model with PB constraints
intact.

---

## `reify.app` — CLI and orchestration

```d
struct AppSolveOptions {
    CompileOptions compilation;
    RequestOptions request;
}

final class NavokojApp {
    string name;
    this(string name, ModelBuilder builder, SolutionPresenter presenter = null);

    Model         build  (JSONValue input);
    CompiledModel compile(JSONValue input, CompileOptions options = CompileOptions());
    SolveResult   solve  (JSONValue input,
                          AppSolveOptions options = AppSolveOptions(),
                          HttpTransport  transport = null);
}

NavokojApp decisionApp(string name, void delegate(Model) buildDomain);
NavokojApp decisionApp(string name, ModelBuilder buildDomain,
                       SolutionPresenter presenter = null);

int    runNavokojApp(string[] args);     // CLI entry point
string navokojAppUsage();                // CLI help text
```

`decisionApp` is the typical entry point for an embedded program. The builder
is a function that takes a `Model` and a `JSONValue` input and adds variables,
constraints, and objectives. `runNavokojApp` parses `args` and dispatches to
`validate`, `compile`, `analyze`, `diagnose`, `solve`, or `capabilities`.

CLI flags:

| Flag | Effect |
|------|--------|
| `--api-key <token>` | Bearer key; default `NAVOKOJ_API_KEY` env |
| `--base-url <url>` | Override endpoint |
| `--engine <name>` | Hosted engine (default `auto` → router) |
| `--backend <name>` | Local SAT/MaxSAT command backend; `auto` keeps hosted routing |
| `--hardware <name>` | Hardware target |
| `--timeout <seconds>` | Solver budget |
| `--min-satisfaction <0..1>` | Stop at threshold |

---

## `reify.errors` — exception hierarchy

All exceptions derive from `NavokojException` (which extends `Exception`).

```d
class NavokojException : Exception { … }

class UnsupportedDomainException : NavokojException  // router-recognized domain boundary
class ModelException             : NavokojException  // invalid model
class CapabilityException        : NavokojException  // unrepresentable by any backend
class BackendException           : NavokojException  // local solver failure
class DiskSpaceException         : BackendException  // staging cannot fit the filesystem
class ProtocolException          : NavokojException  // wire contract violation

enum RequestDeliveryState { delivered, accepted, retryable, unrecoverable,
                            acceptanceUnknown }

class ApiException : NavokojException {
    RequestDeliveryState deliveryState;
    int    statusCode;
    string rawBody;
    string requestId;
}
```

| When you see | Likely cause |
|--------------|--------------|
| `ModelException` | Building a model with inconsistent expressions (e.g. expressions from different models) |
| `CapabilityException` | The model needs a feature the chosen backend cannot provide (e.g. soft constraints exported to CNF) |
| `UnsupportedDomainException` | Router classified the model as outside hosted scope (e.g. very large hardware BMC) |
| `BackendException` | Local solver subprocess failed to start or produced no parseable output |
| `DiskSpaceException` | Not enough room to stage the artifact for a local backend |
| `ApiException` | Hosted call failed; `deliveryState` tells you whether retry is safe |
| `ProtocolException` | The wire response did not match the expected schema |

---

## End-to-end example

A WCNF MaxSAT problem: each row of an addition must be unique (soft,
weighted) and the carries must compute correctly (hard).

```d
import reify;
import reify.exports;

auto m = new Model("send-more-money");

// Variables
auto s = m.booleanVar("S");
auto e = m.booleanVar("E");
auto n = m.booleanVar("N");
auto d = m.booleanVar("D");
auto mo = [m.booleanVar("M"), m.booleanVar("O"), m.booleanVar("R"), m.booleanVar("Y")];

// Hard: at most one of each letter
foreach (pair; [["S","E"],["N","D"],["M","O"]]) { … }

// Hard: no leading zero
m.require("no_leading_zero_S", !s);
m.require("no_leading_zero_M", !mo[0]);

// Soft: distinct letters (preference)
m.prefer("distinct", distinctExpr, /*weight=*/ 10.0);

// Objective
m.maximize("reward", rewardExpr);

// Compile and emit WCNF
auto wcnf = m.emit!WCNF();
writeln(wcnf.payload);
writeln(wcnf.verificationManifest.toPrettyString());

// Or solve directly via a local backend
import reify.local.backend;
auto compiled = m.compile();
auto result = solveLocal(compiled);
if (result.verification.hardConstraintsSatisfied)
    writeln("OK: ", result.decisions);
```

Same model, hosted path:

```d
import reify.navokoj.client;
import std.process : environment;

RequestOptions opts;
opts.apiKey = environment.get("NAVOKOJ_API_KEY", "");
opts.transportTimeout = dur!"seconds"(60);

auto client = new NavokojClient();
auto compiled = m.compile();
auto result = client.solve(compiled, opts, RoutingRecommendation("auto", "cpu"));
```

Same model, CLI:

```bash
reify solve --input send-more-money.json --backend open-wbo --timeout 60
```

---

## Solver adapter quick reference

| Adapter id | Format | Category |
|------------|--------|----------|
| `kissat` | DIMACS | SAT |
| `glucose` | DIMACS | SAT |
| `minisat` | DIMACS | SAT |
| `cadical` | DIMACS | SAT |
| `cryptominisat` | DIMACS | SAT |
| `open-wbo` | WCNF | MaxSAT |
| `loandra` | WCNF | MaxSAT |
| `maxhs` | WCNF | MaxSAT |
| `rc2` | WCNF | MaxSAT |
| `uwrmaxsat` | WCNF | MaxSAT |
| `pacose` | WCNF | MaxSAT |
| `wmaxcdcl` | WCNF | MaxSAT |
| `maxcdcl` | WCNF | MaxSAT |
| `evalmxsat` | WCNF | MaxSAT |

To use a custom binary, pass its path as the second argument to
`createLocalBackend(id, "/path/to/binary")` or to the `CommandSolverBackend`
constructor. Standard CLIs are supported as-is; unusual ones (e.g. RC2) may
need a wrapper or custom arguments.

---

## See also

- [`README.md`](README.md) — landing page and quickstart
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — module map, design rationale, capability matrix
- [`docs/DEVELOPER.md`](docs/DEVELOPER.md) — developer workflow
- [`docs/ENGINEERING.md`](docs/ENGINEERING.md) — engineer's overview
- [`examples/`](examples/) — runnable models
