// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.spacetime;

/**
 * SpaceTime is a temporal projection over DecisionSpace.
 *
 * DecisionSpace describes possible choices. SpaceTime retains the same
 * relational candidates and adds an ordered time dimension, temporal
 * vocabulary, and composable constraint recipes. Everything still lowers into
 * the ordinary Model IR and therefore uses the existing CNF/WCNF compiler.
 *
 * Kripke-semantics correspondence
 * --------------------------------
 * This module intentionally borrows the useful shape of a finite Kripke
 * structure:
 *
 *   W — DecisionCandidate tuples are the finite set of possible worlds.
 *   R — time order, `before`, duration overlap, and resource compatibility
 *       induce accessibility/incompatibility relations between those worlds.
 *   V — each candidate's BoolExpr is the valuation saying whether that world
 *       belongs to the selected solution.
 *
 * Recipes then state laws over W, R, and V, and the ordinary Navokoj compiler
 * asks SAT/MaxSAT to find a valuation satisfying those laws. This is an
 * engineering correspondence, not a claim that SpaceTime implements a complete
 * modal-logic proof system: modal operators such as □ and ◇ are not yet part of
 * the public language.
 */

import reify.builders : DecisionCandidate, DecisionGroup, DecisionSpace;
import reify.errors : ModelException;
import reify.explain : LogicalPlan, PhysicalPlan, explainLogical, explainPhysical;
import reify.model : BoolExpr, Model, atMost, logicalNot;

import std.algorithm : canFind;
import std.array : join;
import std.conv : to;
import std.format : format;
import std.meta : staticIndexOf;

/**
 * A compile-time named decision dimension.
 *
 * In the Kripke-inspired reading, dimensions provide coordinates for naming a
 * finite world without changing its truth valuation.
 *
 * Example:
 *   alias DoctorDim = Dimension!("doctor", Doctor);
 */
struct Dimension(string dimensionName_, ValueType_) {
    enum name = dimensionName_;
    alias Value = ValueType_;
    enum temporal = false;
}

/**
 * A compile-time named, ordered time dimension.
 *
 * Values are ordered exactly as they are supplied to SpaceTime.time.
 * Consecutive values provide the primitive temporal accessibility relation used
 * when temporal vocabulary is lowered to clauses.
 */
struct TimeDimension(string dimensionName_, ValueType_) {
    enum name = dimensionName_;
    alias Value = ValueType_;
    enum temporal = true;
}

/**
 * A discrete availability window. Values use the same external spelling as
 * their dimension values, so enums, integers, and strings can all be used.
 */
struct TimeWindow {
    string[] allowedValues;

    bool contains(string value) const {
        return allowedValues.canFind(value);
    }
}

TimeWindow timeWindow(R)(R values) {
    return TimeWindow(stringValues(values));
}

private string[] stringValues(R)(R values) {
    string[] result;
    foreach (value; values) {
        result ~= value.to!string;
    }
    return result;
}

private void requirePositiveWeight(double weight) {
    if (weight <= 0.0) {
        throw new ModelException("Recipe weights must be positive");
    }
}

/**
 * A composable policy fragment. A recipe only contributes model constraints;
 * it does not own a solver or a second intermediate representation.
 *
 * Semantically, a recipe is a reusable theory over possible worlds. `and`
 * forms the conjunction (union of generated laws) of two such theories.
 */
struct ConstraintRecipe {
    alias Step = void delegate(SpaceTime);

    private Step[] steps;
    private string availabilityDimension;
    string description;

    ConstraintRecipe and(ConstraintRecipe other) {
        ConstraintRecipe combined;
        combined.steps = this.steps.dup;
        combined.steps ~= other.steps;
        combined.description =
            this.description.length == 0
                ? other.description
                : (
                    other.description.length == 0
                        ? this.description
                        : this.description ~ " and " ~ other.description
                );
        return combined;
    }

