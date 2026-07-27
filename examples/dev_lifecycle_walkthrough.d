// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Reify SDK Lifecycle Walkthrough
// ============================================================================
//
//  A 4-node, 3-color graph coloring used to exercise every stage of the SDK
//  lifecycle in a single runnable example. Pairs with docs/DEVELOPER.md.
//
//  Stages covered:
//    1. Author    — decisionApp signature
//    2. Build     — Model construction (also done internally by compile)
//    3. Validate  — semantic check, no API credits
//    4. Compile   — wire payload, no API credits
//    5. Analyze   — topology + routing recommendation, no API credits
//    6. Configure — AppSolveOptions
//    7. Solve     — needs NAVOKOJ_API_KEY (skipped if absent)
//    8. Inspect   — SolveResult, Solution, VerificationReport
//    9. Explain   — ExecutionTrace
//   10. Present   — JSON envelope
//   11. Diagnose  — physics-informed analysis (needs API key)
//
//  Build:
//    ldc2 -i examples/dev_lifecycle_walkthrough.d source/reify/package.d \
//        source/reify/errors.d source/reify/model.d source/reify/compiler.d \
//        source/reify/formula.d source/reify/dimacs.d source/reify/opb.d \
//        source/reify/result.d source/reify/backend.d source/reify/transport.d \
//        source/reify/diagnostics.d source/reify/router.d source/reify/app.d \
//        source/reify/document.d source/reify/builders.d source/reify/spacetime.d \
//        source/reify/exports.d source/reify/explain.d \
//        -Isource -of=build/dev-lifecycle-walkthrough
//
//  Run (no API key — stages 1-6 only):
//    ./build/dev-lifecycle-walkthrough
//
//  Run (with API key — full lifecycle):
//    export NAVOKOJ_API_KEY=...
//    ./build/dev-lifecycle-walkthrough
//
// ============================================================================

module dev_lifecycle_walkthrough;

import reify;
import std.json : JSONValue;
import std.process : environment;
import std.stdio : writeln;
import std.string : format, startsWith;

