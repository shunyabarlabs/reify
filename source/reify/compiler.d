// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.compiler;

import reify.errors : CapabilityException, ModelException;
import reify.model;

import std.algorithm : all, any, canFind, sort;
import std.bigint : BigInt;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import std.math : isFinite;

private enum ulong maximumExactDoubleInteger = 9_007_199_254_740_991UL;

enum Backend {
    cnf,
    hybrid,
    qstate
}

string backendName(Backend backend) {
    final switch (backend) {
        case Backend.cnf:
            return "cnf";
        case Backend.hybrid:
            return "hybrid";
        case Backend.qstate:
            return "qstate";
    }
}

struct CompileOptions {
    // `auto` remains the low-level compiler default because it can select a
    // representation such as Q-State. The runnable app sets its hosted API
    // default explicitly to `nitro`.
    string engine = "auto";
    string hardware;
    double timeoutBudgetSeconds = 0.0;
    double minSatisfaction = -1.0;
    double minWeightedSatisfaction = -1.0;
    size_t maxIntegerDomain = 10_001;
    size_t maxPseudoBooleanTerms = 10_000;
    size_t maxBddNodesPerConstraint = 500_000;
    size_t maxEncodedVariables = 1_000_000;
    size_t maxEncodedClauses = 5_000_000;
    bool preferQState = true;
    bool preferNativeParity = true;
    bool diagnosticOnly = false;
    double maximumEncodedWeight = 9.0e15;
}

struct DomainAtom {
    long value;
    int literalWhenSelected;
}

struct EncodedClause {
    int[] literals;
    string constraintName;
    ConstraintLevel level;
    double weight;
    bool structural;
    int priorityLevel = -1;
    string semanticOperationId;
    string[] constraintNames;
    string[] semanticOperationIds;
}

/**
 * The complete compilation artifact used both for API submission and hydration.
 */
final class CompiledModel {
    Model model;
    Backend backend;
    JSONValue request;
    DomainAtom[][] atoms;
    int[][] integerOrderLiterals;
    EncodedClause[] clauses;
    size_t[] qstateVariableOrder;
    size_t generatedVariableCount;
    bool diagnosticProjection;
    string[] warnings;

    this(Model model) {
        this.model = model;
        this.atoms.length = model.internalVariables.length;
        this.integerOrderLiterals.length = model.internalVariables.length;
    }

    JSONValue summary() {
        JSONValue[string] value;
        value["model"] = JSONValue(model.name);
        value["backend"] = JSONValue(backendName(backend));
        value["logical_variables"] = JSONValue(
            cast(long) model.internalVariables.length
        );
        value["encoded_variables"] = JSONValue(cast(long) generatedVariableCount);
        value["clauses"] = JSONValue(cast(long) clauses.length);
        value["semantic_operations"] = JSONValue(
            cast(long) model.semanticOperations.length
        );

        JSONValue[] warningValues;
        foreach (warning; warnings) {
            warningValues ~= JSONValue(warning);
        }
        value["warnings"] = JSONValue(warningValues);
        return JSONValue(value);
    }
}

CompiledModel compile(Model model, CompileOptions options = CompileOptions()) {
    // This function is the main lowering boundary. Everything above it is a
    // symbolic D model; everything below it must be valid API-contract JSON.
    // For SpaceTime models, this is also the finite-model boundary: possible
    // worlds and relational laws are reduced to a solver-searchable valuation.
    validateModel(model, options);

    const qstateShape = supportsQState(model);
    const qstateEngineRequested = options.engine == "qstate";
    if (qstateEngineRequested && (!options.preferQState || !qstateShape)) {
        throw new CapabilityException(
            "The qstate engine requires a Q-State-compatible model containing " ~
            "only hard categorical equality, inequality, singleton-domain, " ~
            "and all-different constraints"
        );
    }

    CompiledModel result;
    if (
        options.preferQState &&
        qstateShape &&
        (options.engine == "auto" || qstateEngineRequested)
    ) {
        result = compileQState(model, options);
    } else {
        result = compileCnf(model, options);
    }

    // CompiledModel retains the source model for hydration and verification.
    // Freeze only after every compilation step succeeds so the wire artifact and
    // its symbol tables can never drift apart.
    model.freeze();
    return result;
}

void validateModel(Model model, CompileOptions options = CompileOptions()) {
    if (model is null) {
        throw new ModelException("Cannot compile a null model");
    }
    const variables = model.internalVariables;

    if (options.maxIntegerDomain == 0) {
        throw new ModelException("maxIntegerDomain must be positive");
    }
    if (options.maxPseudoBooleanTerms == 0) {
        throw new ModelException("maxPseudoBooleanTerms must be positive");
    }
    if (options.maxBddNodesPerConstraint == 0) {
        throw new ModelException(
            "maxBddNodesPerConstraint must be positive"
        );
    }
    if (options.maxEncodedVariables == 0) {
        throw new ModelException("maxEncodedVariables must be positive");
    }
    if (options.maxEncodedVariables > int.max) {
        throw new ModelException(
            "maxEncodedVariables cannot exceed the signed DIMACS literal range"
        );
    }
    if (options.maxEncodedClauses == 0) {
        throw new ModelException("maxEncodedClauses must be positive");
    }
    if (variables.length > options.maxEncodedVariables) {
        throw new CapabilityException(format(
            "Model declares %s variables, above the configured encoded-variable " ~
            "limit of %s",
            variables.length,
            options.maxEncodedVariables
        ));
    }
    if (options.engine.length == 0) {
        throw new ModelException("engine cannot be empty");
    }
    if (
        !options.maximumEncodedWeight.isFinite ||
        options.maximumEncodedWeight < 1.0 ||
        options.maximumEncodedWeight >
            cast(double) maximumExactDoubleInteger
    ) {
        throw new ModelException(
            "maximumEncodedWeight must be between 1 and the largest exactly " ~
            "representable IEEE-754 integer"
        );
    }
    if (
        !options.timeoutBudgetSeconds.isFinite ||
        options.timeoutBudgetSeconds < 0.0
    ) {
        throw new ModelException(
            "timeoutBudgetSeconds must be finite and non-negative"
        );
    }
    if (
        !options.minSatisfaction.isFinite ||
        (
            options.minSatisfaction != -1.0 &&
            (
                options.minSatisfaction < 0.0 ||
                options.minSatisfaction > 1.0
            )
        )
    ) {
        throw new ModelException(
            "minSatisfaction must be -1 (disabled) or between 0 and 1"
        );
    }
    if (
        !options.minWeightedSatisfaction.isFinite ||
        (
            options.minWeightedSatisfaction != -1.0 &&
            (
                options.minWeightedSatisfaction < 0.0 ||
                options.minWeightedSatisfaction > 1.0
            )
        )
    ) {
        throw new ModelException(
            "minWeightedSatisfaction must be -1 (disabled) or between 0 and 1"
        );
    }
    foreach (variable; variables) {
        if (
            variable.kind == VariableKind.integer &&
            variable.domainSize > options.maxIntegerDomain
        ) {
            throw new CapabilityException(format(
                "Integer variable '%s' has %s values; the exact finite-domain " ~
                "encoder limit is %s. Tighten its bounds or use a future MILP backend.",
                variable.name,
                variable.domainSize,
                options.maxIntegerDomain
            ));
        }
    }
}

