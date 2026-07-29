// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module tests.test_runner;

import reify;
import reify.navokoj.client : NavokojClient, RequestOptions;
import reify.transport : HttpResponse, HttpTransport;
import reify.document : documentApp;
import reify.result : buildSolveResult, normalizeResponse;

import std.algorithm : canFind;
import std.conv : to;
import std.datetime : Duration, dur;
import std.file : readText;
import std.json : JSONType, JSONValue, parseJSON;
import std.stdio : writeln;

private size_t assertions;

private void check(bool condition, string message) {
    ++assertions;
    if (!condition) {
        throw new Exception("Assertion failed: " ~ message);
    }
}

private void testBooleanCompilation() {
    auto model = new Model("boolean-service");
    auto gateway = model.booleanVar("gateway");
    auto database = model.booleanVar("database");
    auto cache = model.booleanVar("cache");

    model.require("gateway needs database", implies(gateway, database));
    model.prefer(
        "database prefers cache",
        implies(database, cache),
        4
    );

    CompileOptions options;
    options.preferQState = false;
    auto compiled = compile(model, options);

    check(compiled.backend == Backend.cnf, "Boolean model selects CNF");
    check(
        compiled.request.object["num_vars"].integer >= 3,
        "CNF includes declared variables"
    );
    check(
        compiled.request.object["clauses"].array.length > 2,
        "Tseitin clauses are emitted"
    );
    check(
        compiled.request.object["weights"].array.length ==
            compiled.request.object["clauses"].array.length,
        "Every CNF clause has a weight"
    );
}

private void testQStateCompilationAndHydration() {
    auto model = new Model("exam");
    auto first = model.categoricalVar(
        "exam[first]",
        ["morning", "afternoon", "evening"]
    );
    auto second = model.categoricalVar(
        "exam[second]",
        ["morning", "afternoon", "evening"]
    );
    auto third = model.categoricalVar(
        "exam[third]",
        ["morning", "afternoon", "evening"]
    );

    model.require(
        "different first and second",
        first.different(second)
    );
    model.require(
        "all slots distinct",
        allDifferent([first, second, third])
    );

    auto compiled = compile(model);
    check(compiled.backend == Backend.qstate, "Categorical model selects Q-State");
    check(
        compiled.request.object["num_states"].integer == 3,
        "Q-State state count is preserved"
    );

    CompileOptions hardwareOptions;
    hardwareOptions.hardware = "l4";
    auto hardwareCompiled = compile(model, hardwareOptions);
    check(
        ("problem_type" in hardwareCompiled.request.object) !is null &&
        ("engine" in hardwareCompiled.request.object) is null,
        "Hardware Q-State uses the documented geometric wire profile"
    );

    JSONValue[string] assignment;
    assignment["1"] = JSONValue(1L);
    assignment["2"] = JSONValue(2L);
    assignment["3"] = JSONValue(3L);
    JSONValue[string] response;
    response["success"] = JSONValue(true);
    response["satisfiable"] = JSONValue(true);
    JSONValue[string] nested;
    nested["assignment"] = JSONValue(assignment);
    nested["satisfaction_rate"] = JSONValue(1.0);
    response["solution"] = JSONValue(nested);

    auto result = buildSolveResult(compiled, JSONValue(response));
    check(result.feasible, "Hydrated Q-State result verifies");
    check(
        result.solution.get("exam[first]").categoricalValue == "morning",
        "One-based Q-State values hydrate to domain states"
    );
    check(
        result.solution.get("exam[third]").categoricalValue == "evening",
        "Every Q-State decision is hydrated"
    );
}

private JSONValue cnfResponseFor(
    CompiledModel compiled,
    long[string] values,
    bool timeout = false
) {
    bool[] assignment = new bool[](compiled.generatedVariableCount);
    assignment[] = false;

    foreach (logicalIndex, variable; compiled.model.variables) {
        auto found = variable.name in values;
        if (found is null) {
            continue;
        }

        if (variable.kind == VariableKind.integer) {
            foreach (
                thresholdIndex, thresholdLiteral;
                compiled.integerOrderLiterals[logicalIndex]
            ) {
                const thresholdValue =
                    variable.lowerBound + cast(long) thresholdIndex + 1;
                assignment[thresholdLiteral - 1] =
                    *found >= thresholdValue;
            }
            continue;
        }

        foreach (atom; compiled.atoms[logicalIndex]) {
            const satIndex = cast(size_t) (
                atom.literalWhenSelected < 0
                    ? -atom.literalWhenSelected
                    : atom.literalWhenSelected
            ) - 1;
            if (atom.value == *found) {
                assignment[satIndex] =
                    atom.literalWhenSelected > 0;
            } else if (atom.literalWhenSelected > 0) {
                assignment[satIndex] = false;
            }
        }
    }

    JSONValue[] assignmentValues;
    foreach (value; assignment) {
        assignmentValues ~= JSONValue(value);
    }
    JSONValue[string] response;
    response["success"] = JSONValue(true);
    response["satisfiable"] = JSONValue(!timeout);
    response["assignment"] = JSONValue(assignmentValues);
    response["satisfaction_rate"] = JSONValue(timeout ? 0.95 : 1.0);
    response["timeout_budget_hit"] = JSONValue(timeout);
    response["engine_used"] = JSONValue("nano");
    response["request_id"] = JSONValue("test-request");
    return JSONValue(response);
}

private void testFiniteArithmeticAndObjectives() {
    auto model = new Model("crop");
    auto wheat = model.integerVar("acres[wheat]", 0, 4);
    auto chickpea = model.integerVar("acres[chickpea]", 0, 4);

    model.require(
        "field capacity",
        lessEqual(wheat + chickpea, integer(4))
    );
    model.require(
        "minimum chickpea",
        greaterEqual(chickpea, integer(1))
    );
    model.prefer(
        "rotation preference",
        greaterEqual(chickpea, integer(2)),
        2
    );
    model.maximize(
        "profit",
        30 * wheat + 22 * chickpea
    );

    auto compiled = compile(model);
    check(compiled.backend == Backend.cnf, "Arithmetic model selects CNF");

    long[string] values;
    values["acres[wheat]"] = 2;
    values["acres[chickpea]"] = 2;
    auto result = buildSolveResult(
        compiled,
        cnfResponseFor(compiled, values)
    );

    check(result.feasible, "Finite arithmetic result verifies locally");
    check(
        result.solution.get("acres[wheat]").integerValue == 2,
        "Integer one-hot assignment hydrates"
    );
    check(
        result.verification.softViolated == 0,
        "Soft constraints are evaluated against domain values"
    );
    check(
        result.objectives.length == 1 &&
        result.objectives[0].known &&
        result.objectives[0].value == 104,
        "Linear objective is recomputed from hydrated domain values"
    );
    check(
        result.verification.matches[0].variables.length == 2,
        "Constraint explanations retain participating decisions"
    );
}

private bool cnfSatisfiable(
    CompiledModel compiled,
    long[string] decisions
) {
    int[][] clauses;
    foreach (clause; compiled.clauses) {
        clauses ~= clause.literals.dup;
    }

    foreach (logicalIndex, variable; compiled.model.variables) {
        auto selected = variable.name in decisions;
        if (selected is null) {
            continue;
        }

        final switch (variable.kind) {
            case VariableKind.boolean:
            case VariableKind.categorical:
                foreach (atom; compiled.atoms[logicalIndex]) {
                    const selectedLiteral =
                        atom.value == *selected
                            ? atom.literalWhenSelected
                            : -atom.literalWhenSelected;
                    clauses ~= [selectedLiteral];
                }
                break;

            case VariableKind.integer:
                foreach (
                    thresholdIndex, literal;
                    compiled.integerOrderLiterals[logicalIndex]
                ) {
                    const threshold =
                        variable.lowerBound + cast(long) thresholdIndex + 1;
                    clauses ~= [*selected >= threshold ? literal : -literal];
                }
                break;
        }
    }

    int[] assignment = new int[](compiled.generatedVariableCount + 1);
    assignment[] = -1;

    bool solve(int[] current) {
        bool changed = true;
        while (changed) {
            changed = false;
            foreach (clause; clauses) {
                bool satisfied;
                int unknownLiteral;
                size_t unknownCount;
                foreach (literal; clause) {
                    const variable = literal < 0 ? -literal : literal;
                    const value = current[variable];
                    if (value == -1) {
                        unknownLiteral = literal;
                        ++unknownCount;
                    } else if (
                        (literal > 0 && value == 1) ||
                        (literal < 0 && value == 0)
                    ) {
                        satisfied = true;
                        break;
                    }
                }
                if (satisfied) {
                    continue;
                }
                if (unknownCount == 0) {
                    return false;
                }
                if (unknownCount == 1) {
                    const variable = unknownLiteral < 0
                        ? -unknownLiteral
                        : unknownLiteral;
                    const required = unknownLiteral > 0 ? 1 : 0;
                    if (
                        current[variable] != -1 &&
                        current[variable] != required
                    ) {
                        return false;
                    }
                    if (current[variable] == -1) {
                        current[variable] = required;
                        changed = true;
                    }
                }
            }
        }

        size_t branch;
        foreach (index; 1 .. current.length) {
            if (current[index] == -1) {
                branch = index;
                break;
            }
        }
        if (branch == 0) {
            return true;
        }

        auto positive = current.dup;
        positive[branch] = 1;
        if (solve(positive)) {
            return true;
        }
        auto negative = current.dup;
        negative[branch] = 0;
        return solve(negative);
    }

    return solve(assignment);
}

