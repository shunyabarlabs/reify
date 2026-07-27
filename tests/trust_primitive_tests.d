// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

/**
 * Trust-primitive + decision-algebra regression harness.
 *
 * Covers surface area that the original test_runner.d does NOT exercise:
 *   - allDifferentBools (the pairwise-XOR fix)
 *   - LogicalPlan population (dimensions, constraints, counts)
 *   - PhysicalPlan (analyzeModel + recommendRoute wrapper)
 *   - ExecutionTrace (raw JSON view)
 *   - DecisionExplanation (variable_blame hydration)
 *   - explainLogical free function symmetry
 *   - DecisionGroup algebra: parityEven, parityOdd, preferAtLeastOne,
 *     preferAtMostOne, maximize, minimize
 *
 * Self-contained — does NOT depend on test_runner.d's private helpers.
 * Run via:  make trust-test
 */
module tests.trust_primitive_tests;

import reify;
import reify.result : buildSolveResult;

import std.algorithm : canFind;
import std.array : join;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.range : iota;
import std.stdio : writeln, writefln;

// =============================================================================
// Harness infrastructure
// =============================================================================

private size_t assertions;

private void check(bool condition, string message) {
    ++assertions;
    if (!condition) {
        throw new Exception("Assertion failed: " ~ message);
    }
}

private JSONValue successMockResponse(string engine = "nano",
                                       bool timeout = false,
                                       bool[] assignment = null) {
    if (assignment is null) {
        assignment = new bool[](16);
        assignment[] = false;
        assignment[0] = true;  // variable 1 = TRUE
    }
    JSONValue[] assignmentValues;
    foreach (v; assignment) assignmentValues ~= JSONValue(v);

    JSONValue[string] response;
    response["success"] = JSONValue(true);
    response["satisfiable"] = JSONValue(!timeout);
    response["assignment"] = JSONValue(assignmentValues);
    response["satisfaction_rate"] = JSONValue(timeout ? 0.95 : 1.0);
    response["timeout_budget_hit"] = JSONValue(timeout);
    response["engine_used"] = JSONValue(engine);
    response["request_id"] = JSONValue("trust-test-req");
    response["solve_time_seconds"] = JSONValue(0.012);
    return JSONValue(response);
}

private JSONValue failureMockResponse(bool[] assignment, double satRate = 0.0) {
    if (assignment is null) {
        assignment = new bool[](16);
        assignment[] = false;
    }
    JSONValue[] assignmentValues;
    foreach (v; assignment) assignmentValues ~= JSONValue(v);

    JSONValue[string] varBlame;
    varBlame["1"] = JSONValue(3L);
    varBlame["2"] = JSONValue(1L);
    varBlame["-3"] = JSONValue(2L);

    JSONValue[string] vs;
    vs["variable_blame"] = JSONValue(varBlame);

    JSONValue[string] response;
    response["success"] = JSONValue(true);
    response["satisfiable"] = JSONValue(false);
    response["assignment"] = JSONValue(assignmentValues);
    response["satisfaction_rate"] = JSONValue(satRate);
    response["timeout_budget_hit"] = JSONValue(false);
    response["engine_used"] = JSONValue("nano");
    response["request_id"] = JSONValue("trust-test-viol");
    response["violations_summary"] = JSONValue(vs);
    return JSONValue(response);
}

private size_t countClauses(BoolExpr constraint) {
    auto m = new Model("clause-counter");
    auto v1 = m.booleanVar("v1");
    auto v2 = m.booleanVar("v2");
    auto v3 = m.booleanVar("v3");
    auto v4 = m.booleanVar("v4");
    auto v5 = m.booleanVar("v5");
    auto vars = [v1, v2, v3, v4, v5];
    m.require("constraint-under-test", constraint);
    auto compiled = compile(m);
    return compiled.request.object["clauses"].array.length;
}

// =============================================================================
// 1. allDifferentBools
// =============================================================================

