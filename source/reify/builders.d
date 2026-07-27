// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.builders;

import reify.model;
import reify.explain;
import std.conv : to;
import std.format : format;
import std.array : join;
import std.traits : EnumMembers;

/**
 * Relational decision candidate.
 *
 * SpaceTime deliberately treats each surviving tuple as a finite possible
 * world in the Kripke-inspired interpretation. `tuple` names the world and
 * `expr` is its propositional valuation atom.
 */
struct DecisionCandidate {
    string varName;
    string[string] tuple;
    BoolExpr expr;
}

/**
 * A relational partition of possible worlds.
 *
 * Query-language operations choose the partition key; cardinality operations
 * then state laws over the truth valuation inside every partition.
 */
struct DecisionGroup {
    Model model;
    DecisionSpace parent;      // back-pointer for explainPlan() aggregation
    string spaceName;
    string[] groupDims;
    BoolExpr[][string] groups;

    this(DecisionSpace parent, Model model, string spaceName,
         string[] groupDims, BoolExpr[][string] groups) {
        this.parent    = parent;
        this.model     = model;
        this.spaceName = spaceName;
        this.groupDims = groupDims;
        this.groups    = groups;
    }

    private void beginSemantic(
        string kind,
        string level,
        string[string] extra = null
    ) {
        string[string] attributes = extra.dup;
        attributes["space"] = spaceName;
        attributes["level"] = level;
        attributes["group_count"] = groups.length.to!string;
        const operationId = model.registerSemanticOperation(
            parent is null ? "decision-space" : parent.semanticDomain,
            kind,
            kind ~ " by " ~ groupDims.join(", "),
            groupDims,
            attributes
        );
        model.enterSemanticOperation(operationId);
    }

    private void endSemantic() {
        model.leaveSemanticOperation();
    }

    void exactlyOne() {
        beginSemantic("exactlyOne", "hard");
        scope(exit) endSemantic();
        if (parent !is null) {
            parent._logicalPlan.constraints ~=
                ConstraintRecord("exactlyOne", groupDims, groups.length, "hard");
            parent._logicalPlan.hardCount++;
        }
        foreach (key, exprs; groups) {
            if (exprs.length == 1) {
                model.requireClause(format("%s_%s_exactly_one_%s", spaceName, groupDims.join("_"), key), [exprs[0]]);
            } else if (exprs.length > 1) {
                model.require(format("%s_%s_exactly_one_%s", spaceName, groupDims.join("_"), key), .exactlyOne(exprs));
            }
        }
    }

    void atMostOne() {
        beginSemantic("atMostOne", "hard");
        scope(exit) endSemantic();
        if (parent !is null) {
            parent._logicalPlan.constraints ~=
                ConstraintRecord("atMostOne", groupDims, groups.length, "hard");
            parent._logicalPlan.hardCount++;
        }
        foreach (key, exprs; groups) {
            if (exprs.length > 1) {
                if (exprs.length <= 8) {
                    foreach (i; 0 .. exprs.length) {
                        foreach (j; i + 1 .. exprs.length) {
                            model.requireClause(
                                format("%s_%s_at_most_one_%s_%d_%d", spaceName, groupDims.join("_"), key, i, j),
                                [logicalNot(exprs[i]), logicalNot(exprs[j])]
                            );
                        }
                    }
                } else {
                    model.require(format("%s_%s_at_most_one_%s", spaceName, groupDims.join("_"), key), .atMostOne(exprs));
                }
            }
        }
    }

    void atLeastOne() {
        beginSemantic("atLeastOne", "hard");
        scope(exit) endSemantic();
        if (parent !is null) {
            parent._logicalPlan.constraints ~=
                ConstraintRecord("atLeastOne", groupDims, groups.length, "hard");
            parent._logicalPlan.hardCount++;
        }
        foreach (key, exprs; groups) {
            if (exprs.length == 1) {
                model.requireClause(format("%s_%s_at_least_one_%s", spaceName, groupDims.join("_"), key), [exprs[0]]);
            } else if (exprs.length > 1) {
                model.require(format("%s_%s_at_least_one_%s", spaceName, groupDims.join("_"), key), .atLeastOne(exprs));
            }
        }
    }