    /**
     * Restrict a resource-scoped recipe, such as nonOverlapping("doctor"), to
     * a discrete availability window.
     */
    ConstraintRecipe within(TimeWindow window) {
        if (availabilityDimension.length == 0) {
            throw new ModelException(
                "within() must follow a resource-scoped recipe"
            );
        }
        auto result = this;
        auto resource = availabilityDimension;
        auto capturedWindow = window;
        result.steps ~= (SpaceTime space) {
            space.within(resource, capturedWindow);
        };
        result.description ~= " within availability";
        return result;
    }

    void apply(SpaceTime space) const {
        if (space is null) {
            throw new ModelException("Cannot apply a recipe to null SpaceTime");
        }
        foreach (step; steps) {
            step(space);
        }
    }
}

ConstraintRecipe exactlyOnePer(string[] dimensions...) {
    if (dimensions.length == 0) {
        throw new ModelException(
            "exactlyOnePer needs at least one dimension"
        );
    }
    auto captured = dimensions.dup;
    ConstraintRecipe recipe;
    recipe.description = "exactly one per " ~ captured.join(", ");
    recipe.steps ~= (SpaceTime space) {
        space.groupBy(captured).exactlyOne();
    };
    return recipe;
}

ConstraintRecipe exactlyOnePer(Dimensions...)()
if (Dimensions.length > 0) {
    string[] names;
    static foreach (D; Dimensions) {
        static assert(
            __traits(compiles, D.name),
            "exactlyOnePer template arguments must be Dimension types"
        );
        names ~= D.name;
    }
    return exactlyOnePer(names);
}

ConstraintRecipe nonOverlapping(string resourceDimension) {
    if (resourceDimension.length == 0) {
        throw new ModelException(
            "nonOverlapping needs a resource dimension"
        );
    }
    const captured = resourceDimension;
    ConstraintRecipe recipe;
    recipe.availabilityDimension = captured;
    recipe.description = "non-overlapping " ~ captured;
    recipe.steps ~= (SpaceTime space) {
        space.enforceNonOverlapping(captured);
    };
    return recipe;
}

ConstraintRecipe nonOverlapping(ResourceDimension)() {
    static assert(
        __traits(compiles, ResourceDimension.name),
        "nonOverlapping template argument must be a Dimension type"
    );
    return nonOverlapping(ResourceDimension.name);
}

/**
 * Limit simultaneous selections for a resource. In SpaceTime, capacity is
 * naturally grouped by resource and time.
 */
ConstraintRecipe capacity(string resourceDimension, size_t limit) {
    if (resourceDimension.length == 0 || limit == 0) {
        throw new ModelException(
            "capacity needs a resource dimension and a positive limit"
        );
    }
    const captured = resourceDimension;
    const capturedLimit = limit;
    ConstraintRecipe recipe;
    recipe.availabilityDimension = captured;
    recipe.description = format("capacity %s <= %s", captured, limit);
    recipe.steps ~= (SpaceTime space) {
        space.enforceCapacity(captured, capturedLimit);
    };
    return recipe;
}

ConstraintRecipe capacity(ResourceDimension)(long limit) {
    static assert(
        __traits(compiles, ResourceDimension.name),
        "capacity template argument must be a Dimension type"
    );
    if (limit <= 0) {
        throw new ModelException("capacity limit must be positive");
    }
    return capacity(ResourceDimension.name, cast(size_t) limit);
}

/**
 * Prefer candidates containing a particular dimension value.
 */
ConstraintRecipe prefer(
    string dimension,
    string value,
    double weight = 1.0
) {
    requirePositiveWeight(weight);
    const capturedDimension = dimension;
    const capturedValue = value;
    const capturedWeight = weight;
    ConstraintRecipe recipe;
    recipe.description =
        "prefer " ~ capturedDimension ~ "=" ~ capturedValue;
    recipe.steps ~= (SpaceTime space) {
        space.preferValue(
            capturedDimension,
            capturedValue,
            capturedWeight
        );
    };
    return recipe;
}

/**
 * Concise form used when a value occurs in exactly one dimension.
 */
