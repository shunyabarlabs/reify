// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.explain;

/**
 * explainPlan() — The trust primitive.
 *
 * The trust primitive combines solver/runtime evidence with semantic-operation
 * provenance retained by Model:
 *
 *   LogicalPlan     → relational shape plus typed semantic operations
 *   PhysicalPlan    → what analyzeModel() + recommendRoute() already return
 *   ExecutionTrace  → runtime evidence aggregated by semantic operation
 *   DecisionExplanation → variable bindings explained in domain vocabulary
 */

import reify.model;
import reify.builders : DecisionSpace;
import reify.compiler;
import reify.result;
import reify.diagnostics;
import reify.router;

import std.conv : to;
import std.format : format;
import std.json : JSONValue, JSONType;
import std.stdio : writefln, writeln;
import std.algorithm : canFind, sort;

// =============================================================================
// 1. LOGICAL PLAN — "EXPLAIN" (pre-compilation)
// =============================================================================

struct DimensionInfo {
    string name;
    size_t valueCount;
}

struct ConstraintRecord {
    string kind;       // "exactlyOne", "atMostOne", "parityEven", "preferAtLeastOne", ...
    string[] dims;
    size_t groupCount;
    string level;      // "hard", "soft", "parity"
}

struct LogicalPlan {
    string spaceName;
    DimensionInfo[] dimensions;
    size_t rawCartesianSize;
    size_t filteredCandidates;
    double filterSelectivity;   // filteredCandidates / rawCartesianSize
    ConstraintRecord[] constraints;
    size_t hardCount;
    size_t softCount;
    size_t parityCount;
    size_t objectiveCount;
    SemanticOperation[] semanticOperations;
    size_t temporalOperationCount;

    void print() const {
        writeln("\n╔══════════════════════════════════════════════════════════╗");
        writefln("║  Navokoj EXPLAIN — Logical Plan: %-24s║", spaceName);
        writeln("╠══════════════════════════════════════════════════════════╣");
        writeln("║  Dimensions:");
        foreach (d; dimensions) {
            writefln("║    %-20s  %6d values", d.name, d.valueCount);
        }
        writefln("║  Raw Cartesian Space:   %12d tuples", rawCartesianSize);
        writefln("║  After Filter:          %12d candidates  (%.1f%%)",
                 filteredCandidates, filterSelectivity * 100.0);
        writeln("║  Constraints:");
        foreach (c; constraints) {
            writefln("║    [%-4s] %-20s groups=%d  dims=%s",
                     c.level, c.kind, c.groupCount, c.dims);
        }
        writefln("║  Hard: %d  Soft: %d  Parity: %d  Objective: %d",
                 hardCount, softCount, parityCount, objectiveCount);
        if (semanticOperations.length > 0) {
            writeln("║  Semantic operations:");
            foreach (operation; semanticOperations) {
                writefln(
                    "║    [%-12s] %-38s║",
                    operation.kind,
                    operation.label.length > 38
                        ? operation.label[0 .. 38]
                        : operation.label
                );
            }
        }
        writeln("╚══════════════════════════════════════════════════════════╝");
    }
}

// =============================================================================
// 2. PHYSICAL PLAN — "EXPLAIN" routing + encoding
//    Wraps the already-computed TopologyAnalysis + RoutingRecommendation
// =============================================================================

struct PhysicalPlan {
    // From analyzeModel() — already runs every solve
    size_t logicalVariables;
    size_t clauseCount;
    size_t parityConstraints;
    size_t objectiveCount;
    double alphaDensity;
    bool nearPhaseTransition;
    string structureClassification;
    string suggestedAction;
    string[] bottleneckWarnings;

    // From recommendRoute() — already computed
    string recommendedEngine;
    string recommendedHardware;
    string targetEndpoint;
    double estimatedSolveTimeMs;
    double estimatedCreditCost;
    string routingRationale;
    size_t semanticOperationCount;
    size_t spaceTimeOperationCount;

