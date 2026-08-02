// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.result;

import reify.compiler;
import reify.errors : ProtocolException;
import reify.model;

import std.algorithm : canFind;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;

enum DecisionStatus {
    assigned,
    missing,
    inconsistent
}

struct DecisionValue {
    DecisionStatus status = DecisionStatus.missing;
    VariableKind kind;
    bool booleanValue;
    long integerValue;
    string categoricalValue;
    string message;

    static DecisionValue boolean(bool value) {
        DecisionValue result;
        result.status = DecisionStatus.assigned;
        result.kind = VariableKind.boolean;
        result.booleanValue = value;
        result.integerValue = value ? 1 : 0;
        return result;
    }

    static DecisionValue integer(long value) {
        DecisionValue result;
        result.status = DecisionStatus.assigned;
        result.kind = VariableKind.integer;
        result.integerValue = value;
        return result;
    }

    static DecisionValue category(string value, long index) {
        DecisionValue result;
        result.status = DecisionStatus.assigned;
        result.kind = VariableKind.categorical;
        result.categoricalValue = value;
        result.integerValue = index;
        return result;
    }

    static DecisionValue missing(
        VariableKind kind,
        string message = "Assignment is missing"
    ) {
        DecisionValue result;
        result.status = DecisionStatus.missing;
        result.kind = kind;
        result.message = message;
        return result;
    }

    static DecisionValue inconsistent(
        VariableKind kind,
        string message
    ) {
        DecisionValue result;
        result.status = DecisionStatus.inconsistent;
        result.kind = kind;
        result.message = message;
        return result;
    }

    JSONValue toJson() const {
        if (status != DecisionStatus.assigned) {
            return JSONValue(null);
        }
        final switch (kind) {
            case VariableKind.boolean:
                return JSONValue(booleanValue);
            case VariableKind.categorical:
                return JSONValue(categoricalValue);
            case VariableKind.integer:
                return JSONValue(integerValue);
        }
    }
}

final class Solution {
    // A Solution is hydrated into logical variable names, not exposed as raw
    // integer literals. This keeps domain presenters independent of encoding
    // details such as auxiliary CNF variables.
    private DecisionValue[string] assignments;
    private string[] order;

    void set(string name, DecisionValue value) {
        if ((name in assignments) is null) {
            order ~= name;
        }
        assignments[name] = value;
    }

    bool has(string name) const {
        return (name in assignments) !is null;
    }

    DecisionValue get(string name) const {
        auto found = name in assignments;
        if (found is null) {
            return DecisionValue.missing(
                VariableKind.boolean,
                "Unknown decision variable '" ~ name ~ "'"
            );
        }
        return *found;
    }

    const(string)[] keys() const {
        return order;
    }

    bool complete() const {
        foreach (value; assignments) {
            if (value.status != DecisionStatus.assigned) {
                return false;
            }
        }
        return true;
    }

    JSONValue toJson() const {
        JSONValue[string] object;
        foreach (name; order) {
            object[name] = assignments[name].toJson();
        }
        return JSONValue(object);
    }

    JSONValue diagnosticsJson() const {
        JSONValue[] diagnostics;
        foreach (name; order) {
            auto value = assignments[name];
            if (value.status == DecisionStatus.assigned) {
                continue;
            }
            JSONValue[string] diagnostic;
            diagnostic["variable"] = JSONValue(name);
            diagnostic["status"] = JSONValue(value.status.to!string);
            diagnostic["message"] = JSONValue(value.message);
            diagnostics ~= JSONValue(diagnostic);
        }
        return JSONValue(diagnostics);
    }
}

struct NormalizedResponse {
    bool hasApiSuccess;
    bool apiSuccess;
    bool hasSatisfiable;
    bool satisfiable;
    bool hasAssignment;
    JSONValue assignment;
    bool hasSatisfactionRate;
    double satisfactionRate = 0.0;
    bool hasSolveTime;
    double solveTimeSeconds = 0.0;
    bool timeoutBudgetHit;
    string engineUsed;
    string method;
    string requestId;
    JSONValue raw;
    string[] warnings;
}

enum MatchState {
    satisfied,
    violated,
    unknown
}

struct ConstraintMatch {
    string name;
    string semanticOperationId;
    ConstraintLevel level;
    double weight;
    MatchState state;
    string message;
    string[] variables;