private void assertBooleanTruthTable(
    string name,
    BoolExpr delegate(BoolExpr, BoolExpr) expression,
    bool delegate(bool, bool) expected
) {
    auto model = new Model(name);
    auto left = model.booleanVar("left");
    auto right = model.booleanVar("right");
    model.require(name, expression(left, right));
    auto compiled = compile(model);

    foreach (leftValue; 0L .. 2L) {
        foreach (rightValue; 0L .. 2L) {
            long[string] decisions;
            decisions["left"] = leftValue;
            decisions["right"] = rightValue;
            check(
                cnfSatisfiable(compiled, decisions) ==
                    expected(leftValue != 0, rightValue != 0),
                "Tseitin encoding matches the " ~ name ~ " truth table"
            );
        }
    }
}

private void testBooleanTruthTables() {
    assertBooleanTruthTable(
        "and",
        (BoolExpr left, BoolExpr right) => left & right,
        (bool left, bool right) => left && right
    );
    assertBooleanTruthTable(
        "or",
        (BoolExpr left, BoolExpr right) => left | right,
        (bool left, bool right) => left || right
    );
    assertBooleanTruthTable(
        "xor",
        (BoolExpr left, BoolExpr right) => left ^ right,
        (bool left, bool right) => left != right
    );
    assertBooleanTruthTable(
        "implies",
        (BoolExpr left, BoolExpr right) => implies(left, right),
        (bool left, bool right) => !left || right
    );
    assertBooleanTruthTable(
        "equivalent",
        (BoolExpr left, BoolExpr right) => equivalent(left, right),
        (bool left, bool right) => left == right
    );
    assertBooleanTruthTable(
        "not",
        (BoolExpr left, BoolExpr right) => ~left,
        (bool left, bool right) => !left
    );
}

private void testPseudoBooleanTruthTable() {
    auto model = new Model("linear-truth-table");
    auto x = model.integerVar("x", -1, 2);
    auto y = model.integerVar("y", 0, 3);
    model.require(
        "weighted capacity",
        lessEqual(2 * x - 3 * y, integer(1))
    );
    auto compiled = compile(model);

    foreach (xValue; -1L .. 3L) {
        foreach (yValue; 0L .. 4L) {
            long[string] decisions;
            decisions["x"] = xValue;
            decisions["y"] = yValue;
            const expected = 2 * xValue - 3 * yValue <= 1;
            check(
                cnfSatisfiable(compiled, decisions) == expected,
                "Pseudo-Boolean CNF matches source arithmetic truth table"
            );
        }
    }
}

private void assertIntegerRelation(
    string name,
    BoolExpr delegate(IntExpr) relation,
    bool delegate(long) expected
) {
    auto model = new Model(name);
    auto value = model.integerVar("value", -2, 2);
    model.require(name, relation(value));
    auto compiled = compile(model);

    foreach (candidate; -2L .. 3L) {
        long[string] decisions;
        decisions["value"] = candidate;
        check(
            cnfSatisfiable(compiled, decisions) == expected(candidate),
            "Linear compiler matches the " ~ name ~ " relation"
        );
    }
}

private void testAllIntegerRelations() {
    assertIntegerRelation(
        "equal",
        (IntExpr value) => equal(value, integer(0)),
        (long value) => value == 0
    );
    assertIntegerRelation(
        "not equal",
        (IntExpr value) => notEqual(value, integer(0)),
        (long value) => value != 0
    );
    assertIntegerRelation(
        "less than",
        (IntExpr value) => lessThan(value, integer(0)),
        (long value) => value < 0
    );
    assertIntegerRelation(
        "less equal",
        (IntExpr value) => lessEqual(value, integer(0)),
        (long value) => value <= 0
    );
    assertIntegerRelation(
        "greater than",
        (IntExpr value) => greaterThan(value, integer(0)),
        (long value) => value > 0
    );
    assertIntegerRelation(
        "greater equal",
        (IntExpr value) => greaterEqual(value, integer(0)),
        (long value) => value >= 0
    );
}

private void testIndexedVariablesAndCardinality() {
    auto model = new Model("selection");
    auto selected = model.booleanVars(
        "selected",
        ["wheat", "chickpea", "rice"]
    );
    model.require(
        "choose exactly one crop",
        exactlyOne([
            selected["wheat"],
            selected["chickpea"],
            selected["rice"]
        ])
    );
    auto compiled = compile(model);

    foreach (mask; 0 .. 8) {
        long[string] decisions;
        decisions["selected[wheat]"] = (mask & 1) != 0;
        decisions["selected[chickpea]"] = (mask & 2) != 0;
        decisions["selected[rice]"] = (mask & 4) != 0;
        const count =
            decisions["selected[wheat]"] +
            decisions["selected[chickpea]"] +
            decisions["selected[rice]"];
        check(
            cnfSatisfiable(compiled, decisions) == (count == 1),
            "Cardinality encoding enforces exactly one indexed decision"
        );
    }
}

private void testCategoricalCnfTruthTable() {
    auto model = new Model("categorical-cnf");
    auto first = model.categoricalVar("first", ["a", "b", "c"]);
    auto second = model.categoricalVar("second", ["a", "b", "c"]);
    auto third = model.categoricalVar("third", ["a", "b", "c"]);
    model.require(
        "all different",
        allDifferent([first, second, third])
    );

    CompileOptions options;
    options.preferQState = false;
    auto compiled = compile(model, options);
    foreach (firstValue; 0L .. 3L) {
        foreach (secondValue; 0L .. 3L) {
            foreach (thirdValue; 0L .. 3L) {
                long[string] decisions;
                decisions["first"] = firstValue;
                decisions["second"] = secondValue;
                decisions["third"] = thirdValue;
                const expected =
                    firstValue != secondValue &&
                    firstValue != thirdValue &&
                    secondValue != thirdValue;
                check(
                    cnfSatisfiable(compiled, decisions) == expected,
                    "Categorical all-different CNF matches domain semantics"
                );
            }
        }
    }
}

private void testPercentScaleAllocationCompilation() {
    auto model = new Model("portfolio-percent");
    auto equity = model.integerVar("equity_pct", 0, 100);
    auto bonds = model.integerVar("bonds_pct", 0, 100);
    auto cash = model.integerVar("cash_pct", 0, 100);
    model.require(
        "fully invested",
        equal(equity + bonds + cash, integer(100))
    );
    model.require(
        "equity cap",
        lessEqual(equity, integer(70))
    );
    model.maximize(
        "linear expected return",
        12 * equity + 5 * bonds + cash
    );

    auto compiled = compile(model);
    check(
        compiled.backend == Backend.cnf,
        "Percent-scale portfolio allocation compiles to CNF"
    );
    check(
        compiled.generatedVariableCount < 100_000,
        "Order/PB encoding stays bounded for percent allocation"
    );
}

private void testPartialAnytimeResult() {
    auto model = new Model("partial");
    auto x = model.integerVar("x", 0, 2);
    model.require("x is two", equal(x, integer(2)));
    auto compiled = compile(model);

    long[string] values;
    values["x"] = 1;
    auto result = buildSolveResult(
        compiled,
        cnfResponseFor(compiled, values, true)
    );
    check(result.status == RunStatus.partial, "Timeout result is marked partial");
    check(
        result.verification.hardViolated == 1,
        "Anytime assignment is independently verified"
    );
}

private final class FakeTransport : HttpTransport {
    HttpResponse next;
    string observedUrl;
    string observedToken;
    string observedBody;
    Duration observedConnectTimeout;
    Duration observedOperationTimeout;

    override HttpResponse postJson(
        string url,
        string bearerToken,
        string body,
        Duration connectTimeout,
        Duration operationTimeout
    ) {
        observedUrl = url;
        observedToken = bearerToken;
        observedBody = body;
        observedConnectTimeout = connectTimeout;
        observedOperationTimeout = operationTimeout;
        return next;
    }
}