private bool supportsQState(Model model) {
    const variables = model.internalVariables;
    const objectives = model.internalObjectives;
    const parityConstraints = model.internalParityConstraints;
    if (
        variables.length == 0 ||
        objectives.length != 0 ||
        parityConstraints.length != 0 ||
        model.internalNativeClauses.length != 0
    ) {
        return false;
    }

    string[] canonicalStates;
    foreach (variable; variables) {
        if (variable.kind != VariableKind.categorical) {
            return false;
        }
        if (canonicalStates.length == 0) {
            canonicalStates = variable.states.dup;
        } else if (canonicalStates != variable.states) {
            return false;
        }
    }

    foreach (constraint; model.internalConstraints) {
        if (constraint.level != ConstraintLevel.hard) {
            return false;
        }
        if (!isQStateExpression(constraint.expression.node, model)) {
            return false;
        }
    }

    return true;
}

private bool isQStateExpression(ExpressionNode node, Model model) {
    if (node is null) {
        return false;
    }

    switch (node.kind) {
        case ExpressionKind.logicalAnd:
            return isQStateExpression(node.children[0], model) &&
                isQStateExpression(node.children[1], model);
        case ExpressionKind.equal:
        case ExpressionKind.notEqual:
            return isCategoryComparison(node, model);
        case ExpressionKind.allDifferent:
            const variables = model.internalVariables;
            return node.children.length >= 2 &&
                node.children.all!(child =>
                    child.kind == ExpressionKind.variable &&
                    variables[child.variableIndex].kind ==
                        VariableKind.categorical
                );
        default:
            return false;
    }
}

private bool isCategoryComparison(ExpressionNode node, Model model) {
    auto left = node.children[0];
    auto right = node.children[1];
    const variables = model.internalVariables;

    const leftVariable =
        left.kind == ExpressionKind.variable &&
        variables[left.variableIndex].kind == VariableKind.categorical;
    const rightVariable =
        right.kind == ExpressionKind.variable &&
        variables[right.variableIndex].kind == VariableKind.categorical;
    const leftConstant = left.kind == ExpressionKind.integerConstant;
    const rightConstant = right.kind == ExpressionKind.integerConstant;

    if (leftVariable && rightVariable) {
        return true;
    }

    // The documented Q-State contract supports singleton `in`, but does not
    // document a domain-exclusion operator.
    if (node.kind == ExpressionKind.notEqual) {
        return false;
    }

    if (leftVariable && rightConstant) {
        return categoryConstantInRange(
            variables[left.variableIndex],
            right.integerValue
        );
    }
    if (leftConstant && rightVariable) {
        return categoryConstantInRange(
            variables[right.variableIndex],
            left.integerValue
        );
    }
    return false;
}

private CompiledModel compileQState(Model model, CompileOptions options) {
    auto result = new CompiledModel(model);
    result.backend = Backend.qstate;

    JSONValue[] constraints;
    foreach (constraint; model.internalConstraints) {
        appendQStateExpression(
            constraint.expression.node,
            model,
            constraints,
            constraint.name
        );
    }

    const variables = model.internalVariables;
    foreach (index, variable; variables) {
        result.qstateVariableOrder ~= index;
        foreach (value; variable.domainValues) {
            result.atoms[index] ~= DomainAtom(value, 0);
        }
    }

    JSONValue[string] request;
    request["num_vars"] = JSONValue(cast(long) variables.length);
    request["num_states"] = JSONValue(
        cast(long) variables[0].states.length
    );
    request["constraints"] = JSONValue(constraints);
    if (options.hardware.length != 0) {
        request["hardware"] = JSONValue(options.hardware);
        request["problem_type"] = JSONValue("qstate-geometric");
    } else {
        request["engine"] = JSONValue("qstate");
    }
    if (options.timeoutBudgetSeconds > 0.0) {
        request["timeout_budget_seconds"] =
            JSONValue(options.timeoutBudgetSeconds);
    }
    if (options.minSatisfaction >= 0.0) {
        request["min_satisfaction"] =
            JSONValue(options.minSatisfaction);
    }
    if (options.minWeightedSatisfaction >= 0.0) {
        throw new CapabilityException(
            "minWeightedSatisfaction requires a weighted CNF model"
        );
    }

    result.generatedVariableCount = variables.length;
    result.request = JSONValue(request);
    return result;
}

private void appendQStateExpression(
    ExpressionNode node,
    Model model,
    ref JSONValue[] output,
    string constraintName
) {
    if (node.kind == ExpressionKind.logicalAnd) {
        appendQStateExpression(node.children[0], model, output, constraintName);
        appendQStateExpression(node.children[1], model, output, constraintName);
        return;
    }

    JSONValue[string] constraint;
    if (node.kind == ExpressionKind.allDifferent) {
        JSONValue[] variables;
        foreach (child; node.children) {
            variables ~= JSONValue(cast(long) child.variableIndex + 1);
        }
        constraint["vars"] = JSONValue(variables);
        constraint["type"] = JSONValue("all_diff");
        output ~= JSONValue(constraint);
        return;
    }

    auto left = node.children[0];
    auto right = node.children[1];
    const typeName =
        node.kind == ExpressionKind.equal ? "eq" : "neq";

    if (
        left.kind == ExpressionKind.variable &&
        right.kind == ExpressionKind.variable
    ) {
        JSONValue[] variables = [
            JSONValue(cast(long) left.variableIndex + 1),
            JSONValue(cast(long) right.variableIndex + 1)
        ];
        constraint["vars"] = JSONValue(variables);
        constraint["type"] = JSONValue(typeName);
        output ~= JSONValue(constraint);
        return;
    }

    auto variable = left.kind == ExpressionKind.variable ? left : right;
    auto constant = left.kind == ExpressionKind.integerConstant ? left : right;
    if (node.kind == ExpressionKind.notEqual) {
        throw new CapabilityException(
            "Q-State domain exclusions are not supported by the current API contract"
        );
    }

    const domain = model.internalVariables[variable.variableIndex];
    if (!categoryConstantInRange(domain, constant.integerValue)) {
        throw new CapabilityException(format(
            "Categorical constant %s is outside the domain of '%s'",
            constant.integerValue,
            domain.name
        ));
    }

    constraint["var"] = JSONValue(cast(long) variable.variableIndex + 1);
    constraint["type"] = JSONValue("in");
    constraint["states"] = JSONValue([
        JSONValue(checkedAdd(
            constant.integerValue,
            1,
            "Q-State state index"
        ))
    ]);
    output ~= JSONValue(constraint);
}