    void print() const {
        writeln("\n╔══════════════════════════════════════════════════════════╗");
        writeln("║  Navokoj EXPLAIN — Physical Plan                        ║");
        writeln("╠══════════════════════════════════════════════════════════╣");
        writefln("║  Structure:         %-34s║", structureClassification);
        writefln("║  Logical Variables: %-34d║", logicalVariables);
        writefln("║  Clauses:           %-34d║", clauseCount);
        writefln("║  Parity (XOR):      %-34d║", parityConstraints);
        writefln("║  Objectives:        %-34d║", objectiveCount);
        writefln("║  Semantic Ops:      %-34d║", semanticOperationCount);
        writefln("║  SpaceTime Ops:     %-34d║", spaceTimeOperationCount);
        writefln("║  α density:         %-34.3f║", alphaDensity);
        if (nearPhaseTransition) {
            writeln("║  ⚠️  Near phase transition (NP-hard boundary)           ║");
        }
        writeln("║  Routing:");
        writefln("║    Engine:    %-40s║", recommendedEngine);
        writefln("║    Hardware:  %-40s║", recommendedHardware);
        writefln("║    Endpoint:  %-40s║", targetEndpoint);
        writefln("║    Est. time: %-36.1f ms║", estimatedSolveTimeMs);
        writefln("║    Est. cost: $%-38.4f║", estimatedCreditCost);
        writeln("║  Rationale:");
        // Word-wrap rationale at 54 chars
        string rat = routingRationale;
        while (rat.length > 54) {
            writefln("║    %s", rat[0..54]);
            rat = rat[54..$];
        }
        if (rat.length > 0) writefln("║    %-50s║", rat);
        foreach (w; bottleneckWarnings) {
            writefln("║  ⚠️  %s", w.length > 52 ? w[0..52] : w);
        }
        writeln("╚══════════════════════════════════════════════════════════╝");
    }
}

// =============================================================================
// 3. EXECUTION TRACE — "EXPLAIN ANALYZE"
//    A view over SolveResult.rawResponse — data already returned by the API
// =============================================================================

struct SemanticImpact {
    string operationId;
    string parentId;
    string semanticDomain;
    string kind;
    string label;
    string status;
    string explanation;
    string[] dimensions;
    string[string] attributes;
    string[] constraints;
    size_t violatedConstraints;
}

struct ExecutionTrace {
    string selectedEngine;
    string hardware;
    double solveTimeMs;
    bool satisfiable;
    bool timeoutHit;
    double satisfactionRate;
    int hardSatisfied;
    int hardViolated;
    double softPenalty;
    string solveStatus;       // "satisfiable", "partial", "infeasible", "unknown"
    bool optimalityProved;
    string requestId;
    double billedUsd;
    SemanticImpact[] semanticImpacts;

    void print() const {
        writeln("\n╔══════════════════════════════════════════════════════════╗");
        writeln("║  Navokoj EXPLAIN ANALYZE — Execution Trace              ║");
        writeln("╠══════════════════════════════════════════════════════════╣");
        writefln("║  Request ID:     %-36s║", requestId);
        writefln("║  Engine Used:    %-36s║", selectedEngine);
        writefln("║  Hardware:       %-36s║", hardware);
        writefln("║  Solve Time:     %-32.2f ms║", solveTimeMs);
        writefln("║  Status:         %-36s║", solveStatus);
        writefln("║  Satisfaction:   %-32.1f%%  ║", satisfactionRate * 100.0);
        writefln("║  Hard Satisfied: %-36d║", hardSatisfied);
        writefln("║  Hard Violated:  %-36d║", hardViolated);
        writefln("║  Soft Penalty:   %-36.2f║", softPenalty);
        writefln("║  Timeout Hit:    %-36s║", timeoutHit ? "YES ⚠️" : "No");
        writefln("║  Optimality:     %-36s║", optimalityProved ? "Proved" : "Not proved");
        writefln("║  Billed:         $%-35.4f║", billedUsd);
        if (semanticImpacts.length > 0) {
            writeln("║  Semantic impacts:");
            foreach (impact; semanticImpacts) {
                writefln(
                    "║    [%-10s] %-40s║",
                    impact.kind,
                    impact.explanation.length > 40
                        ? impact.explanation[0 .. 40]
                        : impact.explanation
                );
            }
        }
        writeln("╚══════════════════════════════════════════════════════════╝");
    }
}

// =============================================================================
// 4. DECISION EXPLANATION — Policy causality over the chosen world
//    A view over variable_blame + constraint_matches from SolveResult.rawResponse
// =============================================================================

