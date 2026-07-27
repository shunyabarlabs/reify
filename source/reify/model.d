// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.model;

import reify.errors : ModelException;

import std.algorithm : canFind;
import std.array : array;
import std.conv : to;
import std.format : format;
import std.math : isFinite;
import std.range : iota;

enum VariableKind {
    boolean,
    categorical,
    integer
}

enum ExpressionKind {
    booleanConstant,
    integerConstant,
    variable,
    logicalNot,
    logicalAnd,
    logicalOr,
    logicalXor,
    implies,
    equivalent,
    equal,
    notEqual,
    lessThan,
    lessEqual,
    greaterThan,
    greaterEqual,
    add,
    subtract,
    multiply,
    negate,
    booleanAsInteger,
    allDifferent
}

enum ConstraintLevel {
    hard,
    medium,
    soft
}

enum ObjectiveSense {
    maximize,
    minimize
}

/**
 * A node in the solver-independent symbolic expression tree.
 *
 * Nodes are deliberately immutable by convention. The public expression wrappers
 * never expose a mutating operation, which makes expressions safe to reuse.
 */
final class ExpressionNode {
    ExpressionKind kind;
    long integerValue;
    bool booleanValue;
    size_t variableIndex;
    ExpressionNode[] children;
    Model owner;

    this(ExpressionKind kind) {
        this.kind = kind;
    }
}

struct ExpressionNodePool {
    ExpressionNode[] currentChunk;
    size_t index = 0;
    ExpressionNode[][] allChunks;

    ExpressionNode alloc(ExpressionKind kind) {
        if (currentChunk.length == 0 || index >= currentChunk.length) {
            size_t newSize = 16384;
            auto newChunk = new ExpressionNode[newSize];
            foreach(i; 0 .. newSize) newChunk[i] = new ExpressionNode(ExpressionKind.variable);
            allChunks ~= newChunk;
            currentChunk = newChunk;
            index = 0;
        }
        ExpressionNode node = currentChunk[index++];
        node.kind = kind;
        node.integerValue = 0;
        node.booleanValue = false;
        node.variableIndex = 0;
        node.children = null;
        node.owner = null;
        return node;
    }
}

private ExpressionNode unaryNode(Model owner, ExpressionKind kind, ExpressionNode child) {
    auto node = owner.allocNode(kind);
    node.children = [child];
    node.owner = owner;
    return node;
}

private ExpressionNode binaryNode(
    Model owner,
    ExpressionKind kind,
    ExpressionNode left,
    ExpressionNode right
) {
    if (
        left.owner !is null &&
        right.owner !is null &&
        left.owner !is right.owner
    ) {
        throw new ModelException(
            "Cannot combine symbolic expressions from different models"
        );
    }

    // Constant-fold when both children are unattached integer constants and the
    // operation is a comparison. Without this, e.g. `equal(integer(0), integer(0))`
    // would null-dereference inside allocNode because no model owns the result.
    if (owner is null &&
        left.kind == ExpressionKind.integerConstant &&
        right.kind == ExpressionKind.integerConstant) {
        const l = left.integerValue;
        const r = right.integerValue;
        bool folded;
        switch (kind) {
            case ExpressionKind.equal:         folded = (l == r); break;
            case ExpressionKind.notEqual:      folded = (l != r); break;
            case ExpressionKind.lessThan:      folded = (l <  r); break;
            case ExpressionKind.lessEqual:     folded = (l <= r); break;
            case ExpressionKind.greaterThan:   folded = (l >  r); break;
            case ExpressionKind.greaterEqual:  folded = (l >= r); break;
            default:
                throw new ModelException(
                    "Cannot fold unattached expression with non-comparison operator"
                );
        }
        auto foldedNode = new ExpressionNode(ExpressionKind.booleanConstant);
        foldedNode.booleanValue = folded;
        return foldedNode;
    }

    if (owner is null) {
        owner = left.owner !is null ? left.owner : right.owner;
    }
    if (owner is null) {
        throw new ModelException(
            "Cannot combine unattached expressions"
        );
    }
    auto node = owner.allocNode(kind);
    node.children = [left, right];
    node.owner = owner;
    return node;
}