    JSONValue toJson() const {
        JSONValue[string] object;
        object["name"] = JSONValue(name);
        object["semantic_operation_id"] =
            JSONValue(semanticOperationId);
        object["level"] = JSONValue(level.to!string);
        object["weight"] = JSONValue(weight);
        object["state"] = JSONValue(state.to!string);
        if (message.length != 0) {
            object["message"] = JSONValue(message);
        }
        JSONValue[] variableValues;
        foreach (variable; variables) {
            variableValues ~= JSONValue(variable);
        }
        object["variables"] = JSONValue(variableValues);
        return JSONValue(object);
    }
}

struct ObjectiveResult {
    string name;
    ObjectiveSense sense;
    int priority;
    bool known;
    long value;
    string message;

    JSONValue toJson() const {
        JSONValue[string] object;
        object["name"] = JSONValue(name);
        object["sense"] = JSONValue(sense.to!string);
        object["priority"] = JSONValue(cast(long) priority);
        object["known"] = JSONValue(known);
        if (known) {
            object["value"] = JSONValue(value);
        } else {
            object["value"] = JSONValue(null);
            object["message"] = JSONValue(message);
        }
        return JSONValue(object);
    }
}

struct VerificationReport {
    bool completeAssignment;
    bool feasible;
    size_t hardSatisfied;
    size_t hardViolated;
    size_t mediumViolated;
    size_t softViolated;
    size_t unknown;
    double mediumPenalty = 0.0;
    double softPenalty = 0.0;
    size_t omittedMatches;
    ConstraintMatch[] matches;

    JSONValue toJson() const {
        JSONValue[string] object;
        object["complete_assignment"] = JSONValue(completeAssignment);
        object["feasible"] = JSONValue(feasible);
        object["hard_satisfied"] = JSONValue(cast(long) hardSatisfied);
        object["hard_violated"] = JSONValue(cast(long) hardViolated);
        object["medium_violated"] = JSONValue(cast(long) mediumViolated);
        object["soft_violated"] = JSONValue(cast(long) softViolated);
        object["unknown"] = JSONValue(cast(long) unknown);
        object["medium_penalty"] = JSONValue(mediumPenalty);
        object["soft_penalty"] = JSONValue(softPenalty);
        object["omitted_constraint_matches"] =
            JSONValue(cast(long) omittedMatches);

        JSONValue[] matchValues;
        foreach (match; matches) {
            matchValues ~= match.toJson();
        }
        object["constraint_matches"] = JSONValue(matchValues);
        return JSONValue(object);
    }
}

struct Score {
    long hardViolations;
    double mediumPenalty = 0.0;
    double softPenalty = 0.0;
    bool feasibilityKnown;
    bool feasible;

    JSONValue toJson() const {
        JSONValue[string] object;
        object["hard"] = JSONValue(-hardViolations);
        object["medium"] = JSONValue(-mediumPenalty);
        object["soft"] = JSONValue(-softPenalty);
        object["feasible"] = feasibilityKnown
            ? JSONValue(feasible)
            : JSONValue(null);
        return JSONValue(object);
    }
}

enum RunStatus {
    feasible,
    partial,
    serverReportedInfeasible,
    noAssignment
}

struct SolveResult {
    RunStatus status;
    /// True only when the selected backend explicitly certified an optimum.
    /// Feasible assignments from anytime solvers remain false.
    bool optimal;
    Solution solution;
    Score score;
    VerificationReport verification;
    ObjectiveResult[] objectives;
    NormalizedResponse server;
    JSONValue rawResponse;
    JSONValue compilation;
    SemanticOperation[] semanticOperations;

    bool feasible() const {
        return status == RunStatus.feasible;
    }