ConstraintRecipe prefer(string value, double weight = 1.0) {
    requirePositiveWeight(weight);
    const capturedValue = value;
    const capturedWeight = weight;
    ConstraintRecipe recipe;
    recipe.description = "prefer " ~ capturedValue;
    recipe.steps ~= (SpaceTime space) {
        space.preferValue("", capturedValue, capturedWeight);
    };
    return recipe;
}

ConstraintRecipe prefer(DimensionType)(
    DimensionType.Value value,
    double weight = 1.0
) {
    static assert(
        __traits(compiles, DimensionType.name),
        "prefer template argument must be a Dimension type"
    );
    return prefer(DimensionType.name, value.to!string, weight);
}

/**
 * Runtime/dynamic SpaceTime API. This is also the implementation used by the
 * compile-time checked TypedSpaceTime facade.
 */
final class SpaceTime {
    // `inner.candidates` is W, the finite world set. The tables below retain
    // enough structure to derive temporal fragments of R without introducing
    // a parallel model representation.
    private DecisionSpace inner;
    private string _timeDimensionName;
    private long[string] timeOrder;
    private size_t timeValueCount;
    private size_t[string] activityDurations;
    private string[string] activityDimensions;
    private bool built;

    this(Model model, string name) {
        inner = new DecisionSpace(model, name);
        inner.semanticDomain = "spacetime";
    }

    @property Model model() {
        return inner.model;
    }

    @property string name() const {
        return inner.spaceName;
    }

    /// Read-only access to the materialized relational candidate rows.
    @property DecisionCandidate[] candidates() {
        return inner.candidates;
    }

    @property string timeDimensionName() const {
        if (_timeDimensionName.length == 0) {
            throw new ModelException(
                "SpaceTime has no time dimension; call time() first"
            );
        }
        return _timeDimensionName;
    }

    SpaceTime dimension(string dimensionName, string[] values) {
        ensureNotBuilt();
        inner.dimension(dimensionName, values);
        return this;
    }

    SpaceTime dimension(R)(string dimensionName, R values) {
        return dimension(dimensionName, stringValues(values));
    }

    SpaceTime dimension(string dimensionName, int count) {
        ensureNotBuilt();
        inner.dimension(dimensionName, count);
        return this;
    }

    SpaceTime time(string dimensionName, string[] orderedValues) {
        ensureNotBuilt();
        if (_timeDimensionName.length != 0) {
            throw new ModelException(
                "SpaceTime supports one primary time dimension; '" ~
                _timeDimensionName ~ "' is already configured"
            );
        }
        if (orderedValues.length == 0) {
            throw new ModelException("Time dimension values cannot be empty");
        }
        string[string] semanticAttributes;
        semanticAttributes["time_dimension"] = dimensionName;
        semanticAttributes["ordered_values"] = orderedValues.join(", ");
        beginSemantic(
            "timeDimension",
            "ordered time dimension " ~ dimensionName,
            [dimensionName],
            semanticAttributes
        );
        scope(exit) endSemantic();
        _timeDimensionName = dimensionName;
        // The supplied order is intentional model semantics. It is the base
        // accessibility relation from which before/overlap constraints derive.
        foreach (index, value; orderedValues) {
            if ((value in timeOrder) !is null) {
                throw new ModelException(
                    "Time dimension contains duplicate value '" ~ value ~ "'"
                );
            }
            timeOrder[value] = cast(long) index;
        }
        timeValueCount = orderedValues.length;
        inner.dimension(dimensionName, orderedValues);
        return this;
    }

    SpaceTime time(R)(string dimensionName, R orderedValues) {
        return time(dimensionName, stringValues(orderedValues));
    }

    SpaceTime time(string dimensionName, int count) {
        string[] values;
        foreach (value; 1 .. count + 1) {
            values ~= value.to!string;
        }
        return time(dimensionName, values);
    }

    SpaceTime filter(
        bool delegate(const(string[string])) predicate
    ) {
        ensureNotBuilt();
        inner.filter(predicate);
        return this;
    }