/// Sequence transport: returns the next queued response per call, recording
/// each (url, body) pair so tests can assert call order and payloads.
private final class SequenceTransport : HttpTransport {
    HttpResponse[] queue;
    string[] observedUrls;
    string[] observedBodies;
    size_t index = 0;

    override HttpResponse postJson(
        string url,
        string bearerToken,
        string body,
        Duration connectTimeout,
        Duration operationTimeout
    ) {
        observedUrls ~= url;
        observedBodies ~= body;
        if (index >= queue.length) {
            throw new Exception(
                "SequenceTransport exhausted at call " ~
                    (cast(long) index).to!string
            );
        }
        return queue[index++];
    }
}

private void testClientAndErrors() {
    auto model = new Model("client");
    auto enabled = model.booleanVar("enabled");
    model.require("enabled", enabled);
    auto compiled = compile(model);

    long[string] values;
    values["enabled"] = 1;
    auto fake = new FakeTransport();
    fake.next = HttpResponse(
        200,
        cnfResponseFor(compiled, values).toString(),
        null
    );

    RequestOptions request;
    request.apiKey = "secret";
    request.baseUrl = "https://example.invalid/";
    auto result = new NavokojClient(fake).solve(compiled, request);
    check(result.feasible, "Client returns hydrated solve result");
    check(
        fake.observedUrl == "https://example.invalid/v1/solve",
        "Client normalizes the solve endpoint"
    );
    check(fake.observedToken == "secret", "Client passes bearer token separately");
    check(
        fake.observedBody.length > 0,
        "Client serializes the compiled request"
    );

    JSONValue[string] diagnostic;
    diagnostic["status"] = JSONValue("likely_solvable");
    diagnostic["solvability_score"] = JSONValue(92L);
    fake.next.body = JSONValue(diagnostic).toString();
    auto diagnosed = new NavokojClient(fake).diagnose(compiled, request);
    check(
        fake.observedUrl == "https://example.invalid/v1/diagnose",
        "Client targets the diagnostic endpoint"
    );
    check(
        diagnosed.object["status"].str == "likely_solvable",
        "Diagnostic JSON is preserved"
    );

    fake.next.statusCode = 429;
    JSONValue[string] failure;
    failure["error"] = JSONValue("Rate limit exceeded");
    failure["retry_after"] = JSONValue(60L);
    fake.next.body = JSONValue(failure).toString();

    bool caught;
    try {
        new NavokojClient(fake).solve(compiled, request);
    } catch (ApiException error) {
        caught = true;
        check(error.statusCode == 429, "API error retains status");
        check(error.retryAfterSeconds == 60, "API error retains retry delay");
    }
    check(caught, "Non-success HTTP response throws ApiException");
}

private void testProtocolHardening() {
    auto model = new Model("protocol");
    auto enabled = model.booleanVar("enabled");
    model.require("enabled", enabled);

    CompileOptions compileOptions;
    compileOptions.timeoutBudgetSeconds = 70.0;
    auto compiled = compile(model, compileOptions);

    long[string] values;
    values["enabled"] = 1;
    auto fake = new FakeTransport();
    fake.next = HttpResponse(
        200,
        cnfResponseFor(compiled, values).toString(),
        null
    );

    RequestOptions request;
    request.apiKey = "secret";
    request.baseUrl = "https://example.invalid";
    request.transportTimeout = dur!"seconds"(1);
    auto solved = new NavokojClient(fake).solve(compiled, request);
    check(solved.feasible, "Timed solve fixture still hydrates");
    check(
        fake.observedOperationTimeout >= dur!"seconds"(80),
        "HTTP deadline includes solver budget, connect time, and response grace"
    );

    JSONValue[string] failure;
    failure["success"] = JSONValue(false);
    failure["error"] = JSONValue("solver rejected the request");
    fake.next = HttpResponse(200, JSONValue(failure).toString(), null);
    bool caught;
    try {
        new NavokojClient(fake).solve(compiled, request);
    } catch (ApiException error) {
        caught = true;
        check(
            error.statusCode == 200,
            "HTTP-200 failure envelope retains its status"
        );
        check(
            error.deliveryState == RequestDeliveryState.responseReceived,
            "Failure envelope records that a response was received"
        );
    }
    check(caught, "HTTP-200 success:false is never treated as a solved run");

    string[string] errorHeaders;
    errorHeaders["X-Request-ID"] = "header-error-id";
    errorHeaders["Retry-After"] = "17";
    fake.next = HttpResponse(503, "<html>unavailable</html>", errorHeaders);
    caught = false;
    try {
        new NavokojClient(fake).solve(compiled, request);
    } catch (ApiException error) {
        caught = true;
        check(error.statusCode == 503, "Non-JSON errors retain HTTP status");
        check(
            error.requestId == "header-error-id",
            "Non-JSON errors retain case-insensitive request IDs"
        );
        check(
            error.retryAfterSeconds == 17,
            "Retry-After header is retained"
        );
        check(
            error.rawBody == "<html>unavailable</html>",
            "Non-JSON error body is retained exactly"
        );
    }
    check(caught, "Non-JSON HTTP failures become structured API errors");

    auto headerOnly = cnfResponseFor(compiled, values);
    headerOnly.object.remove("request_id");
    string[string] successHeaders;
    successHeaders["x-request-id"] = "header-success-id";
    fake.next = HttpResponse(200, headerOnly.toString(), successHeaders);
    solved = new NavokojClient(fake).solve(compiled, request);
    check(
        solved.server.requestId == "header-success-id",
        "Successful response uses the request-ID header fallback"
    );

    RequestOptions insecure = request;
    insecure.baseUrl = "http://example.invalid";
    caught = false;
    try {
        new NavokojClient(fake).solve(compiled, insecure);
    } catch (ApiException error) {
        caught = true;
        check(
            error.deliveryState == RequestDeliveryState.notSent,
            "TLS policy rejects a request before transport invocation"
        );
    }
    check(caught, "Bearer tokens are never sent over arbitrary HTTP");

    insecure.baseUrl = "http://127.0.0.1:8080";
    insecure.allowInsecureHttp = true;
    fake.next = HttpResponse(200, headerOnly.toString(), successHeaders);
    solved = new NavokojClient(fake).solve(compiled, insecure);
    check(
        fake.observedUrl == "http://127.0.0.1:8080/v1/solve",
        "Explicit insecure mode is restricted to loopback development"
    );
}

private void testDiagnosticProjection() {
    auto model = new Model("diagnostic-projection");
    auto x = model.booleanVar("x");
    model.require("hard x", x);
    model.prefer("soft not x", logicalNot(x), 10);
    model.maximize("maximize x", asInteger(x));

    CompileOptions ordinaryOptions;
    ordinaryOptions.preferQState = false;
    ordinaryOptions.preferNativeParity = false;
    auto ordinary = compile(model, ordinaryOptions);

    auto fake = new FakeTransport();
    JSONValue[string] diagnosticResponse;
    diagnosticResponse["status"] = JSONValue("likely_solvable");
    fake.next = HttpResponse(
        200,
        JSONValue(diagnosticResponse).toString(),
        null
    );
    RequestOptions request;
    request.apiKey = "secret";
    request.baseUrl = "https://example.invalid";

    bool caught;
    try {
        new NavokojClient(fake).diagnose(ordinary, request);
    } catch (CapabilityException error) {
        caught = true;
    }
    check(
        caught,
        "Weighted solve compilation cannot be misrepresented as hard DEFEKT CNF"
    );

    CompileOptions projectionOptions = ordinaryOptions;
    projectionOptions.diagnosticOnly = true;
    auto projection = compile(model, projectionOptions);
    check(
        ("weights" in projection.request.object) is null,
        "Diagnostic projection never emits clause weights"
    );
    foreach (clause; projection.clauses) {
        check(
            clause.constraintName != "soft not x" &&
            !clause.constraintName.canFind("$objective:"),
            "Diagnostic projection contains only structural and hard clauses"
        );
    }
    auto diagnosed = new NavokojClient(fake).diagnose(projection, request);
    check(
        diagnosed.object["status"].str == "likely_solvable",
        "Hard-only diagnostic projection submits successfully"
    );
}

private void testResponseNormalization() {
    JSONValue[string] top;
    top["success"] = JSONValue(true);
    top["assignment"] = JSONValue([JSONValue(false)]);
    top["solve_time_ms"] = JSONValue(25L);

    JSONValue[string] nested;
    nested["assignment"] = JSONValue([JSONValue(true)]);
    nested["overall_rate"] = JSONValue(0.75);
    top["solution"] = JSONValue(nested);

    auto normalized = normalizeResponse(JSONValue(top));
    check(normalized.hasAssignment, "Nested assignment is discovered");
    check(
        normalized.assignment.array[0].boolean,
        "Nested assignment takes precedence"
    );
    check(normalized.warnings.length == 1, "Conflicting shapes produce warning");
    check(
        normalized.solveTimeSeconds == 0.025,
        "Millisecond solve time normalizes to seconds"
    );
}