    JSONValue toJson() const {
        JSONValue[string] root;
        root["status"] = JSONValue(status.to!string);
        root["optimal"] = JSONValue(optimal);
        root["solution"] = solution is null
            ? JSONValue(null)
            : solution.toJson();
        root["decision_diagnostics"] = solution is null
            ? JSONValue(new JSONValue[](0))
            : solution.diagnosticsJson();
        root["score"] = score.toJson();
        root["verification"] = verification.toJson();
        JSONValue[] objectiveValues;
        foreach (objective; objectives) {
            objectiveValues ~= objective.toJson();
        }
        root["objectives"] = JSONValue(objectiveValues);

        JSONValue[string] statistics;
        JSONValue[string] navokoj;
        navokoj["success"] = server.hasApiSuccess
            ? JSONValue(server.apiSuccess)
            : JSONValue(null);
        navokoj["satisfiable"] = server.hasSatisfiable
            ? JSONValue(server.satisfiable)
            : JSONValue(null);
        navokoj["request_id"] = JSONValue(server.requestId);
        navokoj["engine"] = JSONValue(server.engineUsed);
        navokoj["method"] = JSONValue(server.method);
        navokoj["timeout_budget_hit"] =
            JSONValue(server.timeoutBudgetHit);
        if (server.hasSolveTime) {
            navokoj["solve_time_seconds"] =
                JSONValue(server.solveTimeSeconds);
        }
        if (server.hasSatisfactionRate) {
            navokoj["server_satisfaction_rate"] =
                JSONValue(server.satisfactionRate);
        }
        statistics["navokoj"] = JSONValue(navokoj);
        statistics["compilation"] = compilation;
        root["statistics"] = JSONValue(statistics);

        JSONValue[] warningValues;
        foreach (warning; server.warnings) {
            warningValues ~= JSONValue(warning);
        }
        root["warnings"] = JSONValue(warningValues);
        root["raw_response"] = rawResponse;
        JSONValue[] semanticValues;
        foreach (operation; semanticOperations) {
            JSONValue[string] semantic;
            semantic["id"] = JSONValue(operation.id);
            semantic["parent_id"] = JSONValue(operation.parentId);
            semantic["domain"] = JSONValue(operation.semanticDomain);
            semantic["kind"] = JSONValue(operation.kind);
            semantic["label"] = JSONValue(operation.label);
            JSONValue[] dimensions;
            foreach (dimension; operation.dimensions) {
                dimensions ~= JSONValue(dimension);
            }
            semantic["dimensions"] = JSONValue(dimensions);
            JSONValue[string] attributes;
            foreach (key, value; operation.attributes) {
                attributes[key] = JSONValue(value);
            }
            semantic["attributes"] = JSONValue(attributes);
            semanticValues ~= JSONValue(semantic);
        }
        root["semantic_operations"] = JSONValue(semanticValues);
        return JSONValue(root);
    }
}

NormalizedResponse normalizeResponse(JSONValue raw) {
    if (raw.type != JSONType.object) {
        throw new ProtocolException("Navokoj response root must be a JSON object");
    }

    NormalizedResponse result;
    result.raw = raw;
    auto root = raw.object;
    if ("success" in root) {
        result.hasApiSuccess = true;
        result.apiSuccess = jsonBool(root["success"], "success");
    }
    if ("satisfiable" in root) {
        result.hasSatisfiable = true;
        result.satisfiable = jsonBool(root["satisfiable"], "satisfiable");
    }

    JSONValue[string] nested;
    bool hasNested;
    if (
        "solution" in root &&
        root["solution"].type == JSONType.object
    ) {
        nested = root["solution"].object;
        hasNested = true;
    }

    const topHasAssignment = "assignment" in root;
    const nestedHasAssignment =
        hasNested && ("assignment" in nested) !is null;

    if (nestedHasAssignment) {
        result.hasAssignment = true;
        result.assignment = nested["assignment"];
        if (
            topHasAssignment &&
            root["assignment"].toString() != result.assignment.toString()
        ) {
            result.warnings ~=
                "Both solution.assignment and assignment were returned; " ~
                "the nested assignment was used";
        }
    } else if (topHasAssignment) {
        result.hasAssignment = true;
        result.assignment = root["assignment"];
    }

    if (
        hasNested &&
        readNumberIfPresent(
            nested,
            "satisfaction_rate",
            result.satisfactionRate
        )
    ) {
        result.hasSatisfactionRate = true;
    } else if (
        hasNested &&
        readNumberIfPresent(nested, "overall_rate", result.satisfactionRate)
    ) {
        result.hasSatisfactionRate = true;
    } else if (
        readNumberIfPresent(root, "satisfaction_rate", result.satisfactionRate)
    ) {
        result.hasSatisfactionRate = true;
    }

    if (
        hasNested &&
        readNumberIfPresent(
            nested,
            "solve_time_seconds",
            result.solveTimeSeconds
        )
    ) {
        result.hasSolveTime = true;
    } else if (
        readNumberIfPresent(
            root,
            "solve_time_seconds",
            result.solveTimeSeconds
        )
    ) {
        result.hasSolveTime = true;
    } else {
        double milliseconds;
        if (
            (hasNested &&
                readNumberIfPresent(nested, "solve_time_ms", milliseconds)) ||
            readNumberIfPresent(root, "solve_time_ms", milliseconds)
        ) {
            result.hasSolveTime = true;
            result.solveTimeSeconds = milliseconds / 1000.0;
        }
    }

    result.timeoutBudgetHit = readBool(
        root,
        "timeout_budget_hit",
        !hasNested
            ? false
            : readBool(nested, "timeout_budget_hit", false)
    );
    result.engineUsed = readString(
        root,
        "engine_used",
        !hasNested ? "" : readString(nested, "engine_used", "")
    );
    result.method = readString(
        root,
        "method",
        !hasNested ? "" : readString(nested, "method", "")
    );
    result.requestId = readString(
        root,
        "request_id",
        !hasNested ? "" : readString(nested, "request_id", "")
    );
    return result;
}