    /**
     * Assign a discrete duration to an activity value. Unspecified activities
     * occupy one time value. Starts that would run past the time horizon are
     * forbidden immediately.
     */
    SpaceTime duration(string activity, size_t occupiedSlots) {
        ensureBuilt();
        if (occupiedSlots == 0) {
            throw new ModelException("Activity duration must be positive");
        }
        const activityDimension = inferValueDimension(activity);
        string[string] semanticAttributes;
        semanticAttributes["activity"] = activity;
        semanticAttributes["duration_slots"] = occupiedSlots.to!string;
        semanticAttributes["time_dimension"] = _timeDimensionName;
        beginSemantic(
            "duration",
            activity ~ " occupies " ~ occupiedSlots.to!string ~ " slots",
            [activityDimension, _timeDimensionName],
            semanticAttributes
        );
        scope(exit) endSemantic();
        activityDurations[activity] = occupiedSlots;
        activityDimensions[activity] = activityDimension;

        foreach (index, candidate; inner.candidates) {
            if (candidate.tuple[activityDimension] != activity) continue;
            const start = timeOrder[candidate.tuple[_timeDimensionName]];
            if (start + occupiedSlots > timeValueCount) {
                inner.model.requireClause(
                    format(
                        "%s_%s_fits_horizon_%s",
                        inner.spaceName,
                        activity,
                        index
                    ),
                    [logicalNot(candidate.expr)]
                );
            }
        }
        return this;
    }

    SpaceTime duration(Value)(Value activity, size_t occupiedSlots) {
        return duration(activity.to!string, occupiedSlots);
    }

    SpaceTime build() {
        if (_timeDimensionName.length == 0) {
            throw new ModelException(
                "SpaceTime needs a primary time dimension before build()"
            );
        }
        // Materialize W exactly once. Every surviving relational tuple becomes
        // a propositional atom whose truth is chosen by the eventual model.
        inner.build();
        built = true;
        return this;
    }

    DecisionGroup groupBy(string[] dimensions...) {
        ensureBuilt();
        foreach (dimension; dimensions) {
            requireDimension(dimension);
        }
        return inner.groupBy(dimensions);
    }

    LogicalPlan explainPlan() {
        return .explainLogical(inner);
    }

    PhysicalPlan explainPhysical() {
        return .explainPhysical(inner.model);
    }

    /**
     * Forbid candidates outside a global working window. The resource
     * dimension is explicit for policy provenance and future per-resource
     * calendars.
     *
     * In Kripke terms this restricts admissible valuations: worlds whose full
     * temporal interval lies outside the allowed frame are forced false.
     */
    SpaceTime within(
        string resourceDimension,
        TimeWindow window
    ) {
        ensureBuilt();
        requireDimension(resourceDimension);
        if (window.allowedValues.length == 0) {
            throw new ModelException("Availability window cannot be empty");
        }
        foreach (value; window.allowedValues) {
            if ((value in timeOrder) is null) {
                throw new ModelException(
                    "Availability references unknown time value '" ~ value ~ "'"
                );
            }
        }
        string[string] semanticAttributes;
        semanticAttributes["resource_dimension"] = resourceDimension;
        semanticAttributes["time_dimension"] = _timeDimensionName;
        semanticAttributes["allowed_values"] =
            window.allowedValues.join(", ");
        beginSemantic(
            "within",
            resourceDimension ~ " within availability",
            [resourceDimension, _timeDimensionName],
            semanticAttributes
        );
        scope(exit) endSemantic();
        foreach (index, candidate; inner.candidates) {
            const timeValue = candidate.tuple[_timeDimensionName];
            const start = timeOrder[timeValue];
            const duration = candidateDuration(candidate);
            bool fullyAvailable = true;
            foreach (offset; 0 .. duration) {
                const occupied = start + cast(long) offset;
                if (
                    occupied >= timeValueCount ||
                    !window.contains(timeValueAt(occupied))
                ) {
                    fullyAvailable = false;
                    break;
                }
            }
            if (!fullyAvailable) {
                inner.model.requireClause(
                    format(
                        "%s_%s_within_%s_%s",
                        inner.spaceName,
                        resourceDimension,
                        timeValue,
                        index
                    ),
                    [logicalNot(candidate.expr)]
                );
            }
        }
        return this;
    }