int main(string[] args) {
    writeln("==========================================================================");
    writeln("  Reify SDK Lifecycle Walkthrough");
    writeln("  (companion to docs/DEVELOPER.md)");
    writeln("==========================================================================");
    writeln();

    // ── Stage 1: Author ────────────────────────────────────────────────
    writeln("[Stage 1] Author");
    writeln("  Define the decision app: 4-node graph coloring with 3 colors.");
    writeln("  No ALO/AMO, no Tseitin, no DIMACS — just relations.");
    writeln();

    auto app = decisionApp("lifecycle-graph-coloring", (Model model) {
        // Categorical: each node picks exactly one of 3 colors.
        CategoryExpr[4] colorOf;
        foreach (i; 0 .. 4)
            colorOf[i] = model.categoricalVar(
                format("color[%s]", cast(char)('A' + i)),
                ["red", "green", "blue"]
            );

        // Adjacent nodes must differ.
        foreach (edge; [[0,1], [1,2], [2,3], [0,3]])
            model.require(
                format("edge[%s,%s]",
                    cast(char)('A' + edge[0]),
                    cast(char)('A' + edge[1])),
                colorOf[edge[0]].different(colorOf[edge[1]])
            );
    }, (JSONValue input, Solution solution) {
        // Presenter: emit only the per-node color assignment.
        JSONValue[string] out_;
        foreach (name; solution.keys) {
            if (name.startsWith("color["))
                out_[name] = solution.get(name).toJson();
        }
        return JSONValue(out_);
    });

    // ── Stage 2: Build ─────────────────────────────────────────────────
    writeln("[Stage 2] Build (no API call)");
    writeln("  Constructing the symbolic Model — no HTTP, no credits.");
    auto model = app.build(JSONValue());
    writeln("  Model name      : ", model.name);
    writeln("  Variables       : ", model.variables.length);
    writeln("  Constraints     : ", model.constraints.length);
    writeln();

    // ── Stage 3: Validate ──────────────────────────────────────────────
    writeln("[Stage 3] Validate (no API credits)");
    writeln("  Semantic checks: domain bounds, ALO/AMO, Tseitin well-formedness.");
    try {
        validateModel(model);
        writeln("  OK — Model is structurally well-formed.");
    } catch (ModelException e) {
        writeln("  FAIL — ", e.msg);
        return 1;
    }
    writeln();

    // ── Stage 4: Compile ───────────────────────────────────────────────
    writeln("[Stage 4] Compile (no API credits)");
    writeln("  Lowering to wire payload: CNF/WCNF/hybrid CNF+XOR/Q-State.");
    auto compiled = app.compile(JSONValue(), CompileOptions());
    writeln("  Backend chosen  : ", backendName(compiled.backend));
    writeln("  Wire payload keys:");
    foreach (key; compiled.request.object.byKey)
        writeln("    - ", key);
    writeln();

    // ── Stage 5: Analyze ───────────────────────────────────────────────
    writeln("[Stage 5] Analyze (no API credits)");
    writeln("  Topology + routing recommendation.");
    auto analysis = analyzeModel(model);
    writeln("  Logical variables : ", analysis.logicalVariables);
    writeln("  Clause count      : ", analysis.clauseCount);
    writeln("  alpha (M/N)       : ", format("%.3f", analysis.alpha));
    writeln("  Near phase trans. : ", analysis.nearPhaseTransition);
    writeln("  Classification    : ", analysis.structureClassification);
    writeln("  Suggested action  : ", analysis.suggestedAction);
    if (analysis.bottleneckWarnings.length > 0) {
        writeln("  Bottleneck warnings:");
        foreach (w; analysis.bottleneckWarnings)
            writeln("    ! ", w);
    }
    writeln();

    // ── Stage 6: Configure ─────────────────────────────────────────────
    writeln("[Stage 6] Configure Solve Options");
    AppSolveOptions options;
    options.compilation.engine = "nitro"; // override the auto router
    options.request.apiKey = environment.get("NAVOKOJ_API_KEY", "");
    writeln("  Engine override  : ", options.compilation.engine);
    writeln("  API key present  : ", options.request.apiKey.length > 0);
    writeln();

    bool haveKey = options.request.apiKey.length > 0;
    SolveResult result;

    // ── Stage 7: Solve ─────────────────────────────────────────────────
    if (haveKey) {
        writeln("[Stage 7] Solve (live Navokoj call)");
        result = app.solve(JSONValue(), options);
        writeln("  Status           : ", result.status);
        writeln("  Feasible         : ", result.feasible);
    } else {
        writeln("[Stage 7] Solve — SKIPPED (no NAVOKOJ_API_KEY)");
        writeln("  Stages 8-11 require a key. Run with:");
        writeln("    export NAVOKOJ_API_KEY=...");
        writeln("    ./build/dev-lifecycle-walkthrough");
    }
    writeln();

    // ── Stage 8: Inspect ───────────────────────────────────────────────
    if (haveKey) {
        writeln("[Stage 8] Inspect Result");
        writeln("  Hard satisfied   : ", result.verification.hardSatisfied);
        writeln("  Hard violated    : ", result.verification.hardViolated);
        if (result.solution !is null) {
            writeln("  Assignment:");
            foreach (name; result.solution.keys)
                writeln("    ", name, " = ",
                        result.solution.get(name).toJson().toString);
        }
        writeln();
    }

    // ── Stage 9: Explain ───────────────────────────────────────────────
    if (haveKey) {
        writeln("[Stage 9] Explain");
        auto trace = explainExecution(result);
        writeln("  Engine used      : ", trace.selectedEngine);
        writeln("  Solve time       : ", format("%.0f", trace.solveTimeMs), " ms");
        writeln();
    }

    // ── Stage 10: Present ──────────────────────────────────────────────
    if (haveKey) {
        writeln("[Stage 10] Present");
        auto envelope = app.present(JSONValue(), result);
        writeln("  Envelope keys:");
        foreach (key; envelope.object.byKey)
            writeln("    - ", key);
        writeln();
    }

    // ── Stage 11: Diagnose ─────────────────────────────────────────────
    if (haveKey) {
        writeln("[Stage 11] Diagnose (Chebyshev bias + Betti numbers)");
        auto diag = app.diagnose(JSONValue(), options);
        writeln("  Diagnostic envelope keys:");
        foreach (key; diag.object.byKey)
            writeln("    - ", key);
    } else {
        writeln("[Stage 11] Diagnose — SKIPPED (no API key)");
    }
    writeln();
    writeln("==========================================================================");
    writeln("  Walkthrough complete.");
    writeln("==========================================================================");

    if (!haveKey) return 0;
    return result.feasible ? 0 : 1;
}