struct BoolExpr {
    package ExpressionNode _node;
    package bool _negated = false;

    package this(ExpressionNode node, bool negated = false) {
        this._node = node;
        this._negated = negated;
    }

    package ExpressionNode node() {
        if (_negated) {
            return unaryNode(_node.owner, ExpressionKind.logicalNot, _node);
        }
        return _node;
    }

    BoolExpr opUnary(string operator)()
        if (operator == "~")
    {
        return BoolExpr(_node, !_negated);
    }

    BoolExpr opBinary(string operator)(BoolExpr right)
        if (operator == "&" || operator == "|" || operator == "^")
    {
        auto leftN = this.node();
        auto rightN = right.node();
        auto owner = leftN.owner is null ? rightN.owner : leftN.owner;
        
        static if (operator == "&") {
            return BoolExpr(binaryNode(owner, ExpressionKind.logicalAnd, leftN, rightN));
        } else static if (operator == "|") {
            return BoolExpr(binaryNode(owner, ExpressionKind.logicalOr, leftN, rightN));
        } else {
            return BoolExpr(binaryNode(owner, ExpressionKind.logicalXor, leftN, rightN));
        }
    }
}

struct IntExpr {
    package ExpressionNode node;

    package this(ExpressionNode node) {
        this.node = node;
    }

    IntExpr opUnary(string operator)() if (operator == "-") {
        return IntExpr(unaryNode(node.owner, ExpressionKind.negate, node));
    }

    IntExpr opBinary(string operator)(IntExpr right)
        if (operator == "+" || operator == "-")
    {
        auto owner = node.owner is null ? right.node.owner : node.owner;
        static if (operator == "+") {
            return IntExpr(binaryNode(owner, ExpressionKind.add, node, right.node));
        } else {
            return IntExpr(binaryNode(owner, ExpressionKind.subtract, node, right.node));
        }
    }

    IntExpr opBinary(string operator)(long right)
        if (operator == "+" || operator == "-" || operator == "*")
    {
        static if (operator == "+") {
            return this + integer(right);
        } else static if (operator == "-") {
            return this - integer(right);
        } else {
            return IntExpr(binaryNode(
                node.owner,
                ExpressionKind.multiply,
                node,
                integer(right).node
            ));
        }
    }

    IntExpr opBinaryRight(string operator)(long left)
        if (operator == "+" || operator == "-" || operator == "*")
    {
        static if (operator == "+") {
            return integer(left) + this;
        } else static if (operator == "-") {
            return integer(left) - this;
        } else {
            return this * left;
        }
    }
}

struct CategoryExpr {
    package IntExpr expression;
    package string[] states;
    package string variableName;

    BoolExpr equals(string state) {
        return equal(expression, integer(stateIndex(state)));
    }

    BoolExpr differs(string state) {
        return notEqual(expression, integer(stateIndex(state)));
    }

    BoolExpr same(CategoryExpr other) {
        ensureCompatible(other);
        return equal(expression, other.expression);
    }

    BoolExpr different(CategoryExpr other) {
        ensureCompatible(other);
        return notEqual(expression, other.expression);
    }

    IntExpr asInteger() {
        return expression;
    }

    private long stateIndex(string state) {
        foreach (index, candidate; states) {
            if (candidate == state) {
                return cast(long) index;
            }
        }

        throw new ModelException(format(
            "Unknown state '%s' for categorical variable '%s'",
            state,
            variableName
        ));
    }

    private void ensureCompatible(CategoryExpr other) {
        if (states != other.states) {
            throw new ModelException(format(
                "Categorical variables '%s' and '%s' use different ordered domains",
                variableName,
                other.variableName
            ));
        }
    }
}

struct BoolVarSet {
    private BoolExpr[string] values;
    string[] keys;

    BoolExpr opIndex(string key) {
        auto found = key in values;
        if (found is null) {
            throw new ModelException("Unknown Boolean index '" ~ key ~ "'");
        }
        return *found;
    }
}

struct IntVarSet {
    private IntExpr[string] values;
    string[] keys;