    /**
     * Require the selected earlier activity to occupy an earlier discrete time
     * value than the selected later activity.
     *
     * The activity dimension is inferred as the unique dimension containing
     * both values. Optional correlation dimensions scope ordering independently
     * (for example, before("preop", "surgery", "patient")).
     *
     * This is the most direct accessibility constructor in the current API:
     * selected later-activity worlds must be reachable only after the selected
     * earlier activity's end. Invalid edges become binary exclusion clauses.
     */
    SpaceTime before(
        string earlierActivity,
        string laterActivity,
        string[] correlateBy...
    ) {
        ensureBuilt();
        const activityDimension = inferActivityDimension(
            earlierActivity,
            laterActivity
        );
        foreach (dimension; correlateBy) {
            requireDimension(dimension);
            if (
                dimension == activityDimension ||
                dimension == _timeDimensionName
            ) {
                throw new ModelException(
                    "before() correlation dimensions cannot be the activity " ~
                    "or time dimension"
                );
            }
        }

        string[string] semanticAttributes;
        semanticAttributes["earlier"] = earlierActivity;
        semanticAttributes["later"] = laterActivity;
        semanticAttributes["activity_dimension"] = activityDimension;
        semanticAttributes["time_dimension"] = _timeDimensionName;
        semanticAttributes["correlate_by"] = correlateBy.join(", ");
        beginSemantic(
            "before",
            earlierActivity ~ " before " ~ laterActivity,
            [
                activityDimension,
                _timeDimensionName
            ] ~ correlateBy,
            semanticAttributes
        );
        scope(exit) endSemantic();

        size_t emitted;
        foreach (leftIndex, left; inner.candidates) {
            if (left.tuple[activityDimension] != earlierActivity) {
                continue;
            }
            foreach (rightIndex, right; inner.candidates) {
                if (right.tuple[activityDimension] != laterActivity) {
                    continue;
                }
                bool correlated = true;
                foreach (dimension; correlateBy) {
                    if (left.tuple[dimension] != right.tuple[dimension]) {
                        correlated = false;
                        break;
                    }
                }
                if (!correlated) continue;

                const leftOrder = timeOrder[left.tuple[_timeDimensionName]];
                const rightOrder = timeOrder[right.tuple[_timeDimensionName]];
                const leftEnd =
                    leftOrder + cast(long) candidateDuration(left);
                if (leftEnd > rightOrder) {
                    inner.model.requireClause(
                        format(
                            "%s_before_%s_%s_%s_%s",
                            inner.spaceName,
                            earlierActivity,
                            laterActivity,
                            leftIndex,
                            rightIndex
                        ),
                        [
                            logicalNot(left.expr),
                            logicalNot(right.expr)
                        ]
                    );
                    ++emitted;
                }
            }
        }
        if (emitted == 0) {
            throw new ModelException(
                "before() found no invalid candidate pairs to constrain; " ~
                "check activity values, correlation dimensions, and time domain"
            );
        }
        return this;
    }

    package void enforceNonOverlapping(string resourceDimension) {
        ensureBuilt();
        requireDimension(resourceDimension);
        string[string] semanticAttributes;
        semanticAttributes["resource_dimension"] = resourceDimension;
        semanticAttributes["time_dimension"] = _timeDimensionName;
        beginSemantic(
            "nonOverlapping",
            "non-overlapping " ~ resourceDimension,
            [resourceDimension, _timeDimensionName],
            semanticAttributes
        );
        scope(exit) endSemantic();
        // Overlapping worlds that claim the same resource are mutually
        // incompatible. The clause ¬left ∨ ¬right forbids that pair of worlds
        // from appearing together in one satisfying valuation.
        foreach (leftIndex, left; inner.candidates) {
            foreach (rightIndex; leftIndex + 1 .. inner.candidates.length) {
                auto right = inner.candidates[rightIndex];
                if (
                    left.tuple[resourceDimension] !=
                        right.tuple[resourceDimension]
                ) {
                    continue;
                }
                if (!intervalsOverlap(left, right)) continue;
                inner.model.requireClause(
                    format(
                        "%s_%s_non_overlap_%s_%s",
                        inner.spaceName,
                        resourceDimension,
                        leftIndex,
                        rightIndex
                    ),
                    [logicalNot(left.expr), logicalNot(right.expr)]
                );
            }
        }
    }