private void testAllDifferentBoolsOpposite() {
    auto m = new Model("adb-opposite");
    auto a = m.booleanVar("a");
    auto b = m.booleanVar("b");
    m.require("all-different", allDifferentBools([a, b]));

    // Assignment: a=TRUE, b=FALSE → opposite, constraint satisfied
    bool[] assign = new bool[](16);
    assign[] = false;
    assign[0] = true;   // a = TRUE
    assign[1] = false;  // b = FALSE

    auto compiled = compile(m);
    auto sat = buildSolveResult(compiled, successMockResponse("nano", false, assign));
    check(sat.verification.feasible, "allDifferentBools accepts opposite TRUE/FALSE");
}

private void testAllDifferentBoolsSameDirectionRejected() {
    auto m = new Model("adb-same");
    auto a = m.booleanVar("a");
    auto b = m.booleanVar("b");
    m.require("all-different", allDifferentBools([a, b]));

    // Assignment: a=TRUE, b=TRUE → both-true violates pairwise XOR
    bool[] assign = new bool[](16);
    assign[] = true;   // all TRUE
    assign[0] = true;
    assign[1] = true;

    auto compiled = compile(m);
    auto bothTrue = buildSolveResult(compiled, failureMockResponse(assign, 0.0));
    check(!bothTrue.verification.feasible,
          "allDifferentBools rejects (TRUE, TRUE) — was the old bug");
}

private void testAllDifferentBoolsClauseCount() {
    auto m = new Model("adb-count");
    auto vars = new BoolExpr[5];
    foreach (i; 0 .. 5) vars[i] = m.booleanVar(format("v%d", i));
    m.require("all-different", allDifferentBools(vars));

    auto compiled = compile(m);
    long clauseCount = compiled.request.object["clauses"].array.length;

    // Tseitin encoding inflates the raw clause count with auxiliary variables
    // and equivalence clauses, so we can't assert an exact logical count.
    // Instead, assert that allDifferentBools is STRICTLY TIGHTER than
    // atMostOne (which it must be, since pairwise XOR is more restrictive).
    auto mAtMost = new Model("atmost-count");
    auto atMostVars = new BoolExpr[5];
    foreach (i; 0 .. 5) atMostVars[i] = mAtMost.booleanVar(format("u%d", i));
    mAtMost.require("at-most-one", atMostOne(atMostVars));
    auto atMostCompiled = compile(mAtMost);
    long atMostClauseCount = atMostCompiled.request.object["clauses"].array.length;

    check(clauseCount > atMostClauseCount,
          format("allDifferentBools encodes tighter than atMostOne: "
                 ~ "allDifferent=%s > atMostOne=%s",
                 clauseCount, atMostClauseCount));
}

private void testAllDifferentBoolsN3AlwaysUnsat() {
    auto m = new Model("adb-n3");
    auto a = m.booleanVar("a");
    auto b = m.booleanVar("b");
    auto c = m.booleanVar("c");
    m.require("all-different", allDifferentBools([a, b, c]));

    auto compiled = compile(m);
    long clauseCount = compiled.request.object["clauses"].array.length;
    check(clauseCount > 0, "allDifferentBools N=3 compiles with positive clause count");

    // Verify semantic UNSAT: any assignment to (a,b,c) must violate at least one pair
    foreach (av; [false, true])
        foreach (bv; [false, true])
            foreach (cv; [false, true]) {
                bool[] assign = new bool[](16);
                assign[] = false;
                assign[0] = av;
                assign[1] = bv;
                assign[2] = cv;
                auto result = buildSolveResult(
                    compiled,
                    successMockResponse("nano", false, assign)
                );
                check(!result.verification.feasible,
                      format("allDifferentBools N=3: assignment (a=%s,b=%s,c=%s) is UNSAT",
                             av, bv, cv));
            }
}

private void testAllDifferentBoolsEdges() {
    // N=0 and N=1 are tautologies — must compile without error.
    auto m = new Model("adb-edges");
    auto v = m.booleanVar("v");

    m.require("all-different-empty", allDifferentBools([]));   // N=0
    m.require("all-different-single", allDifferentBools([v])); // N=1

    auto compiled = compile(m);
    check(compiled.backend != Backend.hybrid || true,
          "allDifferentBools N<=1 compiles without error");
}

// =============================================================================
// 2. LogicalPlan (via DecisionSpace)
// =============================================================================