    void between(size_t minCount, size_t maxCount)
    in {
        assert(minCount <= maxCount, "minCount must be <= maxCount");
    }
    do {
        string[string] attributes;
        attributes["minimum"] = minCount.to!string;
        attributes["maximum"] = maxCount.to!string;
        beginSemantic("between", "hard", attributes);
        scope(exit) endSemantic();
        if (parent !is null) {
            parent._logicalPlan.constraints ~=
                ConstraintRecord("between", groupDims, groups.length, "hard");
            parent._logicalPlan.hardCount++;
        }
        foreach (key, exprs; groups) {
            if (exprs.length > 0) {
                model.require(format("%s_%s_between_%d_%d_%s", spaceName, groupDims.join("_"), minCount, maxCount, key), .between(minCount, maxCount, exprs));
            }
        }
    }

    void atMost(size_t maxCount)
    in {
        assert(maxCount > 0, "maxCount must be > 0");
    }
    do {
        string[string] attributes;
        attributes["maximum"] = maxCount.to!string;
        beginSemantic("atMost", "hard", attributes);
        scope(exit) endSemantic();
        if (parent !is null) {
            parent._logicalPlan.constraints ~=
                ConstraintRecord("atMost", groupDims, groups.length, "hard");
            parent._logicalPlan.hardCount++;
        }
        foreach (key, exprs; groups) {
            if (exprs.length > 0) {
                model.require(format("%s_%s_at_most_%d_%s", spaceName, groupDims.join("_"), maxCount, key), .atMost(maxCount, exprs));
            }
        }
    }

    // -------------------------------------------------------------------------
    // Advanced Solvers: Parity (XOR) Constraints
    // -------------------------------------------------------------------------

    void parityEven() {
        beginSemantic("parityEven", "parity");
        scope(exit) endSemantic();
        if (parent !is null) {
            parent._logicalPlan.constraints ~=
                ConstraintRecord("parityEven", groupDims, groups.length, "parity");
            parent._logicalPlan.parityCount++;
        }
        foreach (key, exprs; groups) {
            if (exprs.length > 0) {
                model.requireParity(format("%s_%s_parity_even_%s", spaceName, groupDims.join("_"), key), exprs, 0);
            }
        }
    }