    package void enforceCapacity(
        string resourceDimension,
        size_t limit
    ) {
        ensureBuilt();
        requireDimension(resourceDimension);
        string[string] semanticAttributes;
        semanticAttributes["resource_dimension"] = resourceDimension;
        semanticAttributes["time_dimension"] = _timeDimensionName;
        semanticAttributes["limit"] = limit.to!string;
        beginSemantic(
            "capacity",
            resourceDimension ~ " capacity " ~ limit.to!string,
            [resourceDimension, _timeDimensionName],
            semanticAttributes
        );
        scope(exit) endSemantic();
        // Capacity is a bounded valuation over each resource/time slice:
        // at most `limit` worlds occupying the slice may be true.
        foreach (resource; dimensionValues(resourceDimension)) {
            foreach (slotIndex; 0 .. timeValueCount) {
                BoolExpr[] occupying;
                foreach (candidate; inner.candidates) {
                    if (
                        candidate.tuple[resourceDimension] == resource &&
                        occupies(candidate, cast(long) slotIndex)
                    ) {
                        occupying ~= candidate.expr;
                    }
                }
                if (occupying.length > limit) {
                    inner.model.require(
                        format(
                            "%s_%s_capacity_%s_%s",
                            inner.spaceName,
                            resourceDimension,
                            resource,
                            slotIndex
                        ),
                        atMost(limit, occupying)
                    );
                }
            }
        }
    }

    SpaceTime apply(ConstraintRecipe recipe) {
        ensureBuilt();
        // Applying a recipe extends the theory; it never executes a workflow or
        // mutates the candidate frame itself.
        string[string] semanticAttributes;
        semanticAttributes["space"] = inner.spaceName;
        semanticAttributes["description"] = recipe.description;
        beginSemantic(
            "recipe",
            recipe.description.length == 0
                ? "anonymous SpaceTime recipe"
                : recipe.description,
            null,
            semanticAttributes
        );
        scope(exit) endSemantic();
        recipe.apply(this);
        return this;
    }

    void preferValue(
        string dimension,
        string value,
        double weight
    ) {
        ensureBuilt();
        requirePositiveWeight(weight);
        string resolvedDimension = dimension;
        if (resolvedDimension.length == 0) {
            foreach (candidateDimension; inner.dims) {
                if (candidateDimension.values.canFind(value)) {
                    if (resolvedDimension.length != 0) {
                        throw new ModelException(
                            "Preferred value '" ~ value ~
                            "' occurs in multiple dimensions; specify one"
                        );
                    }
                    resolvedDimension = candidateDimension.name;
                }
            }
            if (resolvedDimension.length == 0) {
                throw new ModelException(
                    "Preferred value '" ~ value ~
                    "' is not present in SpaceTime"
                );
            }
        } else {
            requireDimension(resolvedDimension);
        }

        string[string] semanticAttributes;
        semanticAttributes["dimension"] = resolvedDimension;
        semanticAttributes["value"] = value;
        semanticAttributes["weight"] = weight.to!string;
        beginSemantic(
            "prefer",
            "prefer " ~ resolvedDimension ~ "=" ~ value,
            [resolvedDimension],
            semanticAttributes
        );
        scope(exit) endSemantic();

        size_t matches;
        foreach (index, candidate; inner.candidates) {
            if (candidate.tuple[resolvedDimension] == value) {
                inner.model.preferClause(
                    format(
                        "%s_prefer_%s_%s_%s",
                        inner.spaceName,
                        resolvedDimension,
                        value,
                        index
                    ),
                    [candidate.expr],
                    weight
                );
                ++matches;
            }
        }
        if (matches == 0) {
            throw new ModelException(
                "Preferred value '" ~ value ~ "' is not present in dimension '" ~
                resolvedDimension ~ "'"
            );
        }
    }