struct VariableBlame {
    string variableName;
    int blameScore;     // how many violated constraints reference this variable
}

struct DecisionExplanation {
    string queriedVariable;
    bool wasChosen;
    string[] bindingConstraints;     // constraints that reference this variable
    VariableBlame[] topBlamed;       // top variables by violation blame score
    string[] violatedConstraints;    // constraint names this variable appears in (violated)
    SemanticImpact[] semanticCauses; // domain-level operations binding the decision

    void print() const {
        writeln("\n╔══════════════════════════════════════════════════════════╗");
        writefln("║  Navokoj EXPLAIN DECISION — %-28s║", queriedVariable);
        writeln("╠══════════════════════════════════════════════════════════╣");
        writefln("║  Chosen:    %-42s║", wasChosen ? "YES" : "No");
        if (bindingConstraints.length > 0) {
            writeln("║  Appears in constraints:");
            foreach (c; bindingConstraints[0 .. (bindingConstraints.length < 5 ? bindingConstraints.length : 5)]) {
                writefln("║    - %-50s║", c.length > 50 ? c[0..50] : c);
            }
        }
        if (violatedConstraints.length > 0) {
            writeln("║  ⚠️  Violated constraints involving this variable:");
            foreach (c; violatedConstraints) {
                writefln("║    - %-50s║", c.length > 50 ? c[0..50] : c);
            }
        }
        if (topBlamed.length > 0) {
            writeln("║  Top variables by violation blame:");
            foreach (b; topBlamed[0 .. (topBlamed.length < 5 ? topBlamed.length : 5)]) {
                writefln("║    blame=%-3d  %s", b.blameScore, b.variableName);
            }
        }
        if (semanticCauses.length > 0) {
            writeln("║  Domain policy context:");
            foreach (cause; semanticCauses) {
                writefln(
                    "║    [%-10s] %-40s║",
                    cause.kind,
                    cause.explanation.length > 40
                        ? cause.explanation[0 .. 40]
                        : cause.explanation
                );
            }
        }
        writeln("╚══════════════════════════════════════════════════════════╝");
    }
}

// =============================================================================
// Builder functions — assemble views from already-available data
// =============================================================================

/// Build PhysicalPlan from a compiled model — wraps analyzeCompiled + recommendRoute
PhysicalPlan explainPhysical(Model model) {
    auto topology = analyzeModel(model);
    auto route = recommendRoute(topology);

    PhysicalPlan p;
    p.logicalVariables      = topology.logicalVariables;
    p.clauseCount           = topology.clauseCount;
    p.parityConstraints     = topology.parityCount;
    p.objectiveCount        = topology.objectiveCount;
    p.alphaDensity          = topology.alpha;
    p.nearPhaseTransition   = topology.nearPhaseTransition;
    p.structureClassification = topology.structureClassification;
    p.suggestedAction       = topology.suggestedAction;
    p.bottleneckWarnings    = topology.bottleneckWarnings;
    p.recommendedEngine     = route.engine;
    p.recommendedHardware   = route.hardware;
    p.targetEndpoint        = route.targetEndpoint;
    p.estimatedSolveTimeMs  = route.estimatedSolveTimeMs;
    p.estimatedCreditCost   = route.estimatedCreditCost;
    p.routingRationale      = route.rationale;
    foreach (operation; model.semanticOperations) {
        ++p.semanticOperationCount;
        if (operation.semanticDomain == "spacetime") {
            ++p.spaceTimeOperationCount;
        }
    }
    return p;
}