    void parityOdd() {
        beginSemantic("parityOdd", "parity");
        scope(exit) endSemantic();
        if (parent !is null) {
            parent._logicalPlan.constraints ~=
                ConstraintRecord("parityOdd", groupDims, groups.length, "parity");
            parent._logicalPlan.parityCount++;
        }
        foreach (key, exprs; groups) {
            if (exprs.length > 0) {
                model.requireParity(format("%s_%s_parity_odd_%s", spaceName, groupDims.join("_"), key), exprs, 1);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Advanced Solvers: Soft Constraints (MaxSAT / WCNF)
    // -------------------------------------------------------------------------

    void preferAtLeastOne(double weight = 1.0)
    in {
        assert(weight > 0.0, "Weight must be positive");
    }
    do {
        string[string] attributes;
        attributes["weight"] = weight.to!string;
        beginSemantic("preferAtLeastOne", "soft", attributes);
        scope(exit) endSemantic();
        if (parent !is null) {
            parent._logicalPlan.constraints ~=
                ConstraintRecord("preferAtLeastOne", groupDims, groups.length, "soft");
            parent._logicalPlan.softCount++;
        }
        foreach (key, exprs; groups) {
            if (exprs.length > 0) {
                model.preferClause(format("%s_%s_prefer_at_least_one_%s", spaceName, groupDims.join("_"), key), exprs, weight);
            }
        }
    }

    void preferAtMostOne(double weight = 1.0)
    in {
        assert(weight > 0.0, "Weight must be positive");
    }
    do {
        string[string] attributes;
        attributes["weight"] = weight.to!string;
        beginSemantic("preferAtMostOne", "soft", attributes);
        scope(exit) endSemantic();
        if (parent !is null) {
            parent._logicalPlan.constraints ~=
                ConstraintRecord("preferAtMostOne", groupDims, groups.length, "soft");
            parent._logicalPlan.softCount++;
        }
        foreach (key, exprs; groups) {
            if (exprs.length > 1) {
                foreach (i; 0 .. exprs.length) {
                    foreach (j; i + 1 .. exprs.length) {
                        model.preferClause(
                            format("%s_%s_prefer_at_most_one_%s_%d_%d", spaceName, groupDims.join("_"), key, i, j),
                            [~exprs[i], ~exprs[j]],
                            weight
                        );
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Advanced Solvers: Objective Preference Hooks
    // -------------------------------------------------------------------------

    void maximize(double weight = 1.0)
    in {
        assert(weight > 0.0, "Weight must be positive");
    }
    do {
        string[string] attributes;
        attributes["weight"] = weight.to!string;
        beginSemantic("maximize", "objective", attributes);
        scope(exit) endSemantic();
        if (parent !is null) {
            parent._logicalPlan.constraints ~=
                ConstraintRecord("maximize", groupDims, groups.length, "objective");
            parent._logicalPlan.objectiveCount++;
        }
        foreach (key, exprs; groups) {
            foreach (i, expr; exprs) {
                model.preferClause(format("%s_%s_max_%s_%d", spaceName, groupDims.join("_"), key, i), [expr], weight);
            }
        }
    }

    void minimize(double weight = 1.0)
    in {
        assert(weight > 0.0, "Weight must be positive");
    }
    do {
        string[string] attributes;
        attributes["weight"] = weight.to!string;
        beginSemantic("minimize", "objective", attributes);
        scope(exit) endSemantic();
        if (parent !is null) {
            parent._logicalPlan.constraints ~=
                ConstraintRecord("minimize", groupDims, groups.length, "objective");
            parent._logicalPlan.objectiveCount++;
        }
        foreach (key, exprs; groups) {
            foreach (i, expr; exprs) {
                model.preferClause(format("%s_%s_min_%s_%d", spaceName, groupDims.join("_"), key, i), [~expr], weight);
            }
        }
    }
}

/// Relational Decision Space Builder
class DecisionSpace {
    Model model;
    string spaceName;
    string semanticDomain = "decision-space";

    struct DimSpec {
        string name;
        string[] values;
    }

    DimSpec[] dims;
    bool delegate(const(string[string])) filterPredicate;
    DecisionCandidate[] candidates;

    // Logical plan metadata — populated during build() and groupBy()
    LogicalPlan _logicalPlan;
    size_t _rawCartesianSize = 1;

    this(Model m, string spaceName) {
        this.model = m;
        this.spaceName = spaceName;
        this._logicalPlan.spaceName = spaceName;
    }

    DecisionSpace dimension(string dimName, string[] values)
    in {
        assert(values.length > 0, "Dimension values cannot be empty");
    }
    do {
        dims ~= DimSpec(dimName, values);
        _rawCartesianSize *= values.length;
        _logicalPlan.dimensions ~= DimensionInfo(dimName, values.length);
        return this;
    }

    DecisionSpace dimension(string dimName, int count)
    in {
        assert(count > 0, "Dimension count must be > 0");
    }
    do {
        string[] vals;
        foreach (i; 1 .. count + 1) vals ~= i.to!string;
        dims ~= DimSpec(dimName, vals);
        _rawCartesianSize *= count;
        _logicalPlan.dimensions ~= DimensionInfo(dimName, count);
        return this;
    }

    DecisionSpace filter(bool delegate(const(string[string])) predicate) {
        this.filterPredicate = predicate;
        return this;
    }

    DecisionSpace build() {
        // Construct the finite frame W as a Cartesian product followed by a
        // predicate restriction. This is query planning on the surface and
        // finite possible-world construction at the semantic layer.
        // Phase 3: Zero-Allocation Range Pipeline equivalent for tuples.
        // We mutate a single shared state dictionary down the recursive tree.
        void generateTuples(size_t dimIndex, ref string[string] currentTuple) {
            if (dimIndex == dims.length) {
                if (filterPredicate !is null && !filterPredicate(currentTuple)) {
                    return;
                }
                
                string[] parts = [spaceName];
                foreach (d; dims) {
                    parts ~= d.name ~ "_" ~ currentTuple[d.name];
                }
                string varKey = parts.join("_");
                auto expr = model.booleanVar(varKey);

                // Only .dup when we actually store a surviving candidate!
                candidates ~= DecisionCandidate(varKey, currentTuple.dup, expr);
                return;
            }

            auto dim = dims[dimIndex];
            foreach (val; dim.values) {
                currentTuple[dim.name] = val; // Mutate shared state
                generateTuples(dimIndex + 1, currentTuple);
            }
        }

        string[string] sharedTuple;
        generateTuples(0, sharedTuple);
        _logicalPlan.rawCartesianSize  = _rawCartesianSize;
        _logicalPlan.filteredCandidates = candidates.length;
        _logicalPlan.filterSelectivity  = _rawCartesianSize > 0
            ? cast(double) candidates.length / cast(double) _rawCartesianSize
            : 0.0;
        return this;
    }

    DecisionGroup groupBy(string[] groupDims...)
    in {
        assert(groupDims.length > 0, "Must group by at least one dimension");
    }
    do {
        // Like relational GROUP BY, this does not ask for stored rows. It
        // partitions possible worlds so the following operator can constrain
        // which members may be true together.
        BoolExpr[][string] groups;
        foreach (c; candidates) {
            string[] keyParts;
            foreach (dimName; groupDims) {
                keyParts ~= c.tuple[dimName];
            }
            string groupKey = keyParts.join("_");
            groups[groupKey] ~= c.expr;
        }
        return DecisionGroup(this, model, spaceName, groupDims.dup, groups);
    }

    /// Returns the pre-compilation logical plan for this decision space
    LogicalPlan explainPlan() {
        return explainLogical(this);
    }

    /// Returns the physical routing plan based on current model topology
    PhysicalPlan explainPhysical() {
        return .explainPhysical(model);
    }
}

/// Helper extension method on Model for DecisionSpace
DecisionSpace decisionSpace(Model m, string spaceName) {
    return new DecisionSpace(m, spaceName);
}

// -----------------------------------------------------------------------------
// Phase 2: Compile-Time Safety via Type-Safe Dimensions
// -----------------------------------------------------------------------------

class TypedDecisionSpaceBuilder {
    DecisionSpace inner;
    string[] dimNames;

    this(Model m, string spaceName) {
        inner = new DecisionSpace(m, spaceName);
    }

    TypedDecisionSpaceBuilder dimension(R)(string dimName, R values) {
        dimNames ~= dimName;
        string[] strVals;
        foreach (val; values) {
            strVals ~= val.to!string;
        }
        inner.dimension(dimName, strVals);
        return this;
    }
    
    TypedDecisionSpaceBuilder dimension(string dimName, int count) {
        dimNames ~= dimName;
        inner.dimension(dimName, count);
        return this;
    }

    auto filter(T...)(bool delegate(T) predicate) {
        assert(T.length == dimNames.length, "Delegate arguments must match dimension count");
        inner.filterPredicate = (const(string[string]) t) {
            T args;
            static foreach (i, type; T) {
                static if (is(type == enum)) {
                    args[i] = t[dimNames[i]].to!string.to!type;
                } else {
                    args[i] = t[dimNames[i]].to!type;
                }
            }
            return predicate(args);
        };
        return this;
    }

    TypedDecisionSpaceBuilder build() {
        inner.build();
        return this;
    }

    DecisionGroup groupBy(string[] groupDims...) {
        return inner.groupBy(groupDims);
    }

    /// Returns the pre-compilation logical plan for this typed decision space
    LogicalPlan explainPlan() {
        return inner.explainPlan();
    }

    /// Returns the physical routing plan based on current model topology
    PhysicalPlan explainPhysical() {
        return inner.explainPhysical();
    }
}

/// Helper extension method for TypedDecisionSpace
TypedDecisionSpaceBuilder typedDecisionSpace(Model m, string spaceName) {
    return new TypedDecisionSpaceBuilder(m, spaceName);
}