private bool categoryConstantInRange(
    const DomainVariable variable,
    long value
) {
    return value >= 0 && cast(ulong) value < variable.states.length;
}

private final class CnfCompiler {
    Model model;
    CompileOptions options;
    CompiledModel result;
    int nextSatVariable;
    int trueSatVariable;
    int[ExpressionNode] booleanMemo;
    int[int] objectiveLevelByPriority;
    bool useNativeParity;
    string currentSemanticOperationId;

    this(Model model, CompileOptions options) {
        this.model = model;
        this.options = options;
        this.result = new CompiledModel(model);
        this.result.diagnosticProjection = options.diagnosticOnly;
    }

    CompiledModel run() {
        allocateDomainAtoms();

        foreach (clause; model.internalNativeClauses) {
            if (
                options.diagnosticOnly &&
                clause.level != ConstraintLevel.hard
            ) {
                continue;
            }

            currentSemanticOperationId = clause.semanticOperationId;
            int[] literals;
            foreach (literal; clause.literals) {
                const positive = atomLiteral(literal.variableIndex, 1);
                literals ~= literal.negated ? -positive : positive;
            }
            addExactClause(
                literals,
                clause.name,
                clause.level,
                clause.weight
            );
        }

        foreach (constraint; model.internalConstraints) {
            if (
                options.diagnosticOnly &&
                constraint.level != ConstraintLevel.hard
            ) {
                continue;
            }
            currentSemanticOperationId =
                constraint.semanticOperationId;
            const root = encodeBoolean(constraint.expression.node);
            addClause(
                [root],
                constraint.name,
                constraint.level,
                constraint.weight,
                false
            );
        }

        useNativeParity =
            options.preferNativeParity &&
            options.engine == "auto" &&
            options.hardware.length == 0 &&
            model.internalParityConstraints.length != 0 &&
            model.internalObjectives.length == 0 &&
            model.internalNativeClauses.all!(
                clause => clause.level == ConstraintLevel.hard
            ) &&
            model.internalConstraints.all!(
                constraint => constraint.level == ConstraintLevel.hard
            );
        if (
            options.preferNativeParity &&
            !useNativeParity &&
            model.internalParityConstraints.length != 0 &&
            (options.engine != "auto" || options.hardware.length != 0)
        ) {
            result.warnings ~=
                "Native parity was lowered to CNF so the explicit engine/hardware " ~
                "selection could be preserved";
        }
        if (!useNativeParity) {
            encodeParityAsCnf();
        }
        currentSemanticOperationId = "";

        if (!options.diagnosticOnly) {
            prepareObjectiveLevels();
            encodeObjectives();
        }
        if (hasWeightedSemantics()) {
            finalizeWeights();
            consolidateEquivalentSoftClauses();
        } else {
            foreach (ref clause; result.clauses) {
                clause.weight = 1.0;
            }
        }
        buildRequest();
        return result;
    }

    /**
     * Weighted MaxSAT is additive: two identical soft clauses are equivalent to
     * one clause whose weight is their sum. Consolidate only clauses at the same
     * semantic level/priority, and retain all contributing constraint and
     * semantic-operation IDs for lossless explanation.
     */
    private void consolidateEquivalentSoftClauses() {
        EncodedClause[] consolidated;
        size_t[string] indexByKey;

        foreach (clause; result.clauses) {
            if (
                clause.structural ||
                clause.level == ConstraintLevel.hard
            ) {
                consolidated ~= clause;
                continue;
            }

            string key =
                clause.level.to!string ~ "|" ~
                clause.priorityLevel.to!string;
            foreach (literal; clause.literals) {
                key ~= "|" ~ literal.to!string;
            }

            auto existing = key in indexByKey;
            if (existing is null) {
                auto retained = clause;
                if (
                    retained.constraintNames.length == 0 &&
                    retained.constraintName.length != 0
                ) {
                    retained.constraintNames ~= retained.constraintName;
                }
                if (
                    retained.semanticOperationIds.length == 0 &&
                    retained.semanticOperationId.length != 0
                ) {
                    retained.semanticOperationIds ~=
                        retained.semanticOperationId;
                }
                consolidated ~= retained;
                indexByKey[key] = consolidated.length - 1;
                continue;
            }

            auto destination = &consolidated[*existing];
            const combinedWeight = destination.weight + clause.weight;
            if (
                !combinedWeight.isFinite ||
                combinedWeight > options.maximumEncodedWeight
            ) {
                throw new CapabilityException(
                    "Consolidated soft-clause weight exceeds the safe " ~
                    "API encoding range"
                );
            }
            destination.weight = combinedWeight;
            appendUnique(
                destination.constraintNames,
                clause.constraintNames.length == 0
                    ? [clause.constraintName]
                    : clause.constraintNames
            );
            appendUnique(
                destination.semanticOperationIds,
                clause.semanticOperationIds.length == 0
                    ? [clause.semanticOperationId]
                    : clause.semanticOperationIds
            );
        }
        result.clauses = consolidated;
    }

    private void appendUnique(
        ref string[] destination,
        string[] values
    ) {
        foreach (value; values) {
            if (
                value.length != 0 &&
                !destination.canFind(value)
            ) {
                destination ~= value;
            }
        }
    }

    private bool hasWeightedSemantics() {
        if (options.diagnosticOnly) {
            return false;
        }
        return
            model.internalObjectives.length != 0 ||
            model.internalNativeClauses.any!(
                clause => clause.level != ConstraintLevel.hard
            ) ||
            model.internalConstraints.any!(
                constraint => constraint.level != ConstraintLevel.hard
            );
    }

    private void encodeParityAsCnf() {
        foreach (parity; model.internalParityConstraints) {
            currentSemanticOperationId = parity.semanticOperationId;
            int current = atomLiteral(parity.variableIndices[0], 1);
            foreach (logicalIndex; parity.variableIndices[1 .. $]) {
                current = encodeXor(
                    current,
                    atomLiteral(logicalIndex, 1)
                );
            }
            const requiredLiteral = parity.target == 1
                ? current
                : -current;
            addClause(
                [requiredLiteral],
                parity.name,
                ConstraintLevel.hard,
                1.0,
                false
            );
        }
    }