/// Build ExecutionTrace from SolveResult — reads already-present rawResponse fields
ExecutionTrace explainExecution(ref SolveResult result) {
    ExecutionTrace t;
    t.selectedEngine    = result.server.engineUsed;
    t.solveTimeMs       = result.server.solveTimeSeconds * 1000.0;
    t.timeoutHit        = result.server.timeoutBudgetHit;
    t.satisfactionRate  = result.server.hasSatisfactionRate ? result.server.satisfactionRate : 0.0;
    t.hardSatisfied     = cast(int) result.verification.hardSatisfied;
    t.hardViolated      = cast(int) result.verification.hardViolated;
    t.softPenalty       = result.verification.softPenalty;
    t.requestId         = result.server.requestId;
    t.optimalityProved  = (result.status == RunStatus.feasible && result.verification.hardViolated == 0);

    // Derive human status
    if (result.verification.feasible) {
        t.solveStatus = result.verification.hardViolated == 0 ? "satisfiable" : "partially_satisfied";
        t.satisfiable = true;
    } else {
        t.solveStatus = result.server.timeoutBudgetHit ? "timeout" : "infeasible";
        t.satisfiable = false;
    }

    // Billing from rawResponse — already present
    auto raw = result.rawResponse;
    if (raw.type == JSONType.object) {
        auto obj = raw.object;
        if ("routing" in obj && obj["routing"].type == JSONType.object) {
            auto routing = obj["routing"].object;
            if ("engine_used" in routing) t.selectedEngine = routing["engine_used"].str;
        }
        if ("billing" in obj && obj["billing"].type == JSONType.object) {
            auto billing = obj["billing"].object;
            if ("total_charge_usd" in billing)
                t.billedUsd = billing["total_charge_usd"].floating;
            if ("hardware" in billing)
                t.hardware = billing["hardware"].str;
        }
    }

    foreach (match; result.verification.matches) {
        if (
            match.semanticOperationId.length != 0 &&
            match.state != MatchState.satisfied
        ) {
            addSemanticImpact(
                t.semanticImpacts,
                result.semanticOperations,
                match.semanticOperationId,
                match.state.to!string,
                match.name,
                match.state == MatchState.violated
            );
        }
    }

    return t;
}

/// Build DecisionExplanation for a specific variable name from the raw API response.
/// `model` is needed to translate raw DIMACS literals back to logical variable names.
DecisionExplanation explainDecision(ref SolveResult result, Model model, string variableName) {
    DecisionExplanation ex;
    ex.queriedVariable = variableName;

    // Was the variable chosen?
    if (result.solution !is null && result.solution.has(variableName)) {
        auto val = result.solution.get(variableName);
        ex.wasChosen = (val.status == DecisionStatus.assigned && val.booleanValue);
    }

    // Which constraints reference this variable? (from verification.matches)
    foreach (ref match; result.verification.matches) {
        import std.algorithm : canFind;
        if (match.variables.canFind(variableName)) {
            ex.bindingConstraints ~= match.name;
            if (match.state == MatchState.violated) {
                ex.violatedConstraints ~= match.name;
            }
            if (match.semanticOperationId.length != 0) {
                addSemanticImpact(
                    ex.semanticCauses,
                    result.semanticOperations,
                    match.semanticOperationId,
                    match.state.to!string,
                    match.name,
                    match.state == MatchState.violated
                );
            }
        }
    }

    // Native SpaceTime clauses are intentionally omitted from the verification
    // report when satisfied. Recover their binding semantic context directly
    // from the model so an unchosen candidate can still be explained in terms
    // of availability, duration, ordering, or resource policies.
    size_t queriedIndex = size_t.max;
    foreach (index, variable; model.internalVariables) {
        if (variable.name == variableName) {
            queriedIndex = index;
            break;
        }
    }
    if (queriedIndex != size_t.max) {
        foreach (clause; model.internalNativeClauses) {
            bool references;
            foreach (literal; clause.literals) {
                if (literal.variableIndex == queriedIndex) {
                    references = true;
                    break;
                }
            }
            if (
                references &&
                clause.semanticOperationId.length != 0
            ) {
                if (!ex.bindingConstraints.canFind(clause.name)) {
                    ex.bindingConstraints ~= clause.name;
                }
                addSemanticImpact(
                    ex.semanticCauses,
                    result.semanticOperations,
                    clause.semanticOperationId,
                    "binding",
                    clause.name,
                    false
                );
            }
        }
    }

    // Variable blame from rawResponse.violations_summary.variable_blame
    // Translate raw DIMACS literal IDs → logical variable names via model.
    auto raw = result.rawResponse;
    if (raw.type == JSONType.object) {
        auto obj = raw.object;
        if ("violations_summary" in obj) {
            auto vs = obj["violations_summary"].object;
            if ("variable_blame" in vs && vs["variable_blame"].type == JSONType.object) {
                foreach (varId, blameVal; vs["variable_blame"].object) {
                    VariableBlame b;
                    b.blameScore   = cast(int) blameVal.integer;
                    b.variableName = hydrateVariableName(varId, model);
                    ex.topBlamed ~= b;
                }
                import std.algorithm : sort;
                ex.topBlamed.sort!((a, b) => a.blameScore > b.blameScore);
            }
        }
    }

    return ex;
}