    IntExpr opIndex(string key) {
        auto found = key in values;
        if (found is null) {
            throw new ModelException("Unknown integer index '" ~ key ~ "'");
        }
        return *found;
    }
}

struct CategoryVarSet {
    private CategoryExpr[string] values;
    string[] keys;

    CategoryExpr opIndex(string key) {
        auto found = key in values;
        if (found is null) {
            throw new ModelException("Unknown categorical index '" ~ key ~ "'");
        }
        return *found;
    }
}

struct DomainVariable {
    string name;
    VariableKind kind;
    long lowerBound;
    long upperBound;
    string[] states;

    size_t domainSize() const {
        final switch (kind) {
            case VariableKind.boolean:
                return 2;
            case VariableKind.categorical:
                return states.length;
            case VariableKind.integer:
                const distance =
                    cast(ulong) upperBound - cast(ulong) lowerBound;
                if (distance >= size_t.max) {
                    throw new ModelException(
                        "Integer domain is too large to represent"
                    );
                }
                return cast(size_t) distance + 1;
        }
    }

    long[] domainValues() const {
        final switch (kind) {
            case VariableKind.boolean:
                return [0L, 1L];
            case VariableKind.categorical:
                return iota(0L, cast(long) states.length).array;
            case VariableKind.integer:
                long[] values;
                long value = lowerBound;
                while (true) {
                    values ~= value;
                    if (value == upperBound) {
                        break;
                    }
                    ++value;
                }
                return values;
        }
    }
}

/**
 * Domain-level provenance for one modeling operation.
 *
 * Constraint frontends such as SpaceTime register semantic operations before
 * emitting ordinary Model constraints. Generated constraints and clauses retain
 * the active operation ID, allowing verification to reconstruct explanations at
 * the vocabulary level in which the policy was authored.
 */
struct SemanticOperation {
    string id;
    string parentId;
    string semanticDomain;
    string kind;
    string label;
    string[] dimensions;
    string[string] attributes;
    string sourceFile;
    size_t sourceLine;
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
    int target;
    string semanticOperationId;
}

/**
 * A signed Boolean literal retained as an exact source-level clause literal.
 *
 * Native clauses are the low-level compatibility boundary for DIMACS and
 * formula generators. Unlike symbolic expressions, their literal order,
 * repetitions, and opposite literal pairs are intentionally significant.
 */
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

/**
 * A solver-independent, domain-neutral finite decision model.
 *
 * The model supports Boolean, categorical, and bounded integer variables.
 * Arithmetic is represented symbolically and is lowered exactly when its finite
 * state space fits the configured compilation limits.
 */
final class Model {
    private DomainVariable[] _variables;
    private NamedConstraint[] _constraints;
    private NamedObjective[] _objectives;
    private ParityConstraint[] _parityConstraints;
    private NamedModelClause[] _nativeClauses;
    private SemanticOperation[] _semanticOperations;
    private string[] semanticOperationStack;
    private size_t nextSemanticOperationId;
    private size_t[string] variableLookup;
    private string _name;
    private bool _frozen;
    
    private ExpressionNodePool nodePool;

    package ExpressionNode allocNode(ExpressionKind kind) {
        return nodePool.alloc(kind);
    }

    this(string name = "decision-model") {
        this._name = name;
    }

    @property string name() const {
        return _name;
    }

    @property void name(string value) {
        ensureMutable();
        _name = value;
    }

    bool frozen() const {
        return _frozen;
    }

    DomainVariable[] variables() {
        auto result = _variables.dup;
        foreach (ref variable; result) {
            variable.states = variable.states.dup;
        }
        return result;
    }

    NamedConstraint[] constraints() {
        return _constraints.dup;
    }

    NamedObjective[] objectives() {
        return _objectives.dup;
    }

    ParityConstraint[] parityConstraints() {
        auto result = _parityConstraints.dup;
        foreach (ref constraint; result) {
            constraint.variableIndices =
                constraint.variableIndices.dup;
        }
        return result;
    }

    NamedModelClause[] nativeClauses() {
        auto result = _nativeClauses.dup;
        foreach (ref clause; result) {
            clause.literals = clause.literals.dup;
        }
        return result;
    }