Solution hydrate(CompiledModel compiled, NormalizedResponse response) {
    auto solution = new Solution();
    if (!response.hasAssignment) {
        foreach (variable; compiled.model.internalVariables) {
            solution.set(
                variable.name,
                DecisionValue.missing(variable.kind)
            );
        }
        return solution;
    }

    if (compiled.backend == Backend.qstate) {
        hydrateQState(compiled, response.assignment, solution);
    } else {
        hydrateCnf(compiled, response.assignment, solution);
    }
    return solution;
}

private void hydrateQState(
    CompiledModel compiled,
    JSONValue assignment,
    Solution solution
) {
    if (assignment.type != JSONType.object) {
        throw new ProtocolException(
            "Q-State assignment must be an object keyed by one-based variable IDs"
        );
    }

    auto object = assignment.object;
    foreach (wireIndex, logicalIndex; compiled.qstateVariableOrder) {
        const key = (wireIndex + 1).to!string;
        auto found = key in object;
        auto variable = compiled.model.internalVariables[logicalIndex];
        if (found is null) {
            solution.set(
                variable.name,
                DecisionValue.missing(
                    variable.kind,
                    "Q-State response is missing variable " ~ key
                )
            );
            continue;
        }

        const state = jsonInteger(*found, "Q-State state") - 1;
        if (state < 0 || state >= variable.states.length) {
            solution.set(
                variable.name,
                DecisionValue.inconsistent(
                    variable.kind,
                    format("Q-State returned out-of-range state %s", state + 1)
                )
            );
            continue;
        }
        solution.set(
            variable.name,
            DecisionValue.category(
                variable.states[state],
                state
            )
        );
    }
}

private void hydrateCnf(
    CompiledModel compiled,
    JSONValue assignment,
    Solution solution
) {
    if (assignment.type == JSONType.object) {
        hydrateNamedObject(compiled, assignment.object, solution);
        return;
    }
    if (assignment.type != JSONType.array) {
        throw new ProtocolException(
            "CNF assignment must be an array or a named object"
        );
    }

    bool[] values;
    bool[] present;
    foreach (entry; assignment.array) {
        if (
            entry.type == JSONType.true_ ||
            entry.type == JSONType.false_
        ) {
            values ~= entry.boolean;
            present ~= true;
        } else if (
            entry.type == JSONType.integer ||
            entry.type == JSONType.uinteger
        ) {
            const integerValue = jsonInteger(entry, "assignment entry");
            if (integerValue != 0 && integerValue != 1) {
                throw new ProtocolException(
                    "Numeric CNF assignments must contain only 0 or 1"
                );
            }
            values ~= integerValue == 1;
            present ~= true;
        } else if (entry.type == JSONType.null_) {
            values ~= false;
            present ~= false;
        } else {
            throw new ProtocolException(
                "CNF assignment contains an unsupported value"
            );
        }
    }

    foreach (logicalIndex, variable; compiled.model.internalVariables) {
        if (variable.kind == VariableKind.integer) {
            bool encounteredFalse;
            bool missingThreshold;
            bool invalidOrder;
            long trueThresholds;

            foreach (
                thresholdLiteral;
                compiled.integerOrderLiterals[logicalIndex]
            ) {
                const satIndex = cast(size_t) thresholdLiteral - 1;
                if (satIndex >= present.length || !present[satIndex]) {
                    missingThreshold = true;
                    continue;
                }
                if (values[satIndex]) {
                    if (encounteredFalse) {
                        invalidOrder = true;
                    }
                    ++trueThresholds;
                } else {
                    encounteredFalse = true;
                }
            }

            if (invalidOrder) {
                solution.set(
                    variable.name,
                    DecisionValue.inconsistent(
                        variable.kind,
                        "Integer order bits are not monotonic"
                    )
                );
            } else if (missingThreshold) {
                solution.set(
                    variable.name,
                    DecisionValue.missing(
                        variable.kind,
                        "One or more integer order bits are missing"
                    )
                );
            } else {
                solution.set(
                    variable.name,
                    DecisionValue.integer(
                        variable.lowerBound + trueThresholds
                    )
                );
            }
            continue;
        }

        long[] selected;
        bool missingAtom;
        foreach (atom; compiled.atoms[logicalIndex]) {
            const satIndex = cast(size_t) (
                atom.literalWhenSelected < 0
                    ? -atom.literalWhenSelected
                    : atom.literalWhenSelected
            ) - 1;
            if (satIndex >= present.length || !present[satIndex]) {
                missingAtom = true;
                continue;
            }
            const positive = values[satIndex];
            const isSelected = atom.literalWhenSelected > 0
                ? positive
                : !positive;
            if (isSelected) {
                selected ~= atom.value;
            }
        }

        if (missingAtom && selected.length == 0) {
            solution.set(
                variable.name,
                DecisionValue.missing(variable.kind)
            );
        } else if (selected.length != 1) {
            solution.set(
                variable.name,
                DecisionValue.inconsistent(
                    variable.kind,
                    format(
                        "Expected one encoded value for '%s', found %s",
                        variable.name,
                        selected.length
                    )
                )
            );
        } else {
            solution.set(
                variable.name,
                makeDecisionValue(variable, selected[0])
            );
        }
    }
}