private void testExactCnfCompatibility() {
    auto formula = new CnfFormula("exact-cnf");
    const first = formula.newVariable("duplicate-label");
    const second = formula.newVariable("duplicate-label");
    formula.newVariable("unused");

    formula.addClause([second, first, first, -first], "shape");
    formula.addClause([], "empty");
    formula.addClause([second, first, first, -first], "duplicate");

    auto compiled = formula.compile();
    auto clauses = compiled.request.object["clauses"].array;
    check(
        compiled.generatedVariableCount == 3,
        "Exact CNF retains unused declared variables"
    );
    check(clauses.length == 3, "Exact CNF retains duplicate clauses");
    check(
        clauses[0].toString() == "[2,1,1,-1]",
        "Exact CNF retains literal order, repetitions, and opposite pairs"
    );
    check(
        clauses[1].array.length == 0,
        "Exact CNF retains an empty clause"
    );
    check(
        clauses[2].toString() == clauses[0].toString(),
        "Exact duplicate clause shape is preserved"
    );
    check(
        compiled.model.variables[0].name !=
            compiled.model.variables[1].name &&
        formula.labelOf(first) == formula.labelOf(second),
        "Stable VarIds are independent of optional duplicate labels"
    );

    auto trueFormula = new CnfFormula("zero-variable-true");
    auto trueCompiled = trueFormula.compile();
    check(
        trueCompiled.generatedVariableCount == 0 &&
        trueCompiled.request.object["clauses"].array.length == 0,
        "Zero-variable true DIMACS formula compiles exactly"
    );

    auto falseFormula = new CnfFormula("zero-variable-false");
    falseFormula.addClause([]);
    auto falseCompiled = falseFormula.compile();
    check(
        falseCompiled.generatedVariableCount == 0 &&
        falseCompiled.request.object["clauses"].array[0].array.length == 0,
        "Zero-variable false DIMACS formula compiles exactly"
    );

    auto verifiedFormula = new CnfFormula("native-verification");
    const required = verifiedFormula.newVariable("required");
    verifiedFormula.addClause([required], "required clause");
    auto verifiedCompiled = verifiedFormula.compile();
    long[string] violatedValues;
    violatedValues["required"] = 0;
    auto verified = buildSolveResult(
        verifiedCompiled,
        cnfResponseFor(verifiedCompiled, violatedValues)
    );
    check(
        verified.verification.hardViolated == 1 &&
        verified.score.hardViolations == 1 &&
        verified.status == RunStatus.partial,
        "Exact native clauses participate in local verification and scoring"
    );
}

private bool relationHolds(
    long left,
    LinearRelation relation,
    long right
) {
    final switch (relation) {
        case LinearRelation.less:
            return left < right;
        case LinearRelation.lessEqual:
            return left <= right;
        case LinearRelation.equal:
            return left == right;
        case LinearRelation.notEqual:
            return left != right;
        case LinearRelation.greaterEqual:
            return left >= right;
        case LinearRelation.greater:
            return left > right;
    }
}

private void testFormulaGeneratorPrimitives() {
    auto mappings = new CnfFormula("mapping-primitives");
    auto mapping = mappings.newMapping("p", 2, 3);
    check(mapping(2, 1) == 4, "Dense blocks use stable row-major VarIds");
    check(
        mapping.select([2L, 0L]) == [4, 5, 6],
        "Dense blocks support wildcard projection"
    );
    mappings.forceCompleteMapping(mapping);
    mappings.forceFunctionalMapping(mapping);
    mappings.forceInjectiveMapping(mapping);
    auto mappingCompiled = mappings.compile();
    check(
        mappingCompiled.generatedVariableCount == 6 &&
        mappingCompiled.request.object["clauses"].array.length == 11,
        "Mapping helpers lower to exact clauses without Tseitin variables"
    );

    auto indexed = new CnfFormula("indexed-primitives");
    auto combinations = indexed.newCombinations("pair", 4, 2);
    check(
        combinations.length == 6 && combinations(2, 4) == 5,
        "Combination-indexed groups have deterministic forward lookup"
    );
    check(
        combinations.toIndex(5) == [2L, 4L],
        "Indexed groups provide reverse VarId lookup"
    );
    auto words = indexed.newWords("word", 2, 3);
    check(words.length == 8, "Word-indexed groups cover Cartesian tuples");

    auto binaryFormula = new CnfFormula("binary-mapping");
    auto binary = binaryFormula.newBinaryMapping("bits", 2, 3);
    check(
        binary.bitsPerValue == 2 &&
        binary.forbid(1, 3).length == 2,
        "Binary mapping exposes compact forbid clauses"
    );

    auto linearFormula = new CnfFormula("signed-linear");
    const x = linearFormula.newVariable("x");
    const y = linearFormula.newVariable("y");
    linearFormula.addLinear(
        [-x, y],
        LinearRelation.greaterEqual,
        1,
        "not x or y"
    );
    auto linearCompiled = linearFormula.compile();
    foreach (xValue; 0L .. 2L) {
        foreach (yValue; 0L .. 2L) {
            long[string] assignment;
            assignment["x"] = xValue;
            assignment["y"] = yValue;
            check(
                cnfSatisfiable(linearCompiled, assignment) ==
                    (xValue == 0 || yValue == 1),
                "Signed pseudo-Boolean literals preserve negation semantics"
            );
        }
    }

    foreach (
        relation;
        [
            LinearRelation.less,
            LinearRelation.lessEqual,
            LinearRelation.equal,
            LinearRelation.notEqual,
            LinearRelation.greaterEqual,
            LinearRelation.greater
        ]
    ) {
        auto exhaustive = new CnfFormula("signed-pb-relation");
        const left = exhaustive.newVariable("left");
        const right = exhaustive.newVariable("right");
        exhaustive.addPseudoBoolean(
            [
                WeightedLiteral(2, left),
                WeightedLiteral(-1, left),
                WeightedLiteral(3, -left),
                WeightedLiteral(2, right),
                WeightedLiteral(-4, -right)
            ],
            relation,
            1,
            "mixed signed relation"
        );
        auto exhaustiveCompiled = exhaustive.compile();
        foreach (leftValue; 0L .. 2L) {
            foreach (rightValue; 0L .. 2L) {
                long[string] assignment;
                assignment["left"] = leftValue;
                assignment["right"] = rightValue;
                const expressionValue =
                    2 * leftValue -
                    leftValue +
                    3 * (1 - leftValue) +
                    2 * rightValue -
                    4 * (1 - rightValue);
                check(
                    cnfSatisfiable(exhaustiveCompiled, assignment) ==
                        relationHolds(expressionValue, relation, 1),
                    "Every signed pseudo-Boolean relation preserves its truth table"
                );
            }
        }
    }

    auto emptyTrue = new CnfFormula("empty-pb-true");
    emptyTrue.addPseudoBoolean(
        [],
        LinearRelation.equal,
        0,
        "zero equals zero"
    );
    long[string] noValues;
    check(
        cnfSatisfiable(emptyTrue.compile(), noValues),
        "An empty true pseudo-Boolean relation is a tautology"
    );

    auto emptyFalse = new CnfFormula("empty-pb-false");
    emptyFalse.addPseudoBoolean(
        [],
        LinearRelation.notEqual,
        0,
        "zero differs from zero"
    );
    check(
        !cnfSatisfiable(emptyFalse.compile(), noValues),
        "An empty false pseudo-Boolean relation is unsatisfiable"
    );

    auto parityFormula = new CnfFormula("signed-parity");
    const a = parityFormula.newVariable("a");
    const b = parityFormula.newVariable("b");
    parityFormula.addParity([-a, a, b], 1, "normalized parity");
    auto parityCompiled = parityFormula.compile();
    check(
        parityCompiled.backend == Backend.hybrid,
        "Signed parity retains the native hybrid path"
    );
    auto xorConstraint =
        parityCompiled.request.object["xor_constraints"].array[0].object;
    check(
        xorConstraint["vars"].array.length == 1 &&
        xorConstraint["vars"].array[0].integer == b &&
        xorConstraint["target"].integer == 0,
        "Signed parity flips its target and cancels duplicate variables"
    );

    auto emptyEvenParity = new CnfFormula("empty-even-parity");
    emptyEvenParity.addParity([], 0);
    check(
        cnfSatisfiable(emptyEvenParity.compile(), noValues),
        "Empty even parity is a tautology"
    );

    auto emptyOddParity = new CnfFormula("empty-odd-parity");
    emptyOddParity.addParity([], 1);
    check(
        !cnfSatisfiable(emptyOddParity.compile(), noValues),
        "Empty odd parity emits an exact empty clause"
    );

    auto otherFormula = new CnfFormula("other-owner");
    otherFormula.newVariable("other");
    bool caught;
    try {
        otherFormula.forceCompleteMapping(mapping);
    } catch (ModelException error) {
        caught = true;
    }
    check(caught, "Variable groups cannot cross formula ownership boundaries");
}