    SemanticOperation[] semanticOperations() {
        auto result = _semanticOperations.dup;
        foreach (ref operation; result) {
            operation.dimensions = operation.dimensions.dup;
            operation.attributes = operation.attributes.dup;
        }
        return result;
    }

    /**
     * Register one domain-level operation. If another semantic operation is
     * active, it becomes the parent; recipes can therefore retain their child
     * operations without flattening provenance.
     */
    string registerSemanticOperation(
        string semanticDomain,
        string kind,
        string label,
        string[] dimensions = null,
        string[string] attributes = null,
        string sourceFile = __FILE__,
        size_t sourceLine = __LINE__
    ) {
        ensureMutable();
        if (
            semanticDomain.length == 0 ||
            kind.length == 0 ||
            label.length == 0
        ) {
            throw new ModelException(
                "Semantic operations need a domain, kind, and label"
            );
        }
        ++nextSemanticOperationId;
        const id = semanticDomain ~ ":" ~ nextSemanticOperationId.to!string;
        const parentId =
            semanticOperationStack.length == 0
                ? ""
                : semanticOperationStack[$ - 1];
        _semanticOperations ~= SemanticOperation(
            id,
            parentId,
            semanticDomain,
            kind,
            label,
            dimensions.dup,
            attributes.dup,
            sourceFile,
            sourceLine
        );
        return id;
    }

    void enterSemanticOperation(string operationId) {
        ensureMutable();
        bool found;
        foreach (operation; _semanticOperations) {
            if (operation.id == operationId) {
                found = true;
                break;
            }
        }
        if (!found) {
            throw new ModelException(
                "Unknown semantic operation '" ~ operationId ~ "'"
            );
        }
        semanticOperationStack ~= operationId;
    }

    void leaveSemanticOperation() {
        if (semanticOperationStack.length == 0) {
            throw new ModelException(
                "No semantic operation is active"
            );
        }
        semanticOperationStack.length = semanticOperationStack.length - 1;
    }

    string activeSemanticOperationId() const {
        return semanticOperationStack.length == 0
            ? ""
            : semanticOperationStack[$ - 1];
    }

    bool findSemanticOperation(
        string operationId,
        out SemanticOperation operation
    ) {
        foreach (candidate; _semanticOperations) {
            if (candidate.id == operationId) {
                operation = candidate;
                operation.dimensions = candidate.dimensions.dup;
                operation.attributes = candidate.attributes.dup;
                return true;
            }
        }
        return false;
    }

    package DomainVariable[] internalVariables() {
        return _variables;
    }

    package NamedConstraint[] internalConstraints() {
        return _constraints;
    }

    package NamedObjective[] internalObjectives() {
        return _objectives;
    }

    package ParityConstraint[] internalParityConstraints() {
        return _parityConstraints;
    }

    package NamedModelClause[] internalNativeClauses() {
        return _nativeClauses;
    }

    package void freeze() {
        _frozen = true;
    }

    BoolExpr booleanVar(string name) {
        ensureUniqueName(name);

        const index = _variables.length;
        _variables ~= DomainVariable(
            name,
            VariableKind.boolean,
            0,
            1,
            null
        );
        variableLookup[name] = index;
        return BoolExpr(variableNode(this, index));
    }

    IntExpr integerVar(string name, long lowerBound, long upperBound) {
        ensureUniqueName(name);
        if (lowerBound > upperBound) {
            throw new ModelException(format(
                "Integer variable '%s' has lower bound %s above upper bound %s",
                name,
                lowerBound,
                upperBound
            ));
        }

        const index = _variables.length;
        _variables ~= DomainVariable(
            name,
            VariableKind.integer,
            lowerBound,
            upperBound,
            null
        );
        variableLookup[name] = index;
        return IntExpr(variableNode(this, index));
    }

