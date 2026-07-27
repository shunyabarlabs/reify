// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module tests.spacetime_tests;

import reify;
import reify.result : buildSolveResult;

import std.algorithm : sort;
import std.conv : to;
import std.json : JSONType, JSONValue;
import std.stdio : writeln;
import std.string : indexOf, startsWith;

private size_t assertions;

private void check(bool condition, string message) {
    ++assertions;
    if (!condition) throw new Exception("Assertion failed: " ~ message);
}

private size_t variableIndex(Model model, string name) {
    foreach (index, variable; model.variables) {
        if (variable.name == name) return index;
    }
    throw new Exception("Unknown test variable " ~ name);
}

private bool clauseWithOperationReferences(
    Model model,
    string operationKind,
    size_t left,
    size_t right = size_t.max
) {
    foreach (clause; model.nativeClauses) {
        SemanticOperation operation;
        if (
            !model.findSemanticOperation(
                clause.semanticOperationId,
                operation
            ) ||
            operation.kind != operationKind
        ) {
            continue;
        }
        bool hasLeft;
        bool hasRight = right == size_t.max;
        foreach (literal; clause.literals) {
            hasLeft |= literal.variableIndex == left;
            hasRight |= literal.variableIndex == right;
        }
        if (hasLeft && hasRight) return true;
    }
    return false;
}

private bool bruteForceSatisfiable(CompiledModel compiled) {
    if (compiled.generatedVariableCount > 22) {
        throw new Exception("Test formula is too large for exhaustive SAT");
    }
    const assignmentCount =
        1UL << cast(uint) compiled.generatedVariableCount;
    foreach (bits; 0UL .. assignmentCount) {
        bool allSatisfied = true;
        foreach (clause; compiled.clauses) {
            bool satisfied;
            foreach (literal; clause.literals) {
                const index = cast(uint)(
                    (literal < 0 ? -literal : literal) - 1
                );
                const value = ((bits >> index) & 1UL) != 0;
                if (literal < 0 ? !value : value) {
                    satisfied = true;
                    break;
                }
            }
            if (!satisfied) {
                allSatisfied = false;
                break;
            }
        }
        if (allSatisfied) return true;
    }
    return false;
}

private string[] canonicalClauseMultiset(CompiledModel compiled) {
    string[] result;
    foreach (clause; compiled.clauses) {
        string key =
            clause.level.to!string ~ ":" ~
            clause.weight.to!string;
        foreach (literal; clause.literals) {
            key ~= ":" ~ literal.to!string;
        }
        result ~= key;
    }
    result.sort;
    return result;
}

private bool hasSemanticKind(
    SemanticOperation[] operations,
    string kind
) {
    foreach (operation; operations) {
        if (operation.kind == kind) return true;
    }
    return false;
}