private void testDimacsInteroperability() {
    const source =
        "c description: standard format fixture\n" ~
        "c varname 1 first\n" ~
        "c arbitrary metadata\n" ~
        "p cnf 3 4\n" ~
        "1 -2\n" ~
        "3 0 0\n" ~
        "2 2 -2 0\n" ~
        "1 -2 3 0\n";

    auto parsed = parseDimacs(source);
    check(
        parsed.numVariables == 3 && parsed.clauses.length == 4,
        "DIMACS parser retains declared counts"
    );
    check(
        parsed.clauses[0] == [1, -2, 3] &&
        parsed.clauses[1].length == 0 &&
        parsed.clauses[2] == [2, 2, -2],
        "DIMACS parser supports multiline, empty, and noncanonical clauses"
    );
    check(
        parsed.name == "standard format fixture" &&
        parsed.variableLabels[1] == "first" &&
        parsed.comments.length == 1,
        "DIMACS parser retains names, variable labels, and comments"
    );

    auto roundTrip = parseDimacs(parsed.toDimacs());
    check(
        roundTrip.clauses == parsed.clauses &&
        roundTrip.numVariables == parsed.numVariables,
        "Canonical DIMACS serializer round-trips exact formula shape"
    );

    auto compiled = documentApp().compile(parsed.toDocumentJson());
    auto wireClauses = compiled.request.object["clauses"].array;
    check(
        compiled.generatedVariableCount == 3 &&
        wireClauses[0].toString() == "[1,-2,3]" &&
        wireClauses[1].array.length == 0 &&
        wireClauses[2].toString() == "[2,2,-2]",
        "DIMACS document adapter reaches exact Navokoj wire CNF"
    );

    auto zero = parseDimacs("p cnf 0 1\n0\n");
    auto zeroCompiled = documentApp().compile(zero.toDocumentJson());
    check(
        zeroCompiled.generatedVariableCount == 0 &&
        zeroCompiled.request.object["clauses"].array[0].array.length == 0,
        "Zero-variable DIMACS edge case is supported end to end"
    );

    const collidingLabels =
        "c varname 1 choice\n" ~
        "c varname 2 choice#3\n" ~
        "c varname 3 choice\n" ~
        "p cnf 3 0\n";
    auto labelsCompiled = documentApp().compile(
        parseDimacs(collidingLabels).toDocumentJson()
    );
    check(
        labelsCompiled.model.variables[0].name == "choice" &&
        labelsCompiled.model.variables[1].name == "choice#3" &&
        labelsCompiled.model.variables[2].name == "choice#4",
        "Colliding DIMACS labels receive deterministic unique hydration keys"
    );
}

private void testOpbInteroperability() {
    const source =
        "* #variable= 2 #constraint= 1 #equal= 0 intsize= 4\n" ~
        "* clean-room linear optimization fixture\n" ~
        "max: +5 x1 -2 ~x2 ;\n" ~
        "+2 x1 +3 ~x2 >= 3 ;\n";

    auto parsed = parseOpb(source);
    check(
        parsed.numVariables == 2 &&
        parsed.constraints.length == 1 &&
        parsed.hasObjective &&
        parsed.objective.sense == OpbObjectiveSense.maximize,
        "OPB parser retains variables, linear constraints, and objective sense"
    );
    check(
        parsed.objective.terms[1].negated &&
        parsed.constraints[0].relation == OpbRelation.greaterEqual,
        "OPB parser retains signed literals and relations"
    );

    auto roundTrip = parseOpb(parsed.toOpb());
    check(
        roundTrip.numVariables == parsed.numVariables &&
        roundTrip.constraints.length == parsed.constraints.length &&
        roundTrip.objective.terms[0].coefficient ==
            parsed.objective.terms[0].coefficient,
        "Canonical OPB serialization round-trips the linear model"
    );

    auto compact = parsed.toDocumentJson();
    auto decoded = opbFromDocumentJson(compact);
    check(
        decoded.constraints.length == 1 &&
        decoded.objective.terms.length == 2,
        "Compact OPB JSON preserves arbitrary-precision terms losslessly"
    );

    CompileOptions hardProjection;
    hardProjection.diagnosticOnly = true;
    auto compiled = documentApp().compile(compact, hardProjection);
    check(
        compiled.model.variables.length == 2 &&
        compiled.model.objectives.length == 1,
        "Compact OPB reaches the normal executable Navokoj model"
    );
    foreach (xValue; 0L .. 2L) {
        foreach (yValue; 0L .. 2L) {
            long[string] assignment;
            assignment["x1"] = xValue;
            assignment["x2"] = yValue;
            const expected =
                2 * xValue + 3 * (1 - yValue) >= 3;
            check(
                cnfSatisfiable(compiled, assignment) == expected,
                "OPB complement normalization preserves constraint semantics"
            );
        }
    }

    const semicolonless =
        "* #variable= 2 #constraint= 1\n" ~
        "+1 x1 +1 ~x2 >= 1\n";
    check(
        parseOpb(semicolonless).constraints.length == 1,
        "The direct adapter accepts line-oriented PB dialect"
    );

    auto oversized = parseOpb(
        "+9223372036854775808 x1 >= 0 ;\n"
    );
    auto untouched = new Model("oversized-opb");
    bool caught;
    try {
        populateModelFromOpb(untouched, oversized);
    } catch (CapabilityException error) {
        caught = true;
    }
    check(
        caught && untouched.variables.length == 0,
        "BigInt OPB values outside the executable backend fail before mutation"
    );

    OpbLimits oneExecutableTerm;
    oneExecutableTerm.maxExecutableTermsPerStatement = 1;
    auto bounded = new Model("bounded-opb");
    caught = false;
    try {
        populateModelFromOpb(bounded, parsed, oneExecutableTerm);
    } catch (CapabilityException error) {
        caught = true;
    }
    check(
        caught && bounded.variables.length == 0,
        "Executable OPB term limits are enforced before model mutation"
    );

    caught = false;
    try {
        parseOpb("+1 x1 x2 >= 1 ;\n");
    } catch (OpbException error) {
        caught = true;
    }
    check(
        caught,
        "Unsupported nonlinear OPB products fail explicitly"
    );

    auto empty = parseOpb(
        "* #variable= 0 #constraint= 0\n"
    );
    auto emptyCompiled = documentApp().compile(empty.toDocumentJson());
    check(
        emptyCompiled.generatedVariableCount == 0 &&
        emptyCompiled.request.object["clauses"].array.length == 0,
        "Zero-variable true OPB models compile end to end"
    );
}

private void testBackendEngineCompatibility() {
    auto categorical = new Model("engine-routing");
    auto slot = categorical.categoricalVar("slot", ["am", "pm"]);
    categorical.require("morning", slot.equals("am"));

    CompileOptions pro;
    pro.engine = "pro";
    auto cnf = compile(categorical, pro);
    check(
        cnf.backend == Backend.cnf &&
        cnf.request.object["engine"].str == "pro",
        "Explicit general engine forces exact CNF lowering"
    );

    CompileOptions qstate;
    qstate.engine = "qstate";
    auto specialized = compile(categorical, qstate);
    check(
        specialized.backend == Backend.qstate,
        "Explicit qstate engine is honored for a compatible model"
    );

    auto booleanModel = new Model("invalid-qstate");
    auto flag = booleanModel.booleanVar("flag");
    booleanModel.require("flag", flag);
    bool caught;
    try {
        compile(booleanModel, qstate);
    } catch (CapabilityException error) {
        caught = true;
    }
    check(caught, "Incompatible explicit qstate engine is rejected");

    auto parityModel = new Model("explicit-parity-engine");
    auto left = parityModel.booleanVar("left");
    auto right = parityModel.booleanVar("right");
    parityModel.parity("odd", [left, right], 1);
    auto lowered = compile(parityModel, pro);
    check(
        lowered.backend == Backend.cnf &&
        ("xor_constraints" in lowered.request.object) is null &&
        lowered.warnings.length == 1,
        "Explicit engine lowers parity to CNF instead of silently dropping it"
    );

    auto weighted = new Model("stop-controls");
    auto weightedFlag = weighted.booleanVar("flag");
    weighted.prefer("prefer flag", weightedFlag, 2);
    CompileOptions stop;
    stop.minSatisfaction = 0.9;
    stop.minWeightedSatisfaction = 0.8;
    auto stopped = compile(weighted, stop);
    check(
        stopped.request.object["min_satisfaction"].floating == 0.9 &&
        stopped.request.object["min_weighted_satisfaction"].floating == 0.8,
        "Documented early-stop cost controls reach the solve payload"
    );

    CompileOptions invalidStop;
    invalidStop.minSatisfaction = -0.5;
    bool rejectedInvalidStop;
    try {
        compile(weighted, invalidStop);
    } catch (ModelException error) {
        rejectedInvalidStop = true;
    }
    check(
        rejectedInvalidStop,
        "Early-stop thresholds accept only -1 or the documented 0..1 range"
    );
}