    CategoryExpr categoricalVar(string name, const(string)[] states) {
        ensureUniqueName(name);
        if (states.length < 2) {
            throw new ModelException(format(
                "Categorical variable '%s' needs at least two states",
                name
            ));
        }

        string[] seen;
        foreach (state; states) {
            if (state.length == 0) {
                throw new ModelException(format(
                    "Categorical variable '%s' contains an empty state",
                    name
                ));
            }
            if (seen.canFind(state)) {
                throw new ModelException(format(
                    "Categorical variable '%s' contains duplicate state '%s'",
                    name,
                    state
                ));
            }
            seen ~= state;
        }

        const index = _variables.length;
        _variables ~= DomainVariable(
            name,
            VariableKind.categorical,
            0,
            cast(long) states.length - 1,
            states.dup
        );
        variableLookup[name] = index;

        return CategoryExpr(
            IntExpr(variableNode(this, index)),
            states.dup,
            name
        );
    }

    BoolVarSet booleanVars(string family, const(string)[] keys) {
        BoolVarSet result;
        foreach (key; uniqueKeys(family, keys)) {
            result.keys ~= key;
            result.values[key] = booleanVar(indexedName(family, key));
        }
        return result;
    }

    IntVarSet integerVars(
        string family,
        long lowerBound,
        long upperBound,
        const(string)[] keys
    ) {
        IntVarSet result;
        foreach (key; uniqueKeys(family, keys)) {
            result.keys ~= key;
            result.values[key] = integerVar(
                indexedName(family, key),
                lowerBound,
                upperBound
            );
        }
        return result;
    }

    CategoryVarSet categoricalVars(
        string family,
        const(string)[] keys,
        const(string)[] states
    ) {
        CategoryVarSet result;
        foreach (key; uniqueKeys(family, keys)) {
            result.keys ~= key;
            result.values[key] = categoricalVar(
                indexedName(family, key),
                states
            );
        }
        return result;
    }

    void require(
        string name,
        BoolExpr expression,
        string sourceFile = __FILE__,
        size_t sourceLine = __LINE__
    ) {
        addConstraint(
            name,
            expression,
            ConstraintLevel.hard,
            1.0,
            sourceFile,
            sourceLine
        );
    }

    void medium(
        string name,
        BoolExpr expression,
        double weight = 1.0,
        string sourceFile = __FILE__,
        size_t sourceLine = __LINE__
    ) {
        addConstraint(
            name,
            expression,
            ConstraintLevel.medium,
            weight,
            sourceFile,
            sourceLine
        );
    }

    void prefer(
        string name,
        BoolExpr expression,
        double weight = 1.0,
        string sourceFile = __FILE__,
        size_t sourceLine = __LINE__
    ) {
        addConstraint(
            name,
            expression,
            ConstraintLevel.soft,
            weight,
            sourceFile,
            sourceLine
        );
    }

    /**
     * Add one exact hard CNF clause.
     *
     * Every entry must be a direct Boolean variable or its direct negation.
     * Empty clauses, repeated literals, literal order, and opposite pairs are
     * retained exactly for benchmark/DIMACS compatibility.
     */
    void requireClause(
        string name,
        BoolExpr[] literals,
        string sourceFile = __FILE__,
        size_t sourceLine = __LINE__
    ) {
        addNativeClause(
            name,
            literals,
            ConstraintLevel.hard,
            1.0,
            sourceFile,
            sourceLine
        );
    }

    void mediumClause(
        string name,
        BoolExpr[] literals,
        double weight = 1.0,
        string sourceFile = __FILE__,
        size_t sourceLine = __LINE__
    ) {
        addNativeClause(
            name,
            literals,
            ConstraintLevel.medium,
            weight,
            sourceFile,
            sourceLine
        );
    }

    void preferClause(
        string name,
        BoolExpr[] literals,
        double weight = 1.0,
        string sourceFile = __FILE__,
        size_t sourceLine = __LINE__
    ) {
        addNativeClause(
            name,
            literals,
            ConstraintLevel.soft,
            weight,
            sourceFile,
            sourceLine
        );
    }

    void maximize(string name, IntExpr expression, int priority = 0) {
        addObjective(name, expression, ObjectiveSense.maximize, priority);
    }

    void minimize(string name, IntExpr expression, int priority = 0) {
        addObjective(name, expression, ObjectiveSense.minimize, priority);
    }