    private void allocateDomainAtoms() {
        foreach (logicalIndex, variable; model.internalVariables) {
            final switch (variable.kind) {
                case VariableKind.boolean:
                    const satVariable = allocateSatVariable();
                    result.atoms[logicalIndex] = [
                        DomainAtom(0, -satVariable),
                        DomainAtom(1, satVariable)
                    ];
                    break;

                case VariableKind.categorical:
                    int[] positiveLiterals;
                    foreach (value; variable.domainValues) {
                        const satVariable = allocateSatVariable();
                        result.atoms[logicalIndex] ~=
                            DomainAtom(value, satVariable);
                        positiveLiterals ~= satVariable;
                    }

                    addClause(
                        positiveLiterals,
                        "$domain:" ~ variable.name,
                        ConstraintLevel.hard,
                        1.0,
                        true
                    );

                    encodeAtMostOne(
                        positiveLiterals,
                        "$domain:" ~ variable.name
                    );
                    break;

                case VariableKind.integer:
                    const thresholdCount = variable.domainSize - 1;
                    foreach (threshold; 0 .. thresholdCount) {
                        result.integerOrderLiterals[logicalIndex] ~=
                            allocateSatVariable();
                    }

                    // Order encoding: bit i means x >= lower + i + 1.
                    // A higher threshold implies every lower threshold.
                    foreach (
                        threshold;
                        1 .. result.integerOrderLiterals[logicalIndex].length
                    ) {
                        addStructural([
                            -result.integerOrderLiterals[logicalIndex][threshold],
                            result.integerOrderLiterals[logicalIndex][threshold - 1]
                        ]);
                    }
                    break;
            }
        }
    }

    private void encodeAtMostOne(int[] literals, string name) {
        if (literals.length <= 1) {
            return;
        }

        if (literals.length <= 8) {
            foreach (left; 0 .. literals.length) {
                foreach (right; left + 1 .. literals.length) {
                    addClause(
                        [-literals[left], -literals[right]],
                        name,
                        ConstraintLevel.hard,
                        1.0,
                        true
                    );
                }
            }
            return;
        }

        // Sinz sequential at-most-one encoding.
        int[] sequential;
        foreach (_; 0 .. literals.length - 1) {
            sequential ~= allocateSatVariable();
        }
        addClause(
            [-literals[0], sequential[0]],
            name,
            ConstraintLevel.hard,
            1.0,
            true
        );
        foreach (index; 1 .. literals.length - 1) {
            addClause(
                [-literals[index], sequential[index]],
                name,
                ConstraintLevel.hard,
                1.0,
                true
            );
            addClause(
                [-sequential[index - 1], sequential[index]],
                name,
                ConstraintLevel.hard,
                1.0,
                true
            );
            addClause(
                [-literals[index], -sequential[index - 1]],
                name,
                ConstraintLevel.hard,
                1.0,
                true
            );
        }
        addClause(
            [-literals[$ - 1], -sequential[$ - 1]],
            name,
            ConstraintLevel.hard,
            1.0,
            true
        );
    }

    private int allocateSatVariable() {
        ++nextSatVariable;
        if (nextSatVariable > options.maxEncodedVariables) {
            throw new CapabilityException(format(
                "Compilation exceeded the encoded-variable limit of %s",
                options.maxEncodedVariables
            ));
        }
        return nextSatVariable;
    }

    private int encodeBoolean(ExpressionNode node) {
        auto memoized = node in booleanMemo;
        if (memoized !is null) {
            return *memoized;
        }

        int literal;
        switch (node.kind) {
            case ExpressionKind.booleanConstant:
                literal = constantLiteral(node.booleanValue);
                break;

            case ExpressionKind.variable:
                literal = atomLiteral(node.variableIndex, 1);
                break;

            case ExpressionKind.logicalNot:
                literal = -encodeBoolean(node.children[0]);
                break;

            case ExpressionKind.logicalAnd:
                literal = encodeAnd(
                    encodeBoolean(node.children[0]),
                    encodeBoolean(node.children[1])
                );
                break;

            case ExpressionKind.logicalOr:
                literal = encodeOr(
                    encodeBoolean(node.children[0]),
                    encodeBoolean(node.children[1])
                );
                break;

            case ExpressionKind.logicalXor:
                literal = encodeXor(
                    encodeBoolean(node.children[0]),
                    encodeBoolean(node.children[1])
                );
                break;

            case ExpressionKind.implies:
                literal = encodeOr(
                    -encodeBoolean(node.children[0]),
                    encodeBoolean(node.children[1])
                );
                break;

            case ExpressionKind.equivalent:
                literal = -encodeXor(
                    encodeBoolean(node.children[0]),
                    encodeBoolean(node.children[1])
                );
                break;

            case ExpressionKind.equal:
                literal = encodeAnd(
                    encodeLinearComparison(
                        node.children[0],
                        node.children[1],
                        ExpressionKind.lessEqual
                    ),
                    encodeLinearComparison(
                        node.children[0],
                        node.children[1],
                        ExpressionKind.greaterEqual
                    )
                );
                break;

            case ExpressionKind.notEqual:
                literal = encodeOr(
                    encodeLinearComparison(
                        node.children[0],
                        node.children[1],
                        ExpressionKind.lessThan
                    ),
                    encodeLinearComparison(
                        node.children[0],
                        node.children[1],
                        ExpressionKind.greaterThan
                    )
                );
                break;

            case ExpressionKind.lessThan:
            case ExpressionKind.lessEqual:
            case ExpressionKind.greaterThan:
            case ExpressionKind.greaterEqual:
                literal = encodeLinearComparison(
                    node.children[0],
                    node.children[1],
                    node.kind
                );
                break;

            case ExpressionKind.allDifferent:
                literal = constantLiteral(true);
                foreach (left; 0 .. node.children.length) {
                    foreach (right; left + 1 .. node.children.length) {
                        const different = encodeOr(
                            encodeLinearComparison(
                                node.children[left],
                                node.children[right],
                                ExpressionKind.lessThan
                            ),
                            encodeLinearComparison(
                                node.children[left],
                                node.children[right],
                                ExpressionKind.greaterThan
                            )
                        );
                        literal = encodeAnd(literal, different);
                    }
                }
                break;

            default:
                throw new CapabilityException(
                    format(
                        "Expression kind %s cannot be used as a Boolean constraint",
                        node.kind
                    )
                );
        }

        booleanMemo[node] = literal;
        return literal;
    }

    private int constantLiteral(bool value) {
        if (trueSatVariable == 0) {
            trueSatVariable = allocateSatVariable();
            addClause(
                [trueSatVariable],
                "$constant",
                ConstraintLevel.hard,
                1.0,
                true
            );
        }
        return value ? trueSatVariable : -trueSatVariable;
    }

    private struct PbTerm {
        int literal;
        long weight;
    }