private void testExplicitUnsatWithoutAssignment() {
    auto model = new Model("unsat-response");
    auto enabled = model.booleanVar("enabled");
    model.require("enabled", enabled);
    auto compiled = compile(model);

    JSONValue[string] response;
    response["success"] = JSONValue(true);
    response["satisfiable"] = JSONValue(false);
    auto result = buildSolveResult(compiled, JSONValue(response));

    check(
        result.status == RunStatus.serverReportedInfeasible,
        "Explicit UNSAT is preserved even when the server returns no assignment"
    );
    check(
        result.score.toJson().object["feasible"].type == JSONType.null_,
        "An incomplete assignment never receives a misleading feasible score"
    );
}

private void testNamedCategoricalIndexConvention() {
    auto model = new Model("named-category");
    auto choice = model.categoricalVar("choice", ["red", "blue"]);
    model.require("choose blue", choice.equals("blue"));

    CompileOptions options;
    options.preferQState = false;
    auto compiled = compile(model, options);

    JSONValue[string] assignment;
    assignment["choice"] = JSONValue(1L);
    JSONValue[string] response;
    response["success"] = JSONValue(true);
    response["satisfiable"] = JSONValue(true);
    response["assignment"] = JSONValue(assignment);

    auto result = buildSolveResult(compiled, JSONValue(response));
    check(
        result.solution.get("choice").categoricalValue == "blue",
        "Named CNF categorical indices use an unambiguous zero-based convention"
    );
}

private void expectDocumentRejected(string json, string label) {
    bool caught;
    try {
        documentApp().compile(parseJSON(json));
    } catch (ModelException error) {
        caught = true;
    }
    check(caught, label);
}

private void testDocumentNumericAndShapeValidation() {
    expectDocumentRejected(
        `{
          "variables": [
            {"name": "x", "type": "integer", "lower": 0, "upper": 1}
          ],
          "objectives": [
            {
              "name": "value",
              "priority": 4294967296,
              "expression": "x"
            }
          ]
        }`,
        "Document priorities cannot wrap through an int cast"
    );
    expectDocumentRejected(
        `{
          "variables": [
            {"name": "x", "type": "boolean"}
          ],
          "parity_constraints": [
            {"name": "bad target", "variables": ["x"], "target": 4294967296}
          ]
        }`,
        "Document parity targets cannot wrap through an int cast"
    );
    expectDocumentRejected(
        `{
          "variables": [
            {"name": "x", "type": "boolean"}
          ],
          "constraints": [
            {
              "name": "bad count",
              "expression": {
                "op": "exactly",
                "count": -1,
                "args": ["x"]
              }
            }
          ]
        }`,
        "Document cardinalities reject negative counts"
    );
    expectDocumentRejected(
        `{
          "variables": [
            {"name": "x", "type": "boolean"}
          ],
          "unexpected": true
        }`,
        "Parser and schema both reject unknown root fields"
    );
    expectDocumentRejected(
        `{
          "variables": [
            {"name": "x", "type": "boolean"}
          ],
          "constraints": [
            {
              "name": "weighted hard",
              "level": "hard",
              "weight": 2,
              "expression": "x"
            }
          ]
        }`,
        "Hard-constraint weights are rejected instead of silently ignored"
    );
}

private void testDocumentExamples() {
    auto cropInput = parseJSON(readText("examples/json/crop-allocation.json"));
    auto crop = documentApp().compile(cropInput);
    check(crop.backend == Backend.cnf, "Crop document compiles end to end");

    auto portfolioInput = parseJSON(
        readText("examples/json/portfolio-allocation.json")
    );
    auto portfolio = documentApp().compile(portfolioInput);
    check(
        portfolio.request.object["weights"].array.length ==
            portfolio.request.object["clauses"].array.length,
        "Portfolio objective compiles to weighted clauses"
    );

    auto examInput = parseJSON(readText("examples/json/exam-allocation.json"));
    auto exam = documentApp().compile(examInput);
    check(exam.backend == Backend.qstate, "Exam document selects Q-State");

    auto quadraticInput = parseJSON(
        readText("examples/json/unsupported-quadratic-portfolio.json")
    );
    bool caught;
    try {
        documentApp().compile(quadraticInput);
    } catch (ModelException error) {
        caught = true;
        check(
            error.msg.canFind("future QP backend"),
            "Unsupported quadratic model points to the required backend"
        );
    }
    check(caught, "Quadratic quant model is never silently approximated");
}

private void testCompilationLimit() {
    auto model = new Model("too-large");
    auto x = model.integerVar("x", 0, 100);
    auto y = model.integerVar("y", 0, 100);
    model.require("combined", lessEqual(x + y, integer(100)));

    CompileOptions options;
    options.maxBddNodesPerConstraint = 1;
    bool caught;
    try {
        compile(model, options);
    } catch (CapabilityException error) {
        caught = true;
        check(
            error.msg.canFind("BDD limit"),
            "Pseudo-Boolean compilation limit explains the failure"
        );
    }
    check(caught, "Oversized pseudo-Boolean compilation is rejected");
}

private void testArithmeticOverflowDiagnostics() {
    auto model = new Model("overflow");
    auto x = model.categoricalVar("x", ["zero", "one", "two"]);
    model.prefer("use any state", boolean(true));
    model.maximize(
        "overflowing objective",
        long.max * x.asInteger()
    );

    bool caught;
    try {
        compile(model);
    } catch (CapabilityException error) {
        caught = true;
        check(
            error.msg.canFind("overflow"),
            "Arithmetic overflow has an explicit diagnostic"
        );
    }
    check(caught, "Overflowing objective is rejected");
}