    void parity(string name, BoolExpr[] variables, int target) {
        ensureMutable();
        if (target != 0 && target != 1) {
            throw new ModelException("Parity target must be either 0 or 1");
        }
        if (variables.length == 0) {
            throw new ModelException("Parity constraint needs at least one variable");
        }

        size_t[] indices;
        foreach (expression; variables) {
            if (
                expression.node is null ||
                expression.node.owner !is this
            ) {
                throw new ModelException(
                    "Parity variables must belong to the receiving model"
                );
            }
            if (
                expression.node.kind != ExpressionKind.variable ||
                _variables[expression.node.variableIndex].kind != VariableKind.boolean
            ) {
                throw new ModelException(
                    "Parity constraints currently accept direct Boolean variables only"
                );
            }
            if (indices.canFind(expression.node.variableIndex)) {
                throw new ModelException(
                    "Parity constraints cannot contain a duplicate variable"
                );
            }
            indices ~= expression.node.variableIndex;
        }

        _parityConstraints ~= ParityConstraint(
            name,
            indices,
            target,
            activeSemanticOperationId
        );
    }

    void requireParity(string name, BoolExpr[] variables, int target = 0) {
        parity(name, variables, target);
    }

    bool hasVariable(string name) const {
        return (name in variableLookup) !is null;
    }

    size_t variableIndex(string name) const {
        auto found = name in variableLookup;
        if (found is null) {
            throw new ModelException("Unknown decision variable '" ~ name ~ "'");
        }
        return *found;
    }

    private void ensureUniqueName(string name) {
        ensureMutable();
        if (name.length == 0) {
            throw new ModelException("Decision variable names cannot be empty");
        }
        if (hasVariable(name)) {
            throw new ModelException("Duplicate decision variable '" ~ name ~ "'");
        }
    }

    private string[] uniqueKeys(string family, const(string)[] keys) {
        if (family.length == 0) {
            throw new ModelException("Variable family names cannot be empty");
        }
        string[] seen;
        foreach (key; keys) {
            if (key.length == 0) {
                throw new ModelException(
                    "Variable family '" ~ family ~ "' contains an empty key"
                );
            }
            if (seen.canFind(key)) {
                throw new ModelException(format(
                    "Variable family '%s' contains duplicate key '%s'",
                    family,
                    key
                ));
            }
            seen ~= key.idup;
        }
        return seen;
    }

    private void addConstraint(
        string name,
        BoolExpr expression,
        ConstraintLevel level,
        double weight,
        string sourceFile,
        size_t sourceLine
    ) {
        ensureMutable();
        if (name.length == 0) {
            throw new ModelException("Constraint names cannot be empty");
        }
        if (expression.node is null) {
            throw new ModelException("Constraint '" ~ name ~ "' has no expression");
        }
        if (expression.node.owner !is null && expression.node.owner !is this) {
            throw new ModelException(
                "Constraint '" ~ name ~ "' belongs to a different model"
            );
        }
        if (!weight.isFinite || weight <= 0.0) {
            throw new ModelException(
                "Constraint weights must be finite and positive"
            );
        }

        _constraints ~= NamedConstraint(
            name,
            expression,
            level,
            weight,
            sourceFile,
            sourceLine,
            activeSemanticOperationId
        );
    }

    private void addNativeClause(
        string name,
        BoolExpr[] expressions,
        ConstraintLevel level,
        double weight,
        string sourceFile,
        size_t sourceLine
    ) {
        ensureMutable();
        if (name.length == 0) {
            throw new ModelException("Clause names cannot be empty");
        }
        if (!weight.isFinite || weight <= 0.0) {
            throw new ModelException(
                "Clause weights must be finite and positive"
            );
        }

        ModelClauseLiteral[] literals;
        foreach (expression; expressions) {
            if (
                expression._node is null ||
                expression._node.owner !is this
            ) {
                throw new ModelException(
                    "Native clause literals must belong to the receiving model"
                );
            }

            auto node = expression._node;
            bool negated = expression._negated;
            
            // Still check just in case a manual logicalNot node was passed
            if (node.kind == ExpressionKind.logicalNot) {
                if (
                    node.children.length != 1 ||
                    node.children[0].kind != ExpressionKind.variable
                ) {
                    throw new ModelException(
                        "Native clause negations must apply directly to a " ~
                        "Boolean variable"
                    );
                }
                node = node.children[0];
                negated = !negated; // Flip negation
            }
            if (
                node.kind != ExpressionKind.variable ||
                _variables[node.variableIndex].kind != VariableKind.boolean
            ) {
                throw new ModelException(
                    "Native clauses accept direct Boolean variables or their " ~
                    "direct negations only"
                );
            }
            literals ~= ModelClauseLiteral(node.variableIndex, negated);
        }

        _nativeClauses ~= NamedModelClause(
            name,
            literals,
            level,
            weight,
            sourceFile,
            sourceLine,
            activeSemanticOperationId
        );
    }