    private void ensureNotBuilt() const {
        if (built) {
            throw new ModelException(
                "SpaceTime dimensions cannot change after build()"
            );
        }
    }

    private void beginSemantic(
        string kind,
        string label,
        string[] dimensions,
        string[string] attributes
    ) {
        auto semanticAttributes = attributes.dup;
        semanticAttributes["space"] = inner.spaceName;
        const operationId = inner.model.registerSemanticOperation(
            "spacetime",
            kind,
            label,
            dimensions,
            semanticAttributes
        );
        inner.model.enterSemanticOperation(operationId);
    }

    private void endSemantic() {
        inner.model.leaveSemanticOperation();
    }

    private void ensureBuilt() const {
        if (!built) {
            throw new ModelException(
                "Call SpaceTime.build() before adding policies"
            );
        }
    }

    private void requireDimension(string dimension) const {
        foreach (spec; inner.dims) {
            if (spec.name == dimension) return;
        }
        throw new ModelException(
            "SpaceTime '" ~ inner.spaceName ~
            "' has no dimension named '" ~ dimension ~ "'"
        );
    }

    private string[] dimensionValues(string dimension) const {
        foreach (spec; inner.dims) {
            if (spec.name == dimension) return spec.values.dup;
        }
        throw new ModelException(
            "SpaceTime has no dimension named '" ~ dimension ~ "'"
        );
    }

    private string timeValueAt(long orderedIndex) const {
        foreach (value, index; timeOrder) {
            if (index == orderedIndex) return value;
        }
        throw new ModelException("Internal SpaceTime ordering is inconsistent");
    }

    private size_t candidateDuration(
        DecisionCandidate candidate
    ) const {
        foreach (activity, duration; activityDurations) {
            const dimension = activityDimensions[activity];
            if (candidate.tuple[dimension] == activity) return duration;
        }
        return 1;
    }

    private bool occupies(
        DecisionCandidate candidate,
        long slotIndex
    ) const {
        const start = timeOrder[candidate.tuple[_timeDimensionName]];
        const finish =
            start + cast(long) candidateDuration(candidate);
        return slotIndex >= start && slotIndex < finish;
    }

    private bool intervalsOverlap(
        DecisionCandidate left,
        DecisionCandidate right
    ) const {
        const leftStart = timeOrder[left.tuple[_timeDimensionName]];
        const rightStart = timeOrder[right.tuple[_timeDimensionName]];
        const leftEnd =
            leftStart + cast(long) candidateDuration(left);
        const rightEnd =
            rightStart + cast(long) candidateDuration(right);
        return leftStart < rightEnd && rightStart < leftEnd;
    }

    private string inferValueDimension(string value) const {
        string found;
        foreach (spec; inner.dims) {
            if (
                spec.name != _timeDimensionName &&
                spec.values.canFind(value)
            ) {
                if (found.length != 0) {
                    throw new ModelException(
                        "Value '" ~ value ~
                        "' occurs in multiple dimensions"
                    );
                }
                found = spec.name;
            }
        }
        if (found.length == 0) {
            throw new ModelException(
                "No SpaceTime dimension contains value '" ~ value ~ "'"
            );
        }
        return found;
    }

    private string inferActivityDimension(
        string earlier,
        string later
    ) const {
        string found;
        foreach (spec; inner.dims) {
            if (
                spec.name != _timeDimensionName &&
                spec.values.canFind(earlier) &&
                spec.values.canFind(later)
            ) {
                if (found.length != 0) {
                    throw new ModelException(
                        "Activity values occur in multiple dimensions; use " ~
                        "unique activity values"
                    );
                }
                found = spec.name;
            }
        }
        if (found.length == 0) {
            throw new ModelException(
                "Could not infer an activity dimension containing both '" ~
                earlier ~ "' and '" ~ later ~ "'"
            );
        }
        return found;
    }
}

/**
 * Compile-time checked facade. Dimensions are declared in the type and every
 * templated dimension/group operation verifies membership with static assert.
 *
 * The D type checker therefore validates the vocabulary used to name worlds
 * before Navokoj performs finite-model compilation.
 */