private void testDynamicSpaceTimeRecipes() {
    auto model = new Model("surgery-policy");
    auto schedule = model.spaceTime("surgery")
        .dimension("patient", ["p1", "p2"])
        .dimension("doctor", ["master", "resident"])
        .dimension("room", ["or1", "or2"])
        .dimension("activity", ["preop", "surgery"])
        .time("slot", ["08:00", "09:00", "10:00"])
        .build();

    schedule.duration("preop", 1).duration("surgery", 2);
    auto workingHours = timeWindow(["08:00", "09:00"]);
    auto noDoctorCollision =
        nonOverlapping("doctor").within(workingHours);
    auto surgeryPolicy =
        exactlyOnePer("patient", "activity")
            .and(noDoctorCollision)
            .and(capacity("room", 1))
            .and(prefer("doctor", "master", 20));

    schedule.apply(surgeryPolicy);
    schedule.before("preop", "surgery", "patient");

    auto logicalPlan = schedule.explainPlan();
    check(
        logicalPlan.temporalOperationCount >= 8,
        "logical plan exposes SpaceTime operations"
    );
    check(
        hasSemanticKind(logicalPlan.semanticOperations, "duration") &&
        hasSemanticKind(logicalPlan.semanticOperations, "before") &&
        hasSemanticKind(logicalPlan.semanticOperations, "within"),
        "logical plan retains temporal vocabulary"
    );
    auto physicalPlan = schedule.explainPhysical();
    check(
        physicalPlan.spaceTimeOperationCount ==
            logicalPlan.temporalOperationCount,
        "physical plan counts the same SpaceTime operations"
    );

    bool hasHorizonGuard;
    bool hasIntervalCollision;
    bool hasOrderingGuard;
    foreach (clause; model.nativeClauses) {
        hasHorizonGuard |= clause.name.indexOf("fits_horizon") >= 0;
        hasIntervalCollision |= clause.name.indexOf("non_overlap") >= 0;
        hasOrderingGuard |= clause.name.indexOf("_before_") >= 0;
    }
    check(hasHorizonGuard, "duration forbids starts past the time horizon");
    check(
        hasIntervalCollision,
        "non-overlap accounts for occupied duration intervals"
    );
    check(
        hasOrderingGuard,
        "before lowers end-before-start ordering clauses"
    );

    CompileOptions options;
    options.preferQState = false;
    options.preferNativeParity = false;
    auto compiled = compile(model, options);
    check(
        compiled.request.object["weights"].type == JSONType.array,
        "recipe preference lowers to weighted CNF"
    );
    check(
        compiled.clauses.length > 0,
        "temporal policies lower to ordinary compiler clauses"
    );

    auto wcnf = model.emit!WCNF(options);
    check(
        wcnf.payload.indexOf("p wcnf ") >= 0,
        "weighted workflow exports standard WCNF"
    );
    check(
        wcnf.verificationManifest.object["clauses"].array.length ==
            compiled.clauses.length,
        "WCNF export includes clause provenance manifest"
    );
    check(
        wcnf.verificationManifest.object[
            "semantic_operations"
        ].array.length == logicalPlan.temporalOperationCount,
        "verification manifest carries semantic operations"
    );

    JSONValue[] assignment;
    assignment.length = compiled.generatedVariableCount;
    assignment[] = JSONValue(false);
    JSONValue[string] response;
    response["success"] = JSONValue(true);
    response["satisfiable"] = JSONValue(false);
    response["assignment"] = JSONValue(assignment);
    response["timeout_budget_hit"] = JSONValue(true);
    auto result = buildSolveResult(compiled, JSONValue(response));
    auto trace = explainExecution(result);
    check(
        trace.semanticImpacts.length > 0,
        "execution trace aggregates violated semantic operations"
    );
    auto decision = explainDecision(
        result,
        model,
        model.variables[0].name
    );
    check(
        decision.semanticCauses.length > 0,
        "decision explanation exposes domain policy context"
    );
    check(
        decision.semanticCauses[0].explanation.indexOf("literal") < 0,
        "decision explanation speaks in domain vocabulary"
    );

    bool rejectedLossyCnf;
    try {
        model.emit!DIMACS(options);
    } catch (CapabilityException) {
        rejectedLossyCnf = true;
    }
    check(
        rejectedLossyCnf,
        "DIMACS CNF rejects workflows with soft semantics"
    );
}

private void testTypedSpaceTime() {
    enum Patient {
        p1,
        p2
    }
    enum Doctor {
        master,
        resident
    }
    enum Activity {
        preop,
        surgery
    }
    enum Slot {
        morning,
        noon,
        evening
    }

    alias PatientDim = Dimension!("patient", Patient);
    alias DoctorDim = Dimension!("doctor", Doctor);
    alias ActivityDim = Dimension!("activity", Activity);
    alias SlotDim = TimeDimension!("slot", Slot);
    alias MisspelledDim = Dimension!("docter", Doctor);

    auto model = new Model("typed-surgery");
    auto schedule =
        model.spaceTime!(PatientDim, DoctorDim, ActivityDim, SlotDim)(
            "typed-surgery"
        )
        .dimension!PatientDim([Patient.p1, Patient.p2])
        .dimension!DoctorDim([Doctor.master, Doctor.resident])
        .dimension!ActivityDim([Activity.preop, Activity.surgery])
        .time!SlotDim([Slot.morning, Slot.noon, Slot.evening])
        .build();

    schedule.duration!ActivityDim(Activity.preop, 1);
    schedule.duration!ActivityDim(Activity.surgery, 2);
    schedule.groupBy!(PatientDim, ActivityDim)().exactlyOne();
    schedule.groupBy!(DoctorDim, SlotDim)().atMostOne();
    schedule.within!DoctorDim(
        timeWindow([Slot.morning, Slot.noon])
    );
    schedule.before("preop", "surgery", "patient");
    schedule.apply(prefer!DoctorDim(Doctor.master, 5));

    static assert(
        __traits(compiles, schedule.groupBy!PatientDim()),
        "dimension at first type-list position must compile"
    );
    static assert(
        __traits(compiles, schedule.groupBy!SlotDim()),
        "dimension at last type-list position must compile"
    );
    static assert(
        !__traits(compiles, schedule.groupBy!MisspelledDim()),
        "unknown typed dimensions must fail during D compilation"
    );

    CompileOptions options;
    options.preferQState = false;
    auto compiled = compile(model, options);
    check(
        compiled.generatedVariableCount > model.variables.length,
        "typed temporal model compiles through the shared finite-domain IR"
    );
}