private void addSemanticImpact(
    ref SemanticImpact[] impacts,
    SemanticOperation[] operations,
    string operationId,
    string status,
    string constraintName,
    bool violated
) {
    size_t existing = size_t.max;
    foreach (index, impact; impacts) {
        if (impact.operationId == operationId) {
            existing = index;
            break;
        }
    }
    if (existing == size_t.max) {
        SemanticOperation operation;
        bool found;
        foreach (candidate; operations) {
            if (candidate.id == operationId) {
                operation = candidate;
                found = true;
                break;
            }
        }
        if (!found) return;

        SemanticImpact impact;
        impact.operationId = operation.id;
        impact.parentId = operation.parentId;
        impact.semanticDomain = operation.semanticDomain;
        impact.kind = operation.kind;
        impact.label = operation.label;
        impact.status = status;
        impact.explanation = describeSemanticOperation(operation);
        impact.dimensions = operation.dimensions.dup;
        impact.attributes = operation.attributes.dup;
        impacts ~= impact;
        existing = impacts.length - 1;
    }
    if (
        constraintName.length != 0 &&
        !impacts[existing].constraints.canFind(constraintName)
    ) {
        impacts[existing].constraints ~= constraintName;
    }
    if (violated) {
        ++impacts[existing].violatedConstraints;
        impacts[existing].status = "violated";
    }
}

private string describeSemanticOperation(SemanticOperation operation) {
    auto attributes = operation.attributes;
    switch (operation.kind) {
        case "duration":
            return format(
                "%s occupies %s time slots",
                attribute(attributes, "activity"),
                attribute(attributes, "duration_slots")
            );
        case "within":
            return format(
                "%s is available within %s",
                attribute(attributes, "resource_dimension"),
                attribute(attributes, "allowed_values")
            );
        case "before":
            return format(
                "%s must finish before %s starts",
                attribute(attributes, "earlier"),
                attribute(attributes, "later")
            );
        case "nonOverlapping":
            return format(
                "%s assignments cannot overlap",
                attribute(attributes, "resource_dimension")
            );
        case "capacity":
            return format(
                "%s capacity is %s per occupied slot",
                attribute(attributes, "resource_dimension"),
                attribute(attributes, "limit")
            );
        case "prefer":
            return format(
                "prefer %s=%s with weight %s",
                attribute(attributes, "dimension"),
                attribute(attributes, "value"),
                attribute(attributes, "weight")
            );
        case "timeDimension":
            return format(
                "%s is ordered as %s",
                attribute(attributes, "time_dimension"),
                attribute(attributes, "ordered_values")
            );
        default:
            return operation.label;
    }
}

private string attribute(
    string[string] attributes,
    string name
) {
    auto found = name in attributes;
    return found is null ? "?" : *found;
}

/// Translate a raw DIMACS literal ID (as a string) to the logical variable name.
/// Falls back to the raw string if the literal does not map to a known variable.
private string hydrateVariableName(string rawId, Model model) {
    import std.conv : to;
    import std.math : abs;
    long lit;
    try { lit = to!long(rawId); }
    catch (Exception e) { return rawId; }
    if (lit == 0) return rawId;
    auto idx = cast(size_t)(abs(lit) - 1);
    if (model is null || idx >= model.internalVariables.length) return rawId;
    return model.internalVariables[idx].name;
}

// =============================================================================
// 5. FREE FUNCTION: explainLogical — mirrors explainPhysical signature
// =============================================================================

/// Build LogicalPlan from a DecisionSpace.
/// Returns the cached _logicalPlan populated as a side-effect of groupBy() calls.
LogicalPlan explainLogical(DecisionSpace space) {
    auto plan = space._logicalPlan;
    foreach (operation; space.model.semanticOperations) {
        auto operationSpace = "space" in operation.attributes;
        if (
            operationSpace !is null &&
            *operationSpace == space.spaceName
        ) {
            plan.semanticOperations ~= operation;
            if (operation.semanticDomain == "spacetime") {
                ++plan.temporalOperationCount;
            }
        }
    }
    return plan;
}