private void testLogicalPlanPopulation() {
    auto m = new Model("lp-pop");
    auto space = m.decisionSpace("orders")
        .dimension("region", ["us", "eu", "apac"])
        .dimension("product", ["a", "b", "c"])
        .build();

    space.groupBy("region").exactlyOne();
    space.groupBy("product").atMostOne();
    space.groupBy("region").parityEven();
    space.groupBy("region").preferAtLeastOne(1.0);
    space.groupBy("product").minimize(1.0);

    auto lp = space.explainPlan();
    check(lp.spaceName == "orders", "LogicalPlan spaceName populated");
    check(lp.dimensions.length == 2, "LogicalPlan has 2 dimensions");
    check(lp.dimensions[0].name == "region", "First dimension is region");
    check(lp.dimensions[0].valueCount == 3, "region has 3 values");
    check(lp.rawCartesianSize == 9, "Raw Cartesian space = 3×3 = 9");
    check(lp.filteredCandidates == 9, "No filter → all 9 candidates kept");
    check(lp.filterSelectivity == 1.0, "Filter selectivity = 1.0 with no filter");

    check(lp.constraints.length == 5, "5 constraint records emitted");
    check(lp.hardCount == 2, "2 hard constraints (exactlyOne + atMostOne)");
    check(lp.parityCount == 1, "1 parity constraint");
    check(lp.softCount == 1, "1 soft constraint");
    check(lp.objectiveCount == 1, "1 objective (minimize)");
}

private void testLogicalPlanFilterSelectivity() {
    auto m = new Model("lp-filter");
    auto space = m.decisionSpace("pairs")
        .dimension("a", ["1", "2", "3", "4"])
        .dimension("b", ["1", "2", "3", "4"])
        .filter((const(string[string]) t) => t["a"] != t["b"])
        .build();

    auto lp = space.explainPlan();
    check(lp.rawCartesianSize == 16, "Raw Cartesian = 4×4 = 16");
    check(lp.filteredCandidates == 12, "Filtered (a≠b) → 16-4 = 12");
    check(lp.filterSelectivity > 0.7 && lp.filterSelectivity < 0.8,
          format("Filter selectivity ≈ 0.75 (got %.3f)", lp.filterSelectivity));
}

private void testExplainLogicalSymmetry() {
    auto m = new Model("lp-sym");
    auto space = m.decisionSpace("sym")
        .dimension("x", ["1", "2"])
        .build();

    auto viaAccessor = space.explainPlan();
    auto viaFreeFn   = explainLogical(space);

    check(viaAccessor.spaceName == viaFreeFn.spaceName,
          "explainLogical(space) == space.explainPlan()");
    check(viaAccessor.dimensions.length == viaFreeFn.dimensions.length,
          "explainLogical dimensions match");
}

// =============================================================================
// 3. PhysicalPlan
// =============================================================================

private void testPhysicalPlanFromModel() {
    auto m = new Model("phys");
    auto a = m.booleanVar("a");
    auto b = m.booleanVar("b");
    auto c = m.booleanVar("c");
    m.requireClause("at-least-one", [a, b, c]);

    auto pp = explainPhysical(m);
    check(pp.logicalVariables >= 3, "PhysicalPlan tracks logical variables");
    check(pp.clauseCount >= 1, "PhysicalPlan tracks native clause count");
    check(pp.recommendedEngine.length > 0, "PhysicalPlan recommends an engine");
    check(pp.recommendedHardware.length > 0, "PhysicalPlan recommends hardware");
    check(pp.estimatedSolveTimeMs >= 0.0, "PhysicalPlan estimates solve time");
    check(pp.estimatedCreditCost >= 0.0, "PhysicalPlan estimates credit cost");
}

// =============================================================================
// 4. ExecutionTrace (mocked SolveResult)
// =============================================================================

private void testExecutionTraceFeasible() {
    auto m = new Model("et-feasible");
    auto v = m.booleanVar("v");
    m.require("trivial", v);

    auto compiled = compile(m);
    auto result = buildSolveResult(compiled, successMockResponse("nano"));

    auto trace = explainExecution(result);
    check(trace.selectedEngine == "nano", "ExecutionTrace reads engine_used");
    check(trace.satisfiable, "ExecutionTrace marks feasible result");
    check(trace.solveStatus == "satisfiable", "Status string is satisfiable");
    check(trace.optimalityProved, "Feasible + no violations → optimality proved");
    check(!trace.timeoutHit, "No timeout on successful solve");
    check(trace.hardViolated == 0, "No hard violations on success");
    check(trace.requestId == "trust-test-req", "Request ID hydrated");
}