private void testConstantFolding() {
    // Every subtest below would either crash with SIGSEGV inside
    // reify.model.unaryNode/binaryNode or surface a misleading "Cannot combine
    // unattached expressions" error before the constant-folding fix. After the
    // fix, constant-only AST operators must lower to folded constants without
    // requiring a model attachment, and the JSON reproducer must compile
    // instead of exiting with SIGSEGV.

    long[string] noDecisions;

    {
        auto model = new Model("not-true");
        model.require("trivial", logicalNot(boolean(true)));
        auto compiled = compile(model);
        check(
            !cnfSatisfiable(compiled, noDecisions),
            "logicalNot(boolean(true)) compiles to an unsatisfiable CNF"
        );
    }
    {
        auto model = new Model("not-false");
        model.require("trivial", logicalNot(boolean(false)));
        auto compiled = compile(model);
        check(
            cnfSatisfiable(compiled, noDecisions),
            "logicalNot(boolean(false)) compiles to a satisfiable CNF"
        );
    }
    {
        auto model = new Model("tilde-not-true");
        model.require("tilde", ~boolean(true));
        auto compiled = compile(model);
        check(
            !cnfSatisfiable(compiled, noDecisions),
            "~boolean(true) materializes and compiles unsat"
        );
    }

    {
        auto model = new Model("arith-five-plus-three");
        model.require(
            "five-plus-three-equals-eight",
            equal(integer(5) + integer(3), integer(8))
        );
        auto compiled = compile(model);
        check(
            cnfSatisfiable(compiled, noDecisions),
            "constant 5 + 3 = 8 compiles sat"
        );
    }
    {
        auto model = new Model("arith-five-plus-three-mismatch");
        model.require(
            "five-plus-three-equals-seven",
            equal(integer(5) + integer(3), integer(7))
        );
        auto compiled = compile(model);
        check(
            !cnfSatisfiable(compiled, noDecisions),
            "constant 5 + 3 != 7 compiles unsat"
        );
    }
    {
        auto model = new Model("arith-sub-mul");
        model.require(
            "ten-minus-four-equals-six",
            equal(integer(10) - integer(4), integer(6))
        );
        model.require(
            "six-times-seven-equals-forty-two",
            equal(integer(6) * 7, integer(42))
        );
        auto compiled = compile(model);
        check(
            cnfSatisfiable(compiled, noDecisions),
            "constant integer subtraction and multiplication fold"
        );
    }
    {
        auto model = new Model("arith-neg-five");
        model.require(
            "neg-five-equals-neg-five",
            equal(-integer(5), integer(-5))
        );
        auto compiled = compile(model);
        check(
            cnfSatisfiable(compiled, noDecisions),
            "unary -integer(5) folds and compares equal"
        );
    }

    {
        auto model = new Model("cast-bool-true");
        model.minimize("value", asInteger(boolean(true)));
        auto compiled = compile(model);
        check(
            cnfSatisfiable(compiled, noDecisions),
            "asInteger(boolean(true)) lowers into a finite objective"
        );
    }

    {
        auto model = new Model("bool-and-false");
        model.require("and", boolean(true) & boolean(false));
        auto compiled = compile(model);
        check(
            !cnfSatisfiable(compiled, noDecisions),
            "boolean(true) & boolean(false) compiles unsat"
        );
    }
    {
        auto model = new Model("bool-or-true");
        model.require("or", boolean(false) | boolean(true));
        auto compiled = compile(model);
        check(
            cnfSatisfiable(compiled, noDecisions),
            "boolean(false) | boolean(true) compiles sat"
        );
    }
    {
        auto model = new Model("bool-xor-cancels");
        model.require("xor", boolean(true) ^ boolean(true));
        auto compiled = compile(model);
        check(
            !cnfSatisfiable(compiled, noDecisions),
            "boolean(true) ^ boolean(true) compiles unsat"
        );
    }
    {
        auto model = new Model("bool-implies");
        model.require("implies", implies(boolean(true), boolean(false)));
        auto compiled = compile(model);
        check(
            !cnfSatisfiable(compiled, noDecisions),
            "implies(boolean(true), boolean(false)) compiles unsat"
        );
    }
    {
        auto model = new Model("bool-equivalent");
        model.require(
            "equivalent",
            equivalent(boolean(true), boolean(false))
        );
        auto compiled = compile(model);
        check(
            !cnfSatisfiable(compiled, noDecisions),
            "equivalent(boolean(true), boolean(false)) compiles unsat"
        );
    }

    {
        auto model = new Model("int-comparisons");
        model.require(
            "seven-equals-seven",
            equal(integer(7), integer(7))
        );
        model.require(
            "three-less-than-nine",
            lessThan(integer(3), integer(9))
        );
        model.require(
            "nine-less-equal-nine",
            lessEqual(integer(9), integer(9))
        );
        model.require(
            "nine-greater-than-three",
            greaterThan(integer(9), integer(3))
        );
        model.require(
            "nine-greater-equal-nine",
            greaterEqual(integer(9), integer(9))
        );
        auto compiled = compile(model);
        check(
            cnfSatisfiable(compiled, noDecisions),
            "constant integer comparisons fold to true and compile sat"
        );
    }
    {
        auto model = new Model("int-comparisons-disagree");
        model.require(
            "seven-not-equal-seven",
            notEqual(integer(7), integer(7))
        );
        auto compiled = compile(model);
        check(
            !cnfSatisfiable(compiled, noDecisions),
            "notEqual(integer(7), integer(7)) compiles unsat"
        );
    }

    // The JSON reproducer from the bug report: a schema-valid document whose
    // only constraint is `{"op":"not","arg":true}` previously exited with
    // SIGSEGV. After the fix it must compile to an unsatisfiable CNF.
    {
        auto app = documentApp();
        auto doc = parseJSON(
            `{"name":"json-constants","variables":[],` ~
            `"constraints":[{"name":"not-true",` ~
            `"expression":{"op":"not","arg":true}}]}`
        );
        auto compiled = app.compile(doc);
        check(
            !cnfSatisfiable(compiled, noDecisions),
            "JSON {\"op\":\"not\",\"arg\":true} compiles unsat instead of crashing"
        );
    }
    {
        auto app = documentApp();
        auto doc = parseJSON(
            `{"name":"json-constants-ok","variables":[],` ~
            `"constraints":[{"name":"not-false",` ~
            `"expression":{"op":"not","arg":false}}]}`
        );
        auto compiled = app.compile(doc);
        check(
            cnfSatisfiable(compiled, noDecisions),
            "JSON {\"op\":\"not\",\"arg\":false} compiles sat"
        );
    }
}

private void testCrossModelSafety() {
    auto first = new Model("first");
    auto second = new Model("second");
    auto left = first.integerVar("left", 0, 2);
    auto right = second.integerVar("right", 0, 2);

    bool caught;
    try {
        auto invalid = left + right;
    } catch (ModelException error) {
        caught = true;
        check(
            error.msg.canFind("different models"),
            "Cross-model expression error is actionable"
        );
    }
    check(caught, "Expressions from different models cannot be combined");
}

private void testCompiledModelSnapshotSafety() {
    auto model = new Model("snapshot");
    auto enabled = model.booleanVar("enabled");
    model.require("enabled is required", enabled);
    auto compiled = compile(model);

    auto exposed = model.variables;
    exposed[0].name = "tampered";
    check(
        compiled.model.variables[0].name == "enabled",
        "Public model views cannot mutate a compiled artifact"
    );

    bool caught;
    try {
        model.booleanVar("late variable");
    } catch (ModelException error) {
        caught = true;
        check(
            error.msg.canFind("frozen"),
            "Post-compilation mutation explains that the model is frozen"
        );
    }
    check(caught, "A compiled model cannot be mutated afterward");
}

private void testHardWeightDominance() {
    auto model = new Model("dominance");
    auto x = model.booleanVar("x");
    model.require("must x", x);
    model.prefer("prefer not x", logicalNot(x), 10);

    auto compiled = compile(model);
    double hardWeight;
    double softWeight;
    foreach (clause; compiled.clauses) {
        if (clause.constraintName == "must x") {
            hardWeight = clause.weight;
        } else if (clause.constraintName == "prefer not x") {
            softWeight = clause.weight;
        }
    }
    check(hardWeight > softWeight, "Hard clause dominates all soft reward");
}

private void testFractionalPriorityDominance() {
    auto model = new Model("fractional-dominance");
    auto x = model.booleanVar("x");
    model.medium("medium x", x, 0.5);
    model.prefer("soft not x", logicalNot(x), 10.0);

    auto compiled = compile(model);
    double mediumWeight;
    double softWeight;
    foreach (clause; compiled.clauses) {
        if (clause.constraintName == "medium x") {
            mediumWeight = clause.weight;
        } else if (clause.constraintName == "soft not x") {
            softWeight = clause.weight;
        }
    }
    check(
        mediumWeight > softWeight,
        "One fractional medium violation dominates all lower-priority soft reward"
    );
}

private void testQStateEligibilityBounds() {
    auto model = new Model("qstate-bounds");
    auto slot = model.categoricalVar("slot", ["am", "pm"]);
    model.require(
        "impossible state",
        equal(slot.asInteger(), integer(long.max))
    );

    auto compiled = compile(model);
    check(
        compiled.backend == Backend.cnf,
        "Out-of-domain categorical constants never produce invalid Q-State wire values"
    );
    foreach (candidate; 0L .. 2L) {
        long[string] values;
        values["slot"] = candidate;
        check(
            !cnfSatisfiable(compiled, values),
            "Out-of-domain categorical equality remains exactly unsatisfiable"
        );
    }
}

private void testObjectiveRangeValidation() {
    auto model = new Model("objective-overflow");
    auto value = model.integerVar("value", long.max - 1, long.max);
    model.maximize("overflowing objective", 2 * value);

    bool caught;
    try {
        compile(model);
    } catch (CapabilityException error) {
        caught = true;
        check(
            error.msg.canFind("overflow") || error.msg.canFind("range"),
            "Objective overflow has an actionable compile-time diagnostic"
        );
    }
    check(
        caught,
        "An objective that overflows for valid decisions is rejected before submission"
    );
}

private void testHybridParityVerification() {
    auto model = new Model("hybrid");
    auto left = model.booleanVar("left");
    auto right = model.booleanVar("right");
    model.require("at least one", left | right);
    model.parity("odd parity", [left, right], 1);

    auto compiled = compile(model);
    check(compiled.backend == Backend.hybrid, "Hard parity selects hybrid");
    check(
        ("xor_constraints" in compiled.request.object) !is null,
        "Hybrid request carries native XOR constraints"
    );
    check(
        ("weights" in compiled.request.object) is null,
        "Hard-only hybrid request avoids undocumented weighted hybrid"
    );
    check(
        ("engine" in compiled.request.object) is null,
        "Hybrid wire request uses strategy rather than an engine discriminator"
    );

    CompileOptions cnfOptions;
    cnfOptions.preferNativeParity = false;
    auto diagnosticCompilation = compile(model, cnfOptions);
    check(
        diagnosticCompilation.backend == Backend.cnf,
        "Native parity can be lowered to CNF for diagnosis"
    );

    long[string] values;
    values["left"] = 1;
    values["right"] = 1;
    auto result = buildSolveResult(
        compiled,
        cnfResponseFor(compiled, values)
    );
    check(
        result.verification.hardViolated == 1,
        "Hydration locally verifies native parity"
    );
    check(result.status == RunStatus.partial, "Parity violation is not feasible");
}