private void hydrateNamedObject(
    CompiledModel compiled,
    JSONValue[string] assignment,
    Solution solution
) {
    foreach (variable; compiled.model.internalVariables) {
        auto found = variable.name in assignment;
        if (found is null) {
            solution.set(
                variable.name,
                DecisionValue.missing(variable.kind)
            );
            continue;
        }

        final switch (variable.kind) {
            case VariableKind.boolean:
                solution.set(
                    variable.name,
                    DecisionValue.boolean(jsonBool(*found, variable.name))
                );
                break;
            case VariableKind.integer:
                solution.set(
                    variable.name,
                    makeDecisionValue(
                        variable,
                        jsonInteger(*found, variable.name)
                    )
                );
                break;
            case VariableKind.categorical:
                if (found.type == JSONType.string) {
                    if (!variable.states.canFind(found.str)) {
                        solution.set(
                            variable.name,
                            DecisionValue.inconsistent(
                                variable.kind,
                                "Unknown categorical state '" ~ found.str ~ "'"
                            )
                        );
                    } else {
                        long index;
                        foreach (candidateIndex, state; variable.states) {
                            if (state == found.str) {
                                index = candidateIndex;
                                break;
                            }
                        }
                        solution.set(
                            variable.name,
                            DecisionValue.category(found.str, index)
                        );
                    }
                } else {
                    solution.set(
                        variable.name,
                        makeDecisionValue(
                            variable,
                            jsonInteger(*found, variable.name)
                        )
                    );
                }
                break;
        }
    }
}

private DecisionValue makeDecisionValue(DomainVariable variable, long value) {
    final switch (variable.kind) {
        case VariableKind.boolean:
            return DecisionValue.boolean(value != 0);
        case VariableKind.integer:
            if (value < variable.lowerBound || value > variable.upperBound) {
                return DecisionValue.inconsistent(
                    variable.kind,
                    format("Value %s is outside the declared bounds", value)
                );
            }
            return DecisionValue.integer(value);
        case VariableKind.categorical:
            if (value < 0 || value >= variable.states.length) {
                return DecisionValue.inconsistent(
                    variable.kind,
                    format("Categorical index %s is outside the domain", value)
                );
            }
            return DecisionValue.category(variable.states[value], value);
    }
}