    private int encodeLinearComparison(
        ExpressionNode leftNode,
        ExpressionNode rightNode,
        ExpressionKind relation
    ) {
        auto left = linearize(leftNode);
        auto right = linearize(rightNode);
        if (!left.valid || !right.valid) {
            throw new CapabilityException(
                "Nonlinear arithmetic requires a future MILP/QP API backend"
            );
        }

        // Normalize every relation to left - right <= bound.
        LinearForm difference = left;
        difference.constant = checkedSubtract(
            difference.constant,
            right.constant,
            "linear comparison constant"
        );
        foreach (logicalIndex, coefficient; right.coefficients) {
            auto existing = logicalIndex in difference.coefficients;
            difference.coefficients[logicalIndex] = checkedSubtract(
                existing is null ? 0 : *existing,
                coefficient,
                "linear comparison coefficient"
            );
        }

        long bound;
        switch (relation) {
            case ExpressionKind.lessEqual:
                bound = 0;
                break;
            case ExpressionKind.lessThan:
                bound = -1;
                break;
            case ExpressionKind.greaterEqual:
                difference = negateLinear(difference);
                bound = 0;
                break;
            case ExpressionKind.greaterThan:
                difference = negateLinear(difference);
                bound = -1;
                break;
            default:
                throw new CapabilityException(
                    "Internal error: unsupported linear relation"
                );
        }

        PbTerm[] terms;
        long constant = difference.constant;
        const variables = model.internalVariables;
        foreach (logicalIndex; 0 .. variables.length) {
            auto coefficientPointer =
                cast(size_t) logicalIndex in difference.coefficients;
            if (coefficientPointer is null || *coefficientPointer == 0) {
                continue;
            }
            const coefficient = *coefficientPointer;
            auto variable = variables[logicalIndex];

            final switch (variable.kind) {
                case VariableKind.boolean:
                    appendSignedTerm(
                        terms,
                        constant,
                        atomLiteral(logicalIndex, 1),
                        coefficient
                    );
                    break;

                case VariableKind.categorical:
                    foreach (atom; result.atoms[logicalIndex]) {
                        appendSignedTerm(
                            terms,
                            constant,
                            atom.literalWhenSelected,
                            checkedMultiply(
                                coefficient,
                                atom.value,
                                "categorical linear term"
                            )
                        );
                    }
                    break;

                case VariableKind.integer:
                    constant = checkedAdd(
                        constant,
                        checkedMultiply(
                            coefficient,
                            variable.lowerBound,
                            "integer lower-bound contribution"
                        ),
                        "linear comparison constant"
                    );
                    foreach (
                        thresholdLiteral;
                        result.integerOrderLiterals[logicalIndex]
                    ) {
                        appendSignedTerm(
                            terms,
                            constant,
                            thresholdLiteral,
                            coefficient
                        );
                    }
                    break;
            }
        }

        return encodePseudoBooleanAtMost(
            terms,
            checkedSubtract(bound, constant, "pseudo-Boolean capacity")
        );
    }

    private LinearForm negateLinear(LinearForm value) {
        value.constant = checkedNegate(
            value.constant,
            "linear comparison constant"
        );
        foreach (logicalIndex, ref coefficient; value.coefficients) {
            coefficient = checkedNegate(
                coefficient,
                "linear comparison coefficient"
            );
        }
        return value;
    }

    private void appendSignedTerm(
        ref PbTerm[] terms,
        ref long constant,
        int literal,
        long coefficient
    ) {
        if (coefficient > 0) {
            terms ~= PbTerm(literal, coefficient);
        } else if (coefficient < 0) {
            // -w*l == w*!l - w
            terms ~= PbTerm(
                -literal,
                checkedNegate(coefficient, "pseudo-Boolean coefficient")
            );
            constant = checkedAdd(
                constant,
                coefficient,
                "pseudo-Boolean normalization"
            );
        }
    }

    private int encodePseudoBooleanAtMost(PbTerm[] terms, long capacity) {
        long totalWeight = 0;
        foreach (term; terms) {
            totalWeight = checkedAdd(
                totalWeight,
                term.weight,
                "pseudo-Boolean total weight"
            );
        }
        if (capacity < 0) {
            return constantLiteral(false);
        }
        if (terms.length == 0 || totalWeight <= capacity) {
            return constantLiteral(true);
        }
        if (terms.length > options.maxPseudoBooleanTerms) {
            throw new CapabilityException(format(
                "A linear constraint contains %s encoded terms, above the " ~
                "configured limit of %s; use coarser fixed-point units, split " ~
                "the constraint, or use a future native MILP backend",
                terms.length,
                options.maxPseudoBooleanTerms
            ));
        }

        terms.sort!((left, right) =>
            left.weight == right.weight
                ? left.literal < right.literal
                : left.weight > right.weight
        );

        long[] suffix = new long[](terms.length + 1);
        suffix[] = 0;
        for (size_t index = terms.length; index > 0; --index) {
            suffix[index - 1] = checkedAdd(
                suffix[index],
                terms[index - 1].weight,
                "pseudo-Boolean suffix weight"
            );
        }

        int[string] memo;
        size_t nodes;

        int build(size_t index, long remainingCapacity) {
            if (remainingCapacity < 0) {
                return constantLiteral(false);
            }
            if (index == terms.length || suffix[index] <= remainingCapacity) {
                return constantLiteral(true);
            }

            const key =
                index.to!string ~ ":" ~ remainingCapacity.to!string;
            auto cached = key in memo;
            if (cached !is null) {
                return *cached;
            }

            ++nodes;
            if (nodes > options.maxBddNodesPerConstraint) {
                throw new CapabilityException(format(
                    "A linear constraint exceeded the pseudo-Boolean BDD limit " ~
                    "of %s nodes; tighten bounds or raise maxBddNodesPerConstraint",
                    options.maxBddNodesPerConstraint
                ));
            }

            const low = build(index + 1, remainingCapacity);
            const high = build(
                index + 1,
                remainingCapacity - terms[index].weight
            );
            if (low == high) {
                memo[key] = low;
                return low;
            }

            const condition = terms[index].literal;
            const output = encodeIte(condition, high, low);
            memo[key] = output;
            return output;
        }

        return build(0, capacity);
    }

    private int encodeIte(int condition, int high, int low) {
        const output = allocateSatVariable();
        addStructural([-condition, -high, output]);
        addStructural([condition, -low, output]);
        addStructural([-condition, high, -output]);
        addStructural([condition, low, -output]);
        return output;
    }

    private int encodeAnd(int left, int right) {
        const output = allocateSatVariable();
        addStructural([-output, left]);
        addStructural([-output, right]);
        addStructural([output, -left, -right]);
        return output;
    }

    private int encodeOr(int left, int right) {
        const output = allocateSatVariable();
        addStructural([output, -left]);
        addStructural([output, -right]);
        addStructural([-output, left, right]);
        return output;
    }

    private int encodeXor(int left, int right) {
        const output = allocateSatVariable();
        addStructural([-output, -left, -right]);
        addStructural([-output, left, right]);
        addStructural([output, -left, right]);
        addStructural([output, left, -right]);
        return output;
    }

    private void addStructural(int[] literals) {
        addClause(
            literals,
            "$encoding",
            ConstraintLevel.hard,
            1.0,
            true
        );
    }