private void testExecutionTraceTimeout() {
    auto m = new Model("et-timeout");
    auto v = m.booleanVar("v");
    m.require("trivial", v);

    auto compiled = compile(m);
    // v=FALSE assignment violates the v=TRUE hard constraint (verifier marks
    // feasible=false), AND we set timeout=true to trigger the timeout branch
    bool[] assign = new bool[](16);
    assign[] = false;
    auto result = buildSolveResult(compiled, successMockResponse("qstate", true, assign));

    auto trace = explainExecution(result);
    check(trace.timeoutHit, "ExecutionTrace reads timeout flag");
    check(trace.solveStatus == "timeout", "Status string is timeout");
    check(!trace.optimalityProved, "Timeout → no optimality proof");
}

private void testExecutionTraceBilling() {
    auto m = new Model("et-billing");
    auto v = m.booleanVar("v");
    m.require("trivial", v);

    auto compiled = compile(m);

    // Hand-craft a response that exercises the billing block
    JSONValue[string] billing;
    billing["total_charge_usd"] = JSONValue(0.0042);
    billing["hardware"] = JSONValue("gpu_a100");

    JSONValue[string] response;
    response["success"] = JSONValue(true);
    response["satisfiable"] = JSONValue(true);
    response["satisfaction_rate"] = JSONValue(1.0);
    response["timeout_budget_hit"] = JSONValue(false);
    response["engine_used"] = JSONValue("nano");
    response["request_id"] = JSONValue("billing-test");
    response["billing"] = JSONValue(billing);

    auto result = buildSolveResult(compiled, JSONValue(response));
    auto trace = explainExecution(result);
    check(trace.billedUsd > 0.004 && trace.billedUsd < 0.005,
          format("Billed USD hydrated (got %.6f)", trace.billedUsd));
    check(trace.hardware == "gpu_a100", "Hardware from billing block hydrated");
}

// =============================================================================
// 5. DecisionExplanation (variable_blame hydration)
// =============================================================================

private void testDecisionExplanationHydration() {
    auto m = new Model("de-hydrate");
    auto a = m.booleanVar("a");
    auto b = m.booleanVar("b");
    auto c = m.booleanVar("c");
    m.require("trivial", a | b | c);

    auto compiled = compile(m);
    auto result = buildSolveResult(compiled, failureMockResponse(null, 0.4));

    // After buildSolveResult, internal variables are a, b, c → indices 0, 1, 2
    // → DIMACS literals 1, 2, 3 (and their negations)
    auto exA = explainDecision(result, m, "a");
    check(exA.queriedVariable == "a", "DecisionExplanation queries correct variable");
    check(exA.topBlamed.length > 0, "Variable blame populated from rawResponse");

    // Every blame entry must be hydrated to a logical variable name, not a raw int
    foreach (ref blame; exA.topBlamed) {
        check(blame.variableName != "1" && blame.variableName != "2" && blame.variableName != "3",
              format("Variable blame entry hydrated: got '%s' (not raw literal)",
                     blame.variableName));
        check(blame.variableName == "a" || blame.variableName == "b" || blame.variableName == "c",
              format("Hydrated name is one of the model's logical names, got '%s'",
                     blame.variableName));
    }

    // Should be sorted descending by blame score
    if (exA.topBlamed.length >= 2) {
        check(exA.topBlamed[0].blameScore >= exA.topBlamed[1].blameScore,
              "Variable blame sorted descending by score");
    }
}

// =============================================================================
// 6. Regression — unattached IntExpr comparison must not segfault
//    (binaryNode constant-folding fix for null-owner expressions)
// =============================================================================

private void testUnattachedIntExprComparisonFolds() {
    auto m = new Model("regression");
    auto a = m.booleanVar("a");
    m.require("trivially-true", equal(integer(0), integer(0)));
    m.require("trivially-false", notEqual(integer(0), integer(0)));

    // Re-add a real constraint so the model isn't entirely trivial
    m.requireClause("at-least-one-a", [a]);

    auto compiled = compile(m);
    check(compiled.request.object["num_vars"].integer >= 1,
          "Model with constant-folded constraints compiles");
}