VerificationReport verify(Model model, Solution solution) {
    VerificationReport report;
    report.completeAssignment = solution.complete();
    report.feasible = report.completeAssignment;

    const variables = model.internalVariables;
    long[] values = new long[](variables.length);
    bool[] assigned = new bool[](variables.length);
    foreach (index, variable; variables) {
        auto value = solution.get(variable.name);
        if (value.status == DecisionStatus.assigned) {
            values[index] = value.integerValue;
            assigned[index] = true;
        }
    }

    foreach (constraint; model.internalConstraints) {
        ConstraintMatch match;
        match.name = constraint.name;
        match.semanticOperationId =
            constraint.semanticOperationId;
        match.level = constraint.level;
        match.weight = constraint.weight;

        bool[] referenced = new bool[](variables.length);
        collectVariables(constraint.expression.node, referenced);
        bool known = true;
        foreach (index, used; referenced) {
            if (used) {
                match.variables ~= variables[index].name;
            }
            if (used && !assigned[index]) {
                known = false;
            }
        }

        if (!known) {
            match.state = MatchState.unknown;
            match.message = "One or more decision values are unavailable";
            ++report.unknown;
            if (constraint.level == ConstraintLevel.hard) {
                report.feasible = false;
            }
        } else if (evaluateBoolean(constraint.expression.node, values)) {
            match.state = MatchState.satisfied;
            if (constraint.level == ConstraintLevel.hard) {
                ++report.hardSatisfied;
            }
        } else {
            match.state = MatchState.violated;
            match.message = "Constraint evaluated to false";
            final switch (constraint.level) {
                case ConstraintLevel.hard:
                    ++report.hardViolated;
                    report.feasible = false;
                    break;
                case ConstraintLevel.medium:
                    ++report.mediumViolated;
                    report.mediumPenalty += constraint.weight;
                    break;
                case ConstraintLevel.soft:
                    ++report.softViolated;
                    report.softPenalty += constraint.weight;
                    break;
            }
        }
        report.matches ~= match;
    }

    // Exact source clauses may number in the millions. Verify all of them, but
    // retain only a bounded set of actionable (violated/unknown) explanations.
    // Aggregate counters and penalties always cover the complete formula.
    enum maximumNativeClauseMatches = 1_000;
    foreach (clause; model.internalNativeClauses) {
        ConstraintMatch match;
        match.name = clause.name;
        match.semanticOperationId = clause.semanticOperationId;
        match.level = clause.level;
        match.weight = clause.weight;

        bool satisfied;
        bool missing;
        ubyte[size_t] polarities;
        foreach (literal; clause.literals) {
            const logicalIndex = literal.variableIndex;
            match.variables ~= variables[logicalIndex].name;

            const polarity = literal.negated ? 2 : 1;
            auto seen = logicalIndex in polarities;
            if (seen is null) {
                polarities[logicalIndex] = polarity;
            } else {
                *seen |= polarity;
                if (*seen == 3) {
                    // x OR !x is true even if the assignment is partial.
                    satisfied = true;
                }
            }

            if (!assigned[logicalIndex]) {
                missing = true;
                continue;
            }
            const value = values[logicalIndex] != 0;
            if (literal.negated ? !value : value) {
                satisfied = true;
            }
        }

        if (satisfied) {
            match.state = MatchState.satisfied;
            if (clause.level == ConstraintLevel.hard) {
                ++report.hardSatisfied;
            }
        } else if (missing) {
            match.state = MatchState.unknown;
            match.message = "One or more clause decisions are unavailable";
            ++report.unknown;
            if (clause.level == ConstraintLevel.hard) {
                report.feasible = false;
            }
        } else {
            match.state = MatchState.violated;
            match.message = "Clause evaluated to false";
            final switch (clause.level) {
                case ConstraintLevel.hard:
                    ++report.hardViolated;
                    report.feasible = false;
                    break;
                case ConstraintLevel.medium:
                    ++report.mediumViolated;
                    report.mediumPenalty += clause.weight;
                    break;
                case ConstraintLevel.soft:
                    ++report.softViolated;
                    report.softPenalty += clause.weight;
                    break;
            }
        }

        if (
            match.state != MatchState.satisfied &&
            report.matches.length < maximumNativeClauseMatches
        ) {
            report.matches ~= match;
        } else {
            ++report.omittedMatches;
        }
    }

    foreach (parity; model.internalParityConstraints) {
        ConstraintMatch match;
        match.name = parity.name;
        match.semanticOperationId = parity.semanticOperationId;
        match.level = ConstraintLevel.hard;
        match.weight = 1.0;

        bool known = true;
        int observed;
        foreach (logicalIndex; parity.variableIndices) {
            match.variables ~= variables[logicalIndex].name;
            if (!assigned[logicalIndex]) {
                known = false;
                break;
            }
            observed ^= values[logicalIndex] != 0 ? 1 : 0;
        }

        if (!known) {
            match.state = MatchState.unknown;
            match.message = "One or more parity decisions are unavailable";
            ++report.unknown;
            report.feasible = false;
        } else if (observed == parity.target) {
            match.state = MatchState.satisfied;
            ++report.hardSatisfied;
        } else {
            match.state = MatchState.violated;
            match.message = format(
                "Observed parity %s, expected %s",
                observed,
                parity.target
            );
            ++report.hardViolated;
            report.feasible = false;
        }
        report.matches ~= match;
    }
    return report;
}

Score calculateScore(VerificationReport report) {
    Score score;
    score.feasibilityKnown =
        report.completeAssignment && report.unknown == 0;
    score.feasible = report.feasible;
    score.hardViolations = cast(long) report.hardViolated;
    score.mediumPenalty = report.mediumPenalty;
    score.softPenalty = report.softPenalty;
    return score;
}