    private void addObjective(
        string name,
        IntExpr expression,
        ObjectiveSense sense,
        int priority
    ) {
        ensureMutable();
        if (name.length == 0) {
            throw new ModelException("Objective names cannot be empty");
        }
        if (expression.node is null) {
            throw new ModelException("Objective '" ~ name ~ "' has no expression");
        }
        if (expression.node.owner !is null && expression.node.owner !is this) {
            throw new ModelException(
                "Objective '" ~ name ~ "' belongs to a different model"
            );
        }
        if (priority < 0) {
            throw new ModelException("Objective priority cannot be negative");
        }

        _objectives ~= NamedObjective(
            name,
            expression,
            sense,
            priority,
            activeSemanticOperationId
        );
    }

    private void ensureMutable() const {
        if (_frozen) {
            throw new ModelException(
                "Decision model is frozen after successful compilation"
            );
        }
    }
}

private string indexedName(string family, string key) {
    return family ~ "[" ~ key ~ "]";
}

private ExpressionNode variableNode(Model owner, size_t index) {
    auto node = new ExpressionNode(ExpressionKind.variable);
    node.variableIndex = index;
    node.owner = owner;
    return node;
}

BoolExpr boolean(bool value) {
    auto node = new ExpressionNode(ExpressionKind.booleanConstant);
    node.booleanValue = value;
    return BoolExpr(node);
}

IntExpr integer(long value) {
    auto node = new ExpressionNode(ExpressionKind.integerConstant);
    node.integerValue = value;
    return IntExpr(node);
}

BoolExpr implies(BoolExpr premise, BoolExpr consequence) {
    auto owner = premise.node().owner !is null ? premise.node().owner : consequence.node().owner;
    return BoolExpr(binaryNode(
        owner,
        ExpressionKind.implies,
        premise.node(),
        consequence.node()
    ));
}

BoolExpr logicalNot(BoolExpr expression) {
    return BoolExpr(unaryNode(expression.node().owner, ExpressionKind.logicalNot, expression.node()));
}

BoolExpr equivalent(BoolExpr left, BoolExpr right) {
    auto owner = left.node().owner !is null ? left.node().owner : right.node().owner;
    return BoolExpr(binaryNode(
        owner,
        ExpressionKind.equivalent,
        left.node(),
        right.node()
    ));
}

BoolExpr equal(IntExpr left, IntExpr right) {
    auto owner = left.node.owner !is null ? left.node.owner : right.node.owner;
    return BoolExpr(binaryNode(owner, ExpressionKind.equal, left.node, right.node));
}

BoolExpr notEqual(IntExpr left, IntExpr right) {
    auto owner = left.node.owner !is null ? left.node.owner : right.node.owner;
    return BoolExpr(binaryNode(owner, ExpressionKind.notEqual, left.node, right.node));
}

BoolExpr lessThan(IntExpr left, IntExpr right) {
    auto owner = left.node.owner !is null ? left.node.owner : right.node.owner;
    return BoolExpr(binaryNode(owner, ExpressionKind.lessThan, left.node, right.node));
}

BoolExpr lessEqual(IntExpr left, IntExpr right) {
    auto owner = left.node.owner !is null ? left.node.owner : right.node.owner;
    return BoolExpr(binaryNode(owner, ExpressionKind.lessEqual, left.node, right.node));
}

BoolExpr greaterThan(IntExpr left, IntExpr right) {
    auto owner = left.node.owner !is null ? left.node.owner : right.node.owner;
    return BoolExpr(binaryNode(owner, ExpressionKind.greaterThan, left.node, right.node));
}