    private int atomLiteral(size_t logicalIndex, long value) {
        foreach (atom; result.atoms[logicalIndex]) {
            if (atom.value == value) {
                return atom.literalWhenSelected;
            }
        }
        throw new ModelException(format(
            "Value %s is outside the domain of '%s'",
            value,
            model.internalVariables[logicalIndex].name
        ));
    }

    private void prepareObjectiveLevels() {
        int[] priorities;
        foreach (objective; model.internalObjectives) {
            if (!priorities.canFind(objective.priority)) {
                priorities ~= objective.priority;
            }
        }
        priorities.sort;

        foreach (rank, priority; priorities) {
            if (rank > cast(size_t) int.max - 3) {
                throw new CapabilityException(
                    "The model declares too many distinct objective priorities"
                );
            }
            objectiveLevelByPriority[priority] = 3 + cast(int) rank;
        }
    }

    private int objectiveLevel(int priority) {
        auto found = priority in objectiveLevelByPriority;
        if (found is null) {
            throw new ModelException(
                "Internal error: objective priority was not normalized"
            );
        }
        return *found;
    }

    private void encodeObjectives() {
        const variables = model.internalVariables;
        foreach (objective; model.internalObjectives) {
            currentSemanticOperationId =
                objective.semanticOperationId;
            auto linear = linearize(objective.expression.node);
            if (!linear.valid) {
                throw new CapabilityException(format(
                    "Objective '%s' is nonlinear. The current API contract only " ~
                    "permits exact finite linear objectives; a QP/MILP API backend " ~
                    "is required for this objective.",
                    objective.name
                ));
            }
            validateObjectiveRange(linear, objective.name);

            foreach (logicalIndex; 0 .. variables.length) {
                auto coefficientPointer =
                    cast(size_t) logicalIndex in linear.coefficients;
                if (coefficientPointer is null) {
                    continue;
                }
                const coefficient = *coefficientPointer;
                if (coefficient == 0) {
                    continue;
                }

                long signedCoefficient = objective.sense ==
                    ObjectiveSense.maximize
                        ? coefficient
                        : checkedNegate(
                            coefficient,
                            "minimization coefficient"
                        );

                if (
                    variables[logicalIndex].kind ==
                    VariableKind.integer
                ) {
                    const magnitude = signedCoefficient > 0
                        ? signedCoefficient
                        : checkedNegate(
                            signedCoefficient,
                            "objective coefficient"
                        );
                    const baseWeight = exactObjectiveWeight(
                        magnitude,
                        objective.name
                    );
                    foreach (
                        thresholdLiteral;
                        result.integerOrderLiterals[logicalIndex]
                    ) {
                        addClause(
                            [
                                signedCoefficient > 0
                                    ? thresholdLiteral
                                    : -thresholdLiteral
                            ],
                            "$objective:" ~ objective.name,
                            ConstraintLevel.soft,
                            baseWeight,
                            false,
                            objectiveLevel(objective.priority)
                        );
                    }
                    continue;
                }

                long minimumReward = long.max;
                long[] rewards;
                foreach (atom; result.atoms[logicalIndex]) {
                    const reward = checkedMultiply(
                        signedCoefficient,
                        atom.value,
                        "objective reward"
                    );
                    rewards ~= reward;
                    if (reward < minimumReward) {
                        minimumReward = reward;
                    }
                }

                foreach (atomIndex, atom; result.atoms[logicalIndex]) {
                    const normalizedReward = checkedSubtract(
                        rewards[atomIndex],
                        minimumReward,
                        "normalized objective reward"
                    );
                    if (normalizedReward == 0) {
                        continue;
                    }
                    addClause(
                        [atom.literalWhenSelected],
                        "$objective:" ~ objective.name,
                        ConstraintLevel.soft,
                        exactObjectiveWeight(
                            normalizedReward,
                            objective.name
                        ),
                        false,
                        objectiveLevel(objective.priority)
                    );
                }
            }
        }
    }

    private struct LinearForm {
        bool valid = true;
        long constant;
        long[size_t] coefficients;
    }

    private double exactObjectiveWeight(long value, string objectiveName) {
        if (
            value <= 0 ||
            cast(ulong) value > maximumExactDoubleInteger
        ) {
            throw new CapabilityException(format(
                "Objective '%s' produces a clause weight outside the exact " ~
                "IEEE-754 integer range; rescale its coefficients",
                objectiveName
            ));
        }
        return cast(double) value;
    }

    private void validateObjectiveRange(
        ref LinearForm linear,
        string objectiveName
    ) {
        BigInt minimum = BigInt(linear.constant);
        BigInt maximum = BigInt(linear.constant);
        const variables = model.internalVariables;

        foreach (logicalIndex, coefficient; linear.coefficients) {
            if (coefficient == 0) {
                continue;
            }

            long lower;
            long upper;
            final switch (variables[logicalIndex].kind) {
                case VariableKind.boolean:
                    lower = 0;
                    upper = 1;
                    break;
                case VariableKind.categorical:
                    lower = 0;
                    upper = cast(long) variables[logicalIndex].states.length - 1;
                    break;
                case VariableKind.integer:
                    lower = variables[logicalIndex].lowerBound;
                    upper = variables[logicalIndex].upperBound;
                    break;
            }

            const first = BigInt(coefficient) * lower;
            const second = BigInt(coefficient) * upper;
            if (first <= second) {
                minimum += first;
                maximum += second;
            } else {
                minimum += second;
                maximum += first;
            }
        }

        if (minimum < long.min || maximum > long.max) {
            throw new CapabilityException(format(
                "Objective '%s' has a value range [%s, %s] that would overflow " ~
                "the supported signed 64-bit result range; rescale its coefficients",
                objectiveName,
                minimum.to!string,
                maximum.to!string
            ));
        }
    }