ObjectiveResult[] evaluateObjectives(Model model, Solution solution) {
    const variables = model.internalVariables;
    long[] values = new long[](variables.length);
    bool[] assigned = new bool[](variables.length);
    foreach (index, variable; variables) {
        auto decision = solution.get(variable.name);
        if (decision.status == DecisionStatus.assigned) {
            values[index] = decision.integerValue;
            assigned[index] = true;
        }
    }

    ObjectiveResult[] results;
    foreach (objective; model.internalObjectives) {
        ObjectiveResult result;
        result.name = objective.name;
        result.sense = objective.sense;
        result.priority = objective.priority;

        bool[] referenced = new bool[](variables.length);
        collectVariables(objective.expression.node, referenced);
        result.known = true;
        foreach (index, used; referenced) {
            if (used && !assigned[index]) {
                result.known = false;
                result.message =
                    "One or more objective decisions are unavailable";
                break;
            }
        }
        if (result.known) {
            result.value = evaluateInteger(
                objective.expression.node,
                values
            );
        }
        results ~= result;
    }
    return results;
}

SolveResult buildSolveResult(CompiledModel compiled, JSONValue raw) {
    SolveResult result;
    result.rawResponse = raw;
    if (
        raw.type == JSONType.object &&
        ("optimal" in raw.object) !is null &&
        raw.object["optimal"].type == JSONType.true_
    ) {
        result.optimal = true;
    }
    result.server = normalizeResponse(raw);
    result.solution = hydrate(compiled, result.server);
    result.verification = verify(compiled.model, result.solution);
    result.score = calculateScore(result.verification);
    result.objectives = evaluateObjectives(compiled.model, result.solution);
    result.compilation = compiled.summary();
    result.semanticOperations = compiled.model.semanticOperations;

    if (!result.server.hasAssignment) {
        if (
            result.server.hasSatisfiable &&
            !result.server.satisfiable &&
            !result.server.timeoutBudgetHit
        ) {
            result.status = RunStatus.serverReportedInfeasible;
        } else {
            result.status = RunStatus.noAssignment;
        }
    } else if (result.verification.feasible) {
        result.status = RunStatus.feasible;
    } else {
        // A returned assignment is always useful evidence, even when the
        // server labels it unsolved/infeasible. Verify it locally and expose
        // violations as a partial result instead of discarding the solution.
        result.status = RunStatus.partial;
    }
    return result;
}

private void collectVariables(ExpressionNode node, bool[] seen) {
    if (node.kind == ExpressionKind.variable) {
        seen[node.variableIndex] = true;
        return;
    }
    foreach (child; node.children) {
        collectVariables(child, seen);
    }
}

private bool evaluateBoolean(ExpressionNode node, long[] values) {
    switch (node.kind) {
        case ExpressionKind.booleanConstant:
            return node.booleanValue;
        case ExpressionKind.variable:
            return values[node.variableIndex] != 0;
        case ExpressionKind.logicalNot:
            return !evaluateBoolean(node.children[0], values);
        case ExpressionKind.logicalAnd:
            return evaluateBoolean(node.children[0], values) &&
                evaluateBoolean(node.children[1], values);
        case ExpressionKind.logicalOr:
            return evaluateBoolean(node.children[0], values) ||
                evaluateBoolean(node.children[1], values);
        case ExpressionKind.logicalXor:
            return evaluateBoolean(node.children[0], values) !=
                evaluateBoolean(node.children[1], values);
        case ExpressionKind.implies:
            return !evaluateBoolean(node.children[0], values) ||
                evaluateBoolean(node.children[1], values);
        case ExpressionKind.equivalent:
            return evaluateBoolean(node.children[0], values) ==
                evaluateBoolean(node.children[1], values);
        case ExpressionKind.equal:
            return evaluateInteger(node.children[0], values) ==
                evaluateInteger(node.children[1], values);
        case ExpressionKind.notEqual:
            return evaluateInteger(node.children[0], values) !=
                evaluateInteger(node.children[1], values);
        case ExpressionKind.lessThan:
            return evaluateInteger(node.children[0], values) <
                evaluateInteger(node.children[1], values);
        case ExpressionKind.lessEqual:
            return evaluateInteger(node.children[0], values) <=
                evaluateInteger(node.children[1], values);
        case ExpressionKind.greaterThan:
            return evaluateInteger(node.children[0], values) >
                evaluateInteger(node.children[1], values);
        case ExpressionKind.greaterEqual:
            return evaluateInteger(node.children[0], values) >=
                evaluateInteger(node.children[1], values);
        case ExpressionKind.allDifferent:
            long[] encountered;
            foreach (child; node.children) {
                const value = evaluateInteger(child, values);
                if (encountered.canFind(value)) {
                    return false;
                }
                encountered ~= value;
            }
            return true;
        default:
            throw new ProtocolException(
                "Cannot evaluate a non-Boolean expression as a constraint"
            );
    }
}