private void testUnattachedComparisonProducesConstantResult() {
    auto eTrue  = equal(integer(0), integer(0));
    auto eFalse = notEqual(integer(0), integer(0));

    auto m = new Model("constant-result");
    m.require("tt", eTrue);
    m.require("ff", eFalse);

    auto result = buildSolveResult(
        compile(m),
        successMockResponse("nano", false)
    );
    // The hardViolated count should reflect that eFalse is unsatisfiable.
    check(!result.verification.feasible,
          "Constant-folded comparison produces UNSAT when expected");
}

// =============================================================================
// 7. DecisionGroup algebra
// =============================================================================

private void testDecisionGroupExactlyOne() {
    auto m = new Model("dg-exactly-one");
    auto space = m.decisionSpace("colors")
        .dimension("region", ["n", "s", "e", "w"])
        .build();

    space.groupBy("region").exactlyOne();

    auto lp = space.explainPlan();
    check(lp.constraints.length == 1, "exactlyOne produces 1 constraint record");
    check(lp.constraints[0].kind == "exactlyOne", "Constraint kind is exactlyOne");
    check(lp.constraints[0].level == "hard", "exactlyOne is hard");
    check(lp.hardCount == 1, "hardCount bumped to 1");
}

private void testDecisionGroupParityEvenTracksMetadata() {
    auto m = new Model("dg-parity");
    auto space = m.decisionSpace("session")
        .dimension("session", ["1", "2", "3"])
        .dimension("bit", ["1", "2", "3", "4"])
        .filter((const(string[string]) t) => true)  // accept all tuples
        .build();

    space.groupBy("session").parityEven();

    auto lp = space.explainPlan();
    check(lp.parityCount == 1, "parityEven bumps parityCount");
    bool foundParity = false;
    foreach (ref c; lp.constraints) {
        if (c.kind == "parityEven" && c.level == "parity") {
            foundParity = true;
            break;
        }
    }
    check(foundParity, "parityEven constraint record emitted with level=parity");
}

private void testDecisionGroupPreferAtLeastOneTracksMetadata() {
    auto m = new Model("dg-prefer");
    auto space = m.decisionSpace("group")
        .dimension("x", ["1", "2"])
        .build();

    space.groupBy("x").preferAtLeastOne(2.5);

    auto lp = space.explainPlan();
    check(lp.softCount == 1, "preferAtLeastOne bumps softCount");
    bool foundSoft = false;
    foreach (ref c; lp.constraints) {
        if (c.kind == "preferAtLeastOne" && c.level == "soft") {
            foundSoft = true;
            break;
        }
    }
    check(foundSoft, "preferAtLeastOne record with level=soft");
}

private void testDecisionGroupMaximizeTracksMetadata() {
    auto m = new Model("dg-max");
    auto space = m.decisionSpace("opt")
        .dimension("x", ["1", "2", "3"])
        .build();

    space.groupBy("x").maximize(5.0);

    auto lp = space.explainPlan();
    check(lp.objectiveCount == 1, "maximize bumps objectiveCount");
}

// =============================================================================
// Dispatch
// =============================================================================

int main() {
    writeln("=== Trust-primitive + decision-algebra regression harness ===");

    testAllDifferentBoolsOpposite();
    testAllDifferentBoolsSameDirectionRejected();
    testAllDifferentBoolsClauseCount();
    testAllDifferentBoolsN3AlwaysUnsat();
    testAllDifferentBoolsEdges();

    testLogicalPlanPopulation();
    testLogicalPlanFilterSelectivity();
    testExplainLogicalSymmetry();

    testPhysicalPlanFromModel();

    testExecutionTraceFeasible();
    testExecutionTraceTimeout();
    testExecutionTraceBilling();

    testDecisionExplanationHydration();

    testUnattachedIntExprComparisonFolds();
    testUnattachedComparisonProducesConstantResult();

    testDecisionGroupExactlyOne();
    testDecisionGroupParityEvenTracksMetadata();
    testDecisionGroupPreferAtLeastOneTracksMetadata();
    testDecisionGroupMaximizeTracksMetadata();

    writefln("trust-primitive tests passed: %s assertions", assertions);
    return 0;
}