    private LinearForm linearize(ExpressionNode node) {
        LinearForm result;

        switch (node.kind) {
            case ExpressionKind.integerConstant:
                result.constant = node.integerValue;
                return result;

            case ExpressionKind.variable:
                result.coefficients[node.variableIndex] = 1;
                return result;

            case ExpressionKind.booleanAsInteger:
                if (
                    node.children[0].kind != ExpressionKind.variable ||
                    model.internalVariables[node.children[0].variableIndex].kind !=
                        VariableKind.boolean
                ) {
                    result.valid = false;
                    return result;
                }
                result.coefficients[node.children[0].variableIndex] = 1;
                return result;

            case ExpressionKind.negate:
                result = linearize(node.children[0]);
                result.constant = checkedNegate(
                    result.constant,
                    "negated linear constant"
                );
                foreach (index, ref coefficient; result.coefficients) {
                    coefficient = checkedNegate(
                        coefficient,
                        "negated linear coefficient"
                    );
                }
                return result;

            case ExpressionKind.add:
            case ExpressionKind.subtract:
                auto left = linearize(node.children[0]);
                auto right = linearize(node.children[1]);
                if (!left.valid || !right.valid) {
                    result.valid = false;
                    return result;
                }
                const sign = node.kind == ExpressionKind.add ? 1L : -1L;
                result = left;
                result.constant = checkedAdd(
                    result.constant,
                    checkedMultiply(
                        sign,
                        right.constant,
                        "linear constant sign"
                    ),
                    "linear constant addition"
                );
                foreach (index, coefficient; right.coefficients) {
                    auto existing = index in result.coefficients;
                    result.coefficients[index] = checkedAdd(
                        existing is null ? 0 : *existing,
                        checkedMultiply(
                            sign,
                            coefficient,
                            "linear coefficient sign"
                        ),
                        "linear coefficient addition"
                    );
                }
                return result;

            case ExpressionKind.multiply:
                auto left = linearize(node.children[0]);
                auto right = linearize(node.children[1]);
                if (!left.valid || !right.valid) {
                    result.valid = false;
                    return result;
                }

                const leftHasVariables = left.coefficients.length != 0;
                const rightHasVariables = right.coefficients.length != 0;
                if (leftHasVariables && rightHasVariables) {
                    result.valid = false;
                    return result;
                }

                if (!leftHasVariables) {
                    result = right;
                    result.constant = checkedMultiply(
                        result.constant,
                        left.constant,
                        "linear constant multiplication"
                    );
                    foreach (index, ref coefficient; result.coefficients) {
                        coefficient = checkedMultiply(
                            coefficient,
                            left.constant,
                            "linear coefficient multiplication"
                        );
                    }
                } else {
                    result = left;
                    result.constant = checkedMultiply(
                        result.constant,
                        right.constant,
                        "linear constant multiplication"
                    );
                    foreach (index, ref coefficient; result.coefficients) {
                        coefficient = checkedMultiply(
                            coefficient,
                            right.constant,
                            "linear coefficient multiplication"
                        );
                    }
                }
                return result;

            default:
                result.valid = false;
                return result;
        }
    }

    private void addClause(
        int[] literals,
        string name,
        ConstraintLevel level,
        double baseWeight,
        bool structural,
        int explicitLevel = -1
    ) {
        int[] normalized;
        foreach (literal; literals) {
            if (literal == 0) {
                throw new ModelException("CNF literals cannot be zero");
            }
            if (normalized.canFind(-literal)) {
                // The clause is a tautology and can be omitted.
                return;
            }
            if (!normalized.canFind(literal)) {
                normalized ~= literal;
            }
        }
        normalized.sort;

        auto encoded = EncodedClause(
            normalized,
            name,
            level,
            baseWeight,
            structural,
            explicitLevel,
            currentSemanticOperationId,
            name.length == 0 ? null : [name],
            currentSemanticOperationId.length == 0
                ? null
                : [currentSemanticOperationId]
        );
        if (result.clauses.length >= options.maxEncodedClauses) {
            throw new CapabilityException(format(
                "Compilation exceeded the encoded-clause limit of %s",
                options.maxEncodedClauses
            ));
        }
        result.clauses ~= encoded;
    }

    /**
     * Append a source CNF clause without canonicalization.
     *
     * DIMACS/formula-generator compatibility requires preservation of literal
     * order, repetitions, opposite pairs, duplicate clauses, and empty clauses.
     */
    private void addExactClause(
        int[] literals,
        string name,
        ConstraintLevel level,
        double baseWeight
    ) {
        foreach (literal; literals) {
            if (literal == 0) {
                throw new ModelException("CNF literals cannot be zero");
            }
        }
        if (result.clauses.length >= options.maxEncodedClauses) {
            throw new CapabilityException(format(
                "Compilation exceeded the encoded-clause limit of %s",
                options.maxEncodedClauses
            ));
        }
        result.clauses ~= EncodedClause(
            literals.dup,
            name,
            level,
            baseWeight,
            false,
            -1,
            currentSemanticOperationId,
            name.length == 0 ? null : [name],
            currentSemanticOperationId.length == 0
                ? null
                : [currentSemanticOperationId]
        );
    }

    private int clauseLevel(ref EncodedClause clause, out double baseWeight) {
        if (clause.priorityLevel >= 0) {
            baseWeight = clause.weight;
            return clause.priorityLevel;
        }
        baseWeight = clause.weight;
        final switch (clause.level) {
            case ConstraintLevel.hard:
                return 0;
            case ConstraintLevel.medium:
                return 1;
            case ConstraintLevel.soft:
                return 2;
        }
    }

    private struct BinaryWeight {
        ulong significand;
        int exponent;
    }

    private union DoubleRepresentation {
        double value;
        ulong bits;
    }

    private BinaryWeight decomposeWeight(double value) {
        DoubleRepresentation representation;
        representation.value = value;

        const exponentBits = cast(uint) (
            (representation.bits >> 52) & 0x7ffUL
        );
        const fractionBits =
            representation.bits & ((1UL << 52) - 1);

        BinaryWeight result;
        if (exponentBits == 0) {
            result.significand = fractionBits;
            result.exponent = -1074;
        } else {
            result.significand = (1UL << 52) | fractionBits;
            result.exponent = cast(int) exponentBits - 1023 - 52;
        }

        while ((result.significand & 1UL) == 0) {
            result.significand >>= 1;
            ++result.exponent;
        }
        return result;
    }

    private BigInt greatestCommonDivisor(BigInt left, BigInt right) {
        while (right != 0) {
            auto remainder = left % right;
            left = right;
            right = remainder;
        }
        return left;
    }

    /**
     * Convert the positive IEEE-754 weights at one priority level into their
     * smallest exact integer ratio. Levels are normalized independently because
     * only ratios within a level are meaningful before lexicographic scaling.
     */
    private void normalizeLevelWeights(int targetLevel) {
        size_t[] clauseIndices;
        BinaryWeight[] decomposed;
        int minimumExponent = int.max;

        foreach (clauseIndex; 0 .. result.clauses.length) {
            if (result.clauses[clauseIndex].structural) {
                continue;
            }
            double baseWeight;
            if (
                clauseLevel(
                    result.clauses[clauseIndex],
                    baseWeight
                ) != targetLevel
            ) {
                continue;
            }
            if (!baseWeight.isFinite || baseWeight <= 0.0) {
                throw new CapabilityException(format(
                    "Clause '%s' produced an invalid base weight %s",
                    result.clauses[clauseIndex].constraintName,
                    baseWeight
                ));
            }

            const parts = decomposeWeight(baseWeight);
            clauseIndices ~= clauseIndex;
            decomposed ~= parts;
            if (parts.exponent < minimumExponent) {
                minimumExponent = parts.exponent;
            }
        }

        if (clauseIndices.length == 0) {
            return;
        }

        BigInt[] units;
        BigInt divisor;
        foreach (parts; decomposed) {
            BigInt unit = BigInt(parts.significand);
            unit <<= cast(size_t) (parts.exponent - minimumExponent);
            units ~= unit;
            divisor = divisor == 0
                ? unit
                : greatestCommonDivisor(divisor, unit);
        }

        const maximumUnit = cast(ulong) options.maximumEncodedWeight;
        foreach (index, unitValue; units) {
            auto normalized = unitValue / divisor;
            if (normalized > maximumUnit) {
                throw new CapabilityException(format(
                    "Priority level %s contains fractional weights whose exact " ~
                    "integer ratio exceeds the safe API range; rescale them to " ~
                    "smaller integer units",
                    targetLevel
                ));
            }
            result.clauses[clauseIndices[index]].weight =
                cast(double) normalized.toLong();
        }
    }