private long evaluateInteger(ExpressionNode node, long[] values) {
    switch (node.kind) {
        case ExpressionKind.integerConstant:
            return node.integerValue;
        case ExpressionKind.variable:
            return values[node.variableIndex];
        case ExpressionKind.add:
            return checkedResultAdd(
                evaluateInteger(node.children[0], values),
                evaluateInteger(node.children[1], values)
            );
        case ExpressionKind.subtract:
            return checkedResultSubtract(
                evaluateInteger(node.children[0], values),
                evaluateInteger(node.children[1], values)
            );
        case ExpressionKind.multiply:
            return checkedResultMultiply(
                evaluateInteger(node.children[0], values),
                evaluateInteger(node.children[1], values)
            );
        case ExpressionKind.negate:
            auto value = evaluateInteger(node.children[0], values);
            if (value == long.min) {
                throw new ProtocolException(
                    "Integer overflow while evaluating hydrated solution"
                );
            }
            return -value;
        case ExpressionKind.booleanAsInteger:
            return evaluateBoolean(node.children[0], values) ? 1 : 0;
        default:
            throw new ProtocolException(
                "Cannot evaluate a non-integer expression as arithmetic"
            );
    }
}

private bool readBool(
    JSONValue[string] object,
    string key,
    bool defaultValue
) {
    auto found = key in object;
    return found is null ? defaultValue : jsonBool(*found, key);
}

private string readString(
    JSONValue[string] object,
    string key,
    string defaultValue
) {
    auto found = key in object;
    if (found is null) {
        return defaultValue;
    }
    if (found.type != JSONType.string) {
        throw new ProtocolException("Field '" ~ key ~ "' must be a string");
    }
    return found.str;
}

private bool readNumberIfPresent(
    JSONValue[string] object,
    string key,
    out double value
) {
    auto found = key in object;
    if (found is null) {
        return false;
    }
    value = jsonNumber(*found, key);
    return true;
}

private bool jsonBool(JSONValue value, string field) {
    if (value.type == JSONType.true_ || value.type == JSONType.false_) {
        return value.boolean;
    }
    if (
        value.type == JSONType.integer ||
        value.type == JSONType.uinteger
    ) {
        const integerValue = jsonInteger(value, field);
        if (integerValue == 0 || integerValue == 1) {
            return integerValue == 1;
        }
    }
    throw new ProtocolException(
        "Field '" ~ field ~ "' must be Boolean or 0/1"
    );
}

private long jsonInteger(JSONValue value, string field) {
    if (value.type == JSONType.integer) {
        return value.integer;
    }
    if (value.type == JSONType.uinteger) {
        const unsignedValue = value.uinteger;
        if (unsignedValue > long.max) {
            throw new ProtocolException(
                "Field '" ~ field ~ "' exceeds the supported integer range"
            );
        }
        return cast(long) unsignedValue;
    }
    throw new ProtocolException("Field '" ~ field ~ "' must be an integer");
}

private double jsonNumber(JSONValue value, string field) {
    if (value.type == JSONType.float_) {
        return value.floating;
    }
    if (
        value.type == JSONType.integer ||
        value.type == JSONType.uinteger
    ) {
        return cast(double) jsonInteger(value, field);
    }
    throw new ProtocolException("Field '" ~ field ~ "' must be numeric");
}

private long checkedResultAdd(long left, long right) {
    if (
        (right > 0 && left > long.max - right) ||
        (right < 0 && left < long.min - right)
    ) {
        throw new ProtocolException(
            "Integer overflow while evaluating hydrated solution"
        );
    }
    return left + right;
}

private long checkedResultSubtract(long left, long right) {
    if (
        (right > 0 && left < long.min + right) ||
        (right < 0 && left > long.max + right)
    ) {
        throw new ProtocolException(
            "Integer overflow while evaluating hydrated solution"
        );
    }
    return left - right;
}

private long checkedResultMultiply(long left, long right) {
    if (left == 0 || right == 0) {
        return 0;
    }
    if (
        (left == -1 && right == long.min) ||
        (right == -1 && left == long.min)
    ) {
        throw new ProtocolException(
            "Integer overflow while evaluating hydrated solution"
        );
    }
    const result = left * right;
    if (result / right != left) {
        throw new ProtocolException(
            "Integer overflow while evaluating hydrated solution"
        );
    }
    return result;
}