private void testTopologyDiagnosticsAndAutoRouting() {
    auto model = new Model("diagnostics-test");
    auto first = model.categoricalVar("c1", ["red", "green", "blue"]);
    auto second = model.categoricalVar("c2", ["red", "green", "blue"]);
    model.require("c1 != c2", first.different(second));

    auto topology = analyzeModel(model);
    check(topology.structureClassification == "qstate_categorical", "Categorical model classified as qstate");
    check(topology.logicalVariables == 2, "Logical variables count matched");
    
    auto route = recommendRoute(topology);
    check(route.engine == "qstate", "Auto-router selected qstate engine");
    check(route.hardware == "gpu_l4", "Auto-router targeted L4 GPU");
    check(route.estimatedVramMb > 0, "VRAM estimated");

    auto xorModel = new Model("xor-test");
    auto x = xorModel.booleanVar("x");
    auto y = xorModel.booleanVar("y");
    xorModel.requireParity("p1", [x, y], 1);
    
    auto xorTopology = analyzeModel(xorModel);
    check(xorTopology.structureClassification == "hybrid_xor", "Parity model classified as hybrid_xor");
    
    auto xorRoute = recommendRoute(xorTopology);
    check(xorRoute.engine == "hybrid", "Auto-router selected hybrid engine");
}

private void testRecommendRouteWithCapabilities() {
    // Empty caps envelope: topology-driven selection is preserved unchanged.
    auto tinyModel = new Model("tiny");
    tinyModel.booleanVar("x");
    auto tinyTopology = analyzeModel(tinyModel);
    auto noCaps = recommendRoute(tinyTopology);
    check(
        !noCaps.isRefusal(),
        "Empty capabilities do not produce a refusal"
    );

    // Tight maxVariables: build a model with more logical variables than the
    // cap allows so the router must refuse rather than attempt submission.
    auto bigModel = new Model("big");
    foreach (i; 0 .. 10) {
        bigModel.booleanVar("v" ~ i.to!string);
    }
    auto bigTopology = analyzeModel(bigModel);
    Capabilities tight;
    tight.maxVariables = 5;
    auto tightRec = recommendRoute(bigTopology, CompileOptions(), tight);
    check(
        tightRec.isRefusal(),
        "Tight caps force a router refusal"
    );
    check(
        tightRec.rationale.canFind("exceeds account limits"),
        "Refusal rationale explains the limit violation"
    );

    // Caps that fit the model but exclude the GPU the topology would pick:
    // CPU-only account should downgrade a GPU selection.
    auto xorModel = new Model("xor-caps");
    auto xorX = xorModel.booleanVar("x");
    auto xorY = xorModel.booleanVar("y");
    xorModel.requireParity("p", [xorX, xorY], 1);
    auto xorTopology = analyzeModel(xorModel);
    Capabilities cpuOnly;
    cpuOnly.hardwareAccess = ["cpu_native"];
    auto xorRoute = recommendRoute(xorTopology, CompileOptions(), cpuOnly);
    check(
        xorRoute.hardware == "cpu_native",
        "CPU-only caps downgrade hybrid_xor topology to CPU"
    );
    check(
        xorRoute.targetEndpoint == "/v1/solve",
        "Downgraded endpoint falls back to /v1/solve"
    );
}

private void testSolveAutoRouting() {
    // Compile a tiny document, stub capabilities then a successful solve,
    // and verify solveAuto wires the call order and applies the routing
    // recommendation to the outgoing request.
    auto app = documentApp();
    auto doc = parseJSON(
        `{"name":"auto-route","variables":[{"name":"v","type":"boolean"}],` ~
        `"constraints":[{"name":"trivial","expression":{"var":"v"}}]}`
    );

    auto fake = new SequenceTransport();
    fake.queue ~= HttpResponse(
        200,
        `{"engines":["nitro","hybrid"],"maxVariables":1000,` ~
        `"maxClauses":10000,"supportsHardClauseMask":true,` ~
        `"supportsSpaceTime":true,"tier":"standard",` ~
        `"hardwareAccess":["cpu_native","gpu_l4"]}`,
        null
    );
    long[string] values;
    values["v"] = 1;
    auto solveStub = documentApp().compile(doc);
    fake.queue ~= HttpResponse(
        200,
        cnfResponseFor(solveStub, values).toString(),
        null
    );

    AppSolveOptions options;
    options.compilation.engine = "auto";
    options.request.apiKey = "secret";
    options.request.baseUrl = "https://example.invalid/";
    auto result = app.solveAuto(doc, options, fake);

    check(fake.observedUrls.length == 2, "solveAuto issued two requests");
    check(
        fake.observedUrls[0].canFind("/v1/capabilities"),
        "First request hits /v1/capabilities"
    );
    check(
        fake.observedUrls[1].canFind("/v1/solve"),
        "Second request hits /v1/solve"
    );
    check(result.feasible, "solveAuto returned a hydrated feasible result");

    // The router, after caps reconciliation, picked "nitro" + cpu_native.
    // The payload sent to /v1/solve should carry those overrides.
    auto sentPayload = parseJSON(fake.observedBodies[1]);
    check(
        sentPayload.object["engine"].str == "nitro",
        "Router-selected engine reached the wire request"
    );
    check(
        sentPayload.object["hardware"].str == "cpu_native",
        "Router-selected hardware reached the wire request"
    );
}

private void testCapabilitiesCliCommand() {
    // Without a transport, the new capabilities() method must surface the
    // capabilities envelope as JSON with the documented fields.
    auto app = documentApp();

    auto fake = new FakeTransport();
    fake.next = HttpResponse(
        200,
        `{"engines":["nitro","qstate"],"maxVariables":500,` ~
        `"maxClauses":5000,"supportsHardClauseMask":true,` ~
        `"supportsSpaceTime":false,"tier":"free",` ~
        `"hardwareAccess":["cpu_native"],"remainingCredits":12.5}`,
        null
    );

    AppSolveOptions options;
    options.request.apiKey = "secret";
    options.request.baseUrl = "https://example.invalid/";
    auto caps = app.capabilities(options, fake);

    check(
        fake.observedUrl.canFind("/v1/capabilities"),
        "capabilities() probed /v1/capabilities"
    );
    check(
        caps.object["tier"].str == "free",
        "Capabilities JSON carries the tier"
    );
    check(
        caps.object["engines"].array.length == 2,
        "Capabilities JSON lists available engines"
    );
    check(
        caps.object["max_variables"].integer == 500,
        "Capabilities JSON carries the variable limit"
    );
    check(
        caps.object["has_account_limits"].type == JSONType.true_,
        "has_account_limits flag set when envelope has limits"
    );
    check(
        caps.object["supports_space_time"].type == JSONType.false_,
        "Capabilities JSON preserves false boolean fields"
    );
}

int main() {
    testBooleanCompilation();
    testQStateCompilationAndHydration();
    testFiniteArithmeticAndObjectives();
    testBooleanTruthTables();
    testPseudoBooleanTruthTable();
    testAllIntegerRelations();
    testIndexedVariablesAndCardinality();
    testCategoricalCnfTruthTable();
    testPercentScaleAllocationCompilation();
    testPartialAnytimeResult();
    testClientAndErrors();
    testProtocolHardening();
    testDiagnosticProjection();
    testResponseNormalization();
    testExactCnfCompatibility();
    testFormulaGeneratorPrimitives();
    testDimacsInteroperability();
    testOpbInteroperability();
    testBackendEngineCompatibility();
    testExplicitUnsatWithoutAssignment();
    testNamedCategoricalIndexConvention();
    testDocumentNumericAndShapeValidation();
    testDocumentExamples();
    testCompilationLimit();
    testArithmeticOverflowDiagnostics();
    testConstantFolding();
    testCrossModelSafety();
    testCompiledModelSnapshotSafety();
    testHardWeightDominance();
    testFractionalPriorityDominance();
    testQStateEligibilityBounds();
    testObjectiveRangeValidation();
    testHybridParityVerification();
    testTopologyDiagnosticsAndAutoRouting();
    testRecommendRouteWithCapabilities();
    testSolveAutoRouting();
    testCapabilitiesCliCommand();

    writeln("navokoj-app tests passed: ", assertions, " assertions");
    return 0;
}