private void testTemporalBoundaries() {
    auto model = new Model("temporal-boundaries");
    auto schedule = model.spaceTime("boundary")
        .dimension("resource", ["r"])
        .dimension("activity", ["long", "short"])
        .time("slot", ["0", "1", "2"])
        .build();
    schedule.duration("long", 2);
    schedule.duration("short", 1);
    schedule.apply(nonOverlapping("resource"));

    const longAt0 = variableIndex(
        model,
        "boundary_resource_r_activity_long_slot_0"
    );
    const longAt1 = variableIndex(
        model,
        "boundary_resource_r_activity_long_slot_1"
    );
    const longAt2 = variableIndex(
        model,
        "boundary_resource_r_activity_long_slot_2"
    );
    const shortAt1 = variableIndex(
        model,
        "boundary_resource_r_activity_short_slot_1"
    );
    const shortAt2 = variableIndex(
        model,
        "boundary_resource_r_activity_short_slot_2"
    );

    check(
        clauseWithOperationReferences(
            model,
            "nonOverlapping",
            longAt0,
            shortAt1
        ),
        "nonOverlapping rejects a mid-interval collision"
    );
    check(
        !clauseWithOperationReferences(
            model,
            "nonOverlapping",
            longAt0,
            shortAt2
        ),
        "nonOverlapping admits an adjacent interval"
    );
    check(
        !clauseWithOperationReferences(
            model,
            "duration",
            longAt1
        ),
        "duration two admits its latest valid start"
    );
    check(
        clauseWithOperationReferences(
            model,
            "duration",
            longAt2
        ),
        "duration two forbids a start beyond the horizon"
    );
    check(
        !clauseWithOperationReferences(
            model,
            "duration",
            shortAt2
        ),
        "duration one admits the final slot"
    );
}

private void testContradictoryPoliciesAreUnsat() {
    auto model = new Model("explicit-unsat");
    auto space = model.decisionSpace("choice")
        .dimension("case", ["only"])
        .dimension("option", ["a", "b"])
        .build();
    space.groupBy("case").exactlyOne();
    foreach (candidate; space.candidates) {
        model.requireClause(
            "forbid_" ~ candidate.varName,
            [logicalNot(candidate.expr)]
        );
    }

    CompileOptions options;
    options.preferQState = false;
    auto compiled = compile(model, options);
    check(
        !bruteForceSatisfiable(compiled),
        "contradictory exactly-one and forbid-all policies report UNSAT"
    );
}