BoolExpr greaterEqual(IntExpr left, IntExpr right) {
    auto owner = left.node.owner !is null ? left.node.owner : right.node.owner;
    return BoolExpr(binaryNode(owner, ExpressionKind.greaterEqual, left.node, right.node));
}

BoolExpr allDifferent(IntExpr[] expressions) {
    if (expressions.length < 2) {
        throw new ModelException("allDifferent needs at least two expressions");
    }

    auto node = new ExpressionNode(ExpressionKind.allDifferent);
    foreach (expression; expressions) {
        if (
            node.owner !is null &&
            expression.node.owner !is null &&
            node.owner !is expression.node.owner
        ) {
            throw new ModelException(
                "Cannot combine allDifferent expressions from different models"
            );
        }
        if (node.owner is null) {
            node.owner = expression.node.owner;
        }
        node.children ~= expression.node;
    }
    return BoolExpr(node);
}

BoolExpr allDifferent(CategoryExpr[] expressions) {
    if (expressions.length >= 2) {
        foreach (expression; expressions[1 .. $]) {
            if (expression.states != expressions[0].states) {
                throw new ModelException(
                    "allDifferent categorical expressions must share one " ~
                    "ordered state domain"
                );
            }
        }
    }
    IntExpr[] values;
    foreach (expression; expressions) {
        values ~= expression.asInteger();
    }
    return allDifferent(values);
}

IntExpr sumExpr(IntExpr[] expressions) {
    if (expressions.length == 0) {
        return integer(0);
    }

    auto result = expressions[0];
    foreach (expression; expressions[1 .. $]) {
        result = result + expression;
    }
    return result;
}

IntExpr asInteger(BoolExpr expression) {
    return IntExpr(unaryNode(
        expression.node().owner,
        ExpressionKind.booleanAsInteger,
        expression.node()
    ));
}

IntExpr countTrue(BoolExpr[] expressions) {
    IntExpr[] values;
    foreach (expression; expressions) {
        values ~= asInteger(expression);
    }
    return sumExpr(values);
}

BoolExpr atMost(size_t count, BoolExpr[] expressions) {
    return lessEqual(
        countTrue(expressions),
        integer(cast(long) count)
    );
}

BoolExpr atLeast(size_t count, BoolExpr[] expressions) {
    return greaterEqual(
        countTrue(expressions),
        integer(cast(long) count)
    );
}

BoolExpr exactly(size_t count, BoolExpr[] expressions) {
    return equal(
        countTrue(expressions),
        integer(cast(long) count)
    );
}

BoolExpr atMostOne(BoolExpr[] expressions) {
    return atMost(1, expressions);
}

BoolExpr atLeastOne(BoolExpr[] expressions) {
    return atLeast(1, expressions);
}

BoolExpr exactlyOne(BoolExpr[] expressions) {
    return exactly(1, expressions);
}

BoolExpr between(size_t minCount, size_t maxCount, BoolExpr[] expressions) {
    auto count = countTrue(expressions);
    return greaterEqual(count, integer(cast(long) minCount)) & lessEqual(count, integer(cast(long) maxCount));
}

BoolExpr unless(BoolExpr target, BoolExpr condition) {
    return implies(logicalNot(condition), target);
}

BoolExpr allDifferentBools(BoolExpr[] expressions) {
    if (expressions.length <= 1) {
        return boolean(true);
    }
    BoolExpr acc;
    bool first = true;
    foreach (i; 0 .. expressions.length) {
        foreach (j; i + 1 .. expressions.length) {
            auto a = expressions[i];
            auto b = expressions[j];
            // Pairwise XOR encoding: (¬a ∨ ¬b) ∧ (a ∨ b)
            auto pairConstr = (~a | ~b) & (a | b);
            acc = first ? pairConstr : (acc & pairConstr);
            first = false;
        }
    }
    return acc;
}

string[] crossKeys(const(string)[] first, const(string)[] second) {
    string[] result;
    foreach (left; first) {
        foreach (right; second) {
            result ~= left ~ "," ~ right;
        }
    }
    return result;
}