    private void finalizeWeights() {
        int maximumLevel = 2;
        foreach (ref clause; result.clauses) {
            double ignored;
            const level = clauseLevel(clause, ignored);
            if (level > maximumLevel) {
                maximumLevel = level;
            }
        }

        foreach (level; 0 .. maximumLevel + 1) {
            normalizeLevelWeights(level);
        }

        double[] totals = new double[](maximumLevel + 1);
        totals[] = 0.0;
        foreach (ref clause; result.clauses) {
            if (clause.structural) {
                continue;
            }
            double baseWeight;
            const level = clauseLevel(clause, baseWeight);
            if (!baseWeight.isFinite || baseWeight <= 0.0) {
                throw new CapabilityException(format(
                    "Clause '%s' produced a non-finite base weight %s",
                    clause.constraintName,
                    baseWeight
                ));
            }
            totals[level] += baseWeight;
        }

        double[] scales = new double[](maximumLevel + 1);
        scales[] = 0.0;
        double lowerMaximum = 0.0;
        for (int level = maximumLevel; level >= 0; --level) {
            scales[level] = lowerMaximum + 1.0;
            lowerMaximum += totals[level] * scales[level];
            if (
                !lowerMaximum.isFinite ||
                lowerMaximum > options.maximumEncodedWeight
            ) {
                throw new CapabilityException(
                    format(
                        "Lexicographic weights exceed the safe API encoding range " ~
                        "at priority level %s (computed bound %.3g, limit %.3g); " ~
                        "reduce weights/domain sizes or use native hierarchical objectives",
                        level,
                        lowerMaximum,
                        options.maximumEncodedWeight
                    )
                );
            }
        }

        const structuralWeight = lowerMaximum + 1.0;
        const hasStructural = result.clauses.any!(
            clause => clause.structural
        );
        if (
            hasStructural &&
            (
                !structuralWeight.isFinite ||
                structuralWeight > options.maximumEncodedWeight
            )
        ) {
            throw new CapabilityException(
                "Structural CNF weights exceed the safe API encoding range; " ~
                "reduce model weights/domain sizes"
            );
        }
        foreach (ref clause; result.clauses) {
            if (clause.structural) {
                clause.weight = structuralWeight;
                continue;
            }
            double baseWeight;
            const level = clauseLevel(clause, baseWeight);
            clause.weight = baseWeight * scales[level];
        }
    }

    private void buildRequest() {
        JSONValue[] clauses;
        JSONValue[] weights;
        JSONValue[] hardClauseMask;
        foreach (clause; result.clauses) {
            JSONValue[] literals;
            foreach (literal; clause.literals) {
                literals ~= JSONValue(cast(long) literal);
            }
            clauses ~= JSONValue(literals);
            weights ~= JSONValue(clause.weight);
            hardClauseMask ~= JSONValue(clause.level == ConstraintLevel.hard);
        }

        JSONValue[string] request;
        request["num_vars"] = JSONValue(cast(long) nextSatVariable);
        request["clauses"] = JSONValue(clauses);
        if (hasWeightedSemantics()) {
            request["weights"] = JSONValue(weights);
            // Preserve hard/soft semantics explicitly. Numeric dominance is
            // retained for older endpoints, while this mask lets engines
            // enforce hard clauses instead of treating every weighted clause
            // as negotiable.
            request["hard_clause_mask"] = JSONValue(hardClauseMask);
        }
        if (options.timeoutBudgetSeconds > 0.0) {
            request["timeout_budget_seconds"] =
                JSONValue(options.timeoutBudgetSeconds);
        }
        if (options.minSatisfaction >= 0.0) {
            request["min_satisfaction"] =
                JSONValue(options.minSatisfaction);
        }
        if (options.minWeightedSatisfaction >= 0.0) {
            if (!hasWeightedSemantics()) {
                throw new CapabilityException(
                    "minWeightedSatisfaction requires a weighted CNF model"
                );
            }
            request["min_weighted_satisfaction"] =
                JSONValue(options.minWeightedSatisfaction);
        }
        if (options.hardware.length != 0) {
            request["hardware"] = JSONValue(options.hardware);
        }

        if (useNativeParity) {
            JSONValue[] parityValues;
            foreach (parity; model.internalParityConstraints) {
                JSONValue[string] parityValue;
                JSONValue[] variables;
                foreach (logicalIndex; parity.variableIndices) {
                    variables ~= JSONValue(cast(long) atomLiteral(
                        logicalIndex,
                        1
                    ));
                }
                parityValue["vars"] = JSONValue(variables);
                parityValue["target"] = JSONValue(cast(long) parity.target);
                parityValues ~= JSONValue(parityValue);
            }
            request["xor_constraints"] = JSONValue(parityValues);
            request["strategy"] = JSONValue("auto");
            result.backend = Backend.hybrid;
        } else {
            request["engine"] = JSONValue(options.engine);
            result.backend = Backend.cnf;
        }

        result.generatedVariableCount = nextSatVariable;
        result.request = JSONValue(request);
    }
}

private CompiledModel compileCnf(Model model, CompileOptions options) {
    return new CnfCompiler(model, options).run();
}

private long checkedAdd(long left, long right, string context) {
    if (
        (right > 0 && left > long.max - right) ||
        (right < 0 && left < long.min - right)
    ) {
        throw new CapabilityException(
            "Integer overflow while compiling " ~ context
        );
    }
    return left + right;
}

private long checkedNegate(long value, string context) {
    if (value == long.min) {
        throw new CapabilityException(
            "Integer overflow while compiling " ~ context
        );
    }
    return -value;
}

private long checkedSubtract(long left, long right, string context) {
    if (
        (right > 0 && left < long.min + right) ||
        (right < 0 && left > long.max + right)
    ) {
        throw new CapabilityException(
            "Integer overflow while compiling " ~ context
        );
    }
    return left - right;
}

private long checkedMultiply(long left, long right, string context) {
    if (left == 0 || right == 0) {
        return 0;
    }
    if (
        (left == -1 && right == long.min) ||
        (right == -1 && left == long.min)
    ) {
        throw new CapabilityException(
            "Integer overflow while compiling " ~ context
        );
    }

    const result = left * right;
    if (result / right != left) {
        throw new CapabilityException(
            "Integer overflow while compiling " ~ context
        );
    }
    return result;
}