private void testPortableHardExports() {
    auto model = new Model("portable-hard-policy");
    auto selected = model.booleanVar("selected");
    auto approved = model.booleanVar("approved");
    model.require("selection requires approval", implies(selected, approved));
    model.require("select", selected);
    model.requireClause(
        "signed clause",
        [selected, logicalNot(approved)]
    );

    CompileOptions options;
    options.preferQState = false;
    options.preferNativeParity = false;

    auto cnf = model.emit!CNF(options);
    check(
        cnf.payload.indexOf("\"num_vars\"") >= 0,
        "CNF target emits portable clause JSON"
    );

    auto dimacs = model.emit!DIMACS(options);
    auto parsedDimacs = parseDimacs(dimacs.payload);
    check(
        parsedDimacs.clauses.length > 0,
        "DIMACS target round-trips through the existing parser"
    );

    auto opb = model.emit!OPB(options);
    auto parsedOpb = parseOpb(opb.payload);
    check(
        parsedOpb.constraints.length == parsedDimacs.clauses.length,
        "OPB target round-trips the lowered hard clauses"
    );
    bool sawNegatedLiteral;
    foreach (constraint; parsedOpb.constraints) {
        foreach (term; constraint.terms) {
            sawNegatedLiteral |= term.negated;
        }
    }
    auto reparsedOpb = parseOpb(parsedOpb.toOpb());
    check(
        sawNegatedLiteral &&
        reparsedOpb.constraints.length == parsedOpb.constraints.length,
        "OPB round-trip preserves signed literal structure"
    );

    auto cloud = model.emit!NavokojIR(options);
    check(
        cloud.payload.indexOf("\"clauses\"") >= 0,
        "NavokojIR target emits the cloud wire request"
    );
    check(
        cloud.verificationManifest.object["variables"].array.length == 2,
        "portable exports retain logical-variable hydration metadata"
    );
}

private void testAllLossyTargetsRejectSoftModels() {
    auto model = new Model("soft-export-rejection");
    auto selected = model.booleanVar("selected");
    model.preferClause("prefer selected", [selected], 2);
    CompileOptions options;
    options.preferQState = false;

    bool cnfRejected;
    bool dimacsRejected;
    bool opbRejected;
    try model.emit!CNF(options);
    catch (CapabilityException) cnfRejected = true;
    try model.emit!DIMACS(options);
    catch (CapabilityException) dimacsRejected = true;
    try model.emit!OPB(options);
    catch (CapabilityException) opbRejected = true;
    check(cnfRejected, "CNF independently rejects soft semantics");
    check(dimacsRejected, "DIMACS independently rejects soft semantics");
    check(opbRejected, "OPB independently rejects soft semantics");
}

private CompiledModel compiledRecipeOrder(bool reverse) {
    auto model = new Model(reverse ? "reverse" : "forward");
    auto schedule = model.spaceTime("order")
        .dimension("job", ["a", "b"])
        .dimension("doctor", ["master"])
        .time("slot", ["0", "1"])
        .build();
    auto collision = nonOverlapping("doctor");
    auto preference = prefer("doctor", "master", 3);
    if (reverse) {
        schedule.apply(preference);
        schedule.apply(collision);
    } else {
        schedule.apply(collision);
        schedule.apply(preference);
    }
    CompileOptions options;
    options.preferQState = false;
    return compile(model, options);
}

private void testRecipeOrderingAndSoftConsolidation() {
    auto forward = compiledRecipeOrder(false);
    auto reverse = compiledRecipeOrder(true);
    check(
        canonicalClauseMultiset(forward) ==
            canonicalClauseMultiset(reverse),
        "recipe application order preserves the encoded clause multiset"
    );

    auto model = new Model("preference-consolidation");
    auto schedule = model.spaceTime("preference")
        .dimension("doctor", ["master", "resident"])
        .time("slot", ["0"])
        .build();
    schedule.apply(prefer("doctor", "master", 2));
    schedule.apply(prefer("doctor", "master", 3));
    CompileOptions options;
    options.preferQState = false;
    auto compiled = compile(model, options);

    size_t matchingSoftClauses;
    bool retainedBothOperations;
    foreach (clause; compiled.clauses) {
        if (clause.level == ConstraintLevel.soft) {
            ++matchingSoftClauses;
            retainedBothOperations |=
                clause.semanticOperationIds.length == 2 &&
                clause.weight == 5.0;
        }
    }
    check(
        matchingSoftClauses == 1,
        "equivalent preferences consolidate to one WCNF clause"
    );
    check(
        retainedBothOperations,
        "soft consolidation retains both policy provenances"
    );
}

int main() {
    testDynamicSpaceTimeRecipes();
    testTypedSpaceTime();
    testTemporalBoundaries();
    testContradictoryPoliciesAreUnsat();
    testPortableHardExports();
    testAllLossyTargetsRejectSoftModels();
    testRecipeOrderingAndSoftConsolidation();
    writeln("SpaceTime tests passed: ", assertions, " assertions");
    return 0;
}