final class TypedSpaceTime(Dimensions...) {
    private SpaceTime inner;
    private bool[string] configured;

    this(Model model, string name) {
        static assert(
            Dimensions.length > 0,
            "TypedSpaceTime needs at least one Dimension type"
        );
        static foreach (index, D; Dimensions) {
            static assert(
                __traits(compiles, D.name) &&
                    __traits(compiles, D.temporal),
                "TypedSpaceTime arguments must be Dimension types"
            );
            static foreach (otherIndex, Other; Dimensions) {
                static if (index < otherIndex) {
                    static assert(
                        D.name != Other.name,
                        "TypedSpaceTime dimension names must be unique"
                    );
                }
            }
        }
        inner = new SpaceTime(model, name);
    }

    TypedSpaceTime dimension(D, R)(R values) {
        static assert(
            staticIndexOf!(D, Dimensions) >= 0,
            "Dimension is not declared by this TypedSpaceTime"
        );
        static assert(!D.temporal, "Use time!D for a TimeDimension");
        ensureUnconfigured!D();
        inner.dimension(D.name, stringValues(values));
        configured[D.name] = true;
        return this;
    }

    TypedSpaceTime time(D, R)(R values) {
        static assert(
            staticIndexOf!(D, Dimensions) >= 0,
            "Time dimension is not declared by this TypedSpaceTime"
        );
        static assert(D.temporal, "time!D requires a TimeDimension");
        ensureUnconfigured!D();
        inner.time(D.name, stringValues(values));
        configured[D.name] = true;
        return this;
    }

    TypedSpaceTime build() {
        static foreach (D; Dimensions) {
            if ((D.name in configured) is null) {
                throw new ModelException(
                    "Declared dimension '" ~ D.name ~
                    "' has no configured values"
                );
            }
        }
        inner.build();
        return this;
    }

    DecisionGroup groupBy(GroupDimensions...)() {
        string[] names;
        static foreach (D; GroupDimensions) {
            static assert(
                staticIndexOf!(D, Dimensions) >= 0,
                "groupBy dimension is not declared by this TypedSpaceTime"
            );
            names ~= D.name;
        }
        static assert(
            GroupDimensions.length > 0,
            "groupBy needs at least one dimension"
        );
        return inner.groupBy(names);
    }

    LogicalPlan explainPlan() {
        return inner.explainPlan();
    }

    PhysicalPlan explainPhysical() {
        return inner.explainPhysical();
    }

    TypedSpaceTime within(ResourceDimension)(TimeWindow window) {
        static assert(
            staticIndexOf!(ResourceDimension, Dimensions) >= 0,
            "within resource is not declared by this TypedSpaceTime"
        );
        inner.within(ResourceDimension.name, window);
        return this;
    }

    TypedSpaceTime duration(ActivityDimension)(
        ActivityDimension.Value activity,
        size_t occupiedSlots
    ) {
        static assert(
            staticIndexOf!(ActivityDimension, Dimensions) >= 0,
            "duration activity is not declared by this TypedSpaceTime"
        );
        static assert(
            !ActivityDimension.temporal,
            "duration applies to an activity dimension, not time itself"
        );
        inner.duration(activity.to!string, occupiedSlots);
        return this;
    }

    TypedSpaceTime before(
        string earlier,
        string later,
        string[] correlateBy...
    ) {
        inner.before(earlier, later, correlateBy);
        return this;
    }

    TypedSpaceTime apply(ConstraintRecipe recipe) {
        inner.apply(recipe);
        return this;
    }

    @property SpaceTime runtime() {
        return inner;
    }

    private void ensureUnconfigured(D)() {
        if ((D.name in configured) !is null) {
            throw new ModelException(
                "Dimension '" ~ D.name ~ "' is already configured"
            );
        }
    }
}

SpaceTime spaceTime(Model model, string name) {
    return new SpaceTime(model, name);
}

TypedSpaceTime!Dimensions spaceTime(Dimensions...)(
    Model model,
    string name
) if (Dimensions.length > 0) {
    return new TypedSpaceTime!Dimensions(model, name);
}