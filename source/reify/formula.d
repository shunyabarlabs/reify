// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.formula;

import reify.compiler : CompileOptions, CompiledModel;
import compilerModule = reify.compiler;
import reify.errors : ModelException;
import reify.model;

import std.array : join;
import std.bigint : BigInt;
import std.conv : to;
import std.format : format;

/**
 * Relation used by the low-level pseudo-Boolean compatibility layer.
 */
enum LinearRelation {
    less,
    lessEqual,
    equal,
    notEqual,
    greaterEqual,
    greater
}

/**
 * One integer-weighted Boolean literal.
 *
 * Literals use DIMACS numbering: `1` is the first variable and `-1`
 * is its negation.
 */
struct WeightedLiteral {
    long coefficient;
    int literal;
}

/**
 * External value numbering used by a compact binary mapping.
 */
enum BinaryValueBase : size_t {
    zero = 0,
    one = 1
}

/**
 * Order in which bit variables receive consecutive DIMACS IDs.
 *
 * Public bit positions remain mathematical positions: position zero is the
 * least-significant bit regardless of allocation order.
 */
enum BinaryBitOrder {
    mostSignificantFirst,
    leastSignificantFirst
}

/**
 * Construction policy for a binary mapping.
 *
 * Defaults follow the common formula-generator convention: zero-based values,
 * most-significant-bit-first variable IDs, and no implicit range clauses.
 */
struct BinaryMappingOptions {
    BinaryValueBase valueBase = BinaryValueBase.zero;
    BinaryBitOrder bitOrder = BinaryBitOrder.mostSignificantFirst;
    bool enforceDeclaredRange = false;

    static BinaryMappingOptions standard() {
        return BinaryMappingOptions(
            BinaryValueBase.zero,
            BinaryBitOrder.mostSignificantFirst,
            false
        );
    }

    static BinaryMappingOptions cnfgenCompatible() {
        return standard();
    }

    /**
     * The one-based, least-significant-bit-first policy used by the initial
     * Navokoj prototype.
     */
    static BinaryMappingOptions legacyOneBased() {
        return BinaryMappingOptions(
            BinaryValueBase.one,
            BinaryBitOrder.leastSignificantFirst,
            true
        );
    }
}

struct FormulaLimits {
    size_t maxVariables = 1_000_000;
    size_t maxClauses = 5_000_000;
    size_t maxLiterals = 50_000_000;
    size_t maxIndexedTuples = 1_000_000;
    size_t maxIndexArity = 64;
    size_t maxPseudoBooleanTerms = 10_000;
}

/**
 * A dense, one-based, row-major block of Boolean variables.
 *
 * This mirrors the variable blocks used by formula generators while keeping
 * labels and assignments attached to the normal Navokoj Model.
 */
final class VariableBlock {
    private CnfFormula owner;
    private int firstVariable;
    private size_t[] shape;

    package this(
        CnfFormula owner,
        int firstVariable,
        const(size_t)[] shape
    ) {
        this.owner = owner;
        this.firstVariable = firstVariable;
        this.shape = shape.dup;
    }

    size_t dimensions() const {
        return shape.length;
    }

    size_t[] ranges() const {
        return shape.dup;
    }

    size_t length() const {
        size_t result = 1;
        foreach (extent; shape) {
            if (extent == 0) {
                return 0;
            }
            result *= extent;
        }
        return result;
    }

    int at(const(size_t)[] indices) const {
        if (indices.length != shape.length) {
            throw new ModelException(format(
                "Variable block expects %s indices, received %s",
                shape.length,
                indices.length
            ));
        }

        size_t flat;
        foreach (axis, index; indices) {
            if (index == 0 || index > shape[axis]) {
                throw new ModelException(format(
                    "Index %s on axis %s is outside 1..%s",
                    index,
                    axis + 1,
                    shape[axis]
                ));
            }
            flat = checkedBlockProduct(flat, shape[axis]);
            flat += index - 1;
        }
        if (flat > cast(size_t) int.max - cast(size_t) firstVariable) {
            throw new ModelException("Variable block index exceeds DIMACS range");
        }
        return firstVariable + cast(int) flat;
    }

    int opCall(size_t first) const {
        return at([first]);
    }

    int opCall(size_t first, size_t second) const {
        return at([first, second]);
    }

    int opCall(size_t first, size_t second, size_t third) const {
        return at([first, second, third]);
    }

    int opCall(
        size_t first,
        size_t second,
        size_t third,
        size_t fourth
    ) const {
        return at([first, second, third, fourth]);
    }

    size_t[] toIndex(int literal) const {
        const variable = checkedVariableId(literal);
        if (
            variable < firstVariable ||
            cast(size_t) (variable - firstVariable) >= length
        ) {
            throw new ModelException(
                "Literal does not belong to this variable block"
            );
        }

        size_t residue = cast(size_t) (variable - firstVariable);
        auto result = new size_t[](shape.length);
        for (size_t axis = shape.length; axis > 0; --axis) {
            const extent = shape[axis - 1];
            result[axis - 1] = residue % extent + 1;
            residue /= extent;
        }
        return result;
    }

    /**
     * Select IDs matching a one-based pattern. Zero is a wildcard.
     */
    int[] select(const(long)[] pattern) const {
        if (pattern.length != shape.length) {
            throw new ModelException(format(
                "Variable block projection expects %s axes, received %s",
                shape.length,
                pattern.length
            ));
        }

        int[] result;
        foreach (offset; 0 .. length) {
            const variable = firstVariable + cast(int) offset;
            auto indices = toIndex(variable);
            bool matches = true;
            foreach (axis, requested; pattern) {
                if (
                    requested != 0 &&
                    requested != cast(long) indices[axis]
                ) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                result ~= variable;
            }
        }
        return result;
    }

    int[] variables() const {
        int[] result;
        foreach (offset; 0 .. length) {
            result ~= firstVariable + cast(int) offset;
        }
        return result;
    }
}

/**
 * A sparse group indexed by explicit positive integer tuples.
 *
 * It covers graph edges, sparse mappings, combinations, permutations, and
 * words without coupling the solver layer to one graph library.
 */
final class IndexedVariableGroup {
    private CnfFormula owner;
    private int[string] variablesByTuple;
    private long[][] tuplesByOffset;
    private int firstVariable;

    package this(
        CnfFormula owner,
        int firstVariable,
        long[][] tuples,
        int[string] variablesByTuple
    ) {
        this.owner = owner;
        this.firstVariable = firstVariable;
        this.tuplesByOffset = tuples;
        this.variablesByTuple = variablesByTuple;
    }

    size_t length() const {
        return tuplesByOffset.length;
    }

    int at(const(long)[] indices) const {
        auto found = tupleKey(indices) in variablesByTuple;
        if (found is null) {
            throw new ModelException(
                "Unknown sparse variable index (" ~
                tupleDisplay(indices) ~ ")"
            );
        }
        return *found;
    }

    int opCall(long first) const {
        return at([first]);
    }

    int opCall(long first, long second) const {
        return at([first, second]);
    }

    int opCall(long first, long second, long third) const {
        return at([first, second, third]);
    }

    int opCall(long first, long second, long third, long fourth) const {
        return at([first, second, third, fourth]);
    }

    long[] toIndex(int literal) const {
        const variable = checkedVariableId(literal);
        const offset = variable - firstVariable;
        if (
            offset < 0 ||
            cast(size_t) offset >= tuplesByOffset.length
        ) {
            throw new ModelException(
                "Literal does not belong to this indexed variable group"
            );
        }
        return tuplesByOffset[offset].dup;
    }

    /**
     * Select IDs matching a tuple pattern. Zero is a wildcard.
     */
    int[] select(const(long)[] pattern) const {
        int[] result;
        foreach (offset, tuple; tuplesByOffset) {
            if (tuple.length != pattern.length) {
                continue;
            }
            bool matches = true;
            foreach (axis, requested; pattern) {
                if (requested != 0 && requested != tuple[axis]) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                result ~= firstVariable + cast(int) offset;
            }
        }
        return result;
    }

    int[] variables() const {
        int[] result;
        foreach (offset; 0 .. tuplesByOffset.length) {
            result ~= firstVariable + cast(int) offset;
        }
        return result;
    }

    long[][] indices() const {
        long[][] result;
        foreach (tuple; tuplesByOffset) {
            result ~= tuple.dup;
        }
        return result;
    }
}

/**
 * A sparse unary mapping with explicit ordered domain and range sets.
 *
 * Keeping both sides independently from the edge variables preserves isolated
 * values, which is necessary for complete and surjective constraints.
 */
final class SparseMapping {
    private CnfFormula owner;
    private IndexedVariableGroup storage;
    private long[] domainValues;
    private long[] rangeValues;
    private bool[long] domainLookup;
    private bool[long] rangeLookup;

    package this(
        CnfFormula owner,
        IndexedVariableGroup storage,
        const(long)[] domainValues,
        const(long)[] rangeValues
    ) {
        this.owner = owner;
        this.storage = storage;
        this.domainValues = domainValues.dup;
        this.rangeValues = rangeValues.dup;
        foreach (value; domainValues) {
            domainLookup[value] = true;
        }
        foreach (value; rangeValues) {
            rangeLookup[value] = true;
        }
    }

    size_t length() const {
        return storage.length;
    }

    long[] domain() const {
        return domainValues.dup;
    }

    long[] range() const {
        return rangeValues.dup;
    }

    int at(long domainValue, long rangeValue) const {
        ensureSparseSideValue(domainLookup, domainValue, "domain");
        ensureSparseSideValue(rangeLookup, rangeValue, "range");
        return storage.at([domainValue, rangeValue]);
    }

    int opCall(long domainValue, long rangeValue) const {
        return at(domainValue, rangeValue);
    }

    bool hasEdge(long domainValue, long rangeValue) const {
        if (
            (domainValue in domainLookup) is null ||
            (rangeValue in rangeLookup) is null
        ) {
            return false;
        }
        return (tupleKey([domainValue, rangeValue]) in
            storage.variablesByTuple) !is null;
    }

    int[] imagesOf(long domainValue) const {
        ensureSparseSideValue(domainLookup, domainValue, "domain");
        return storage.select([domainValue, 0]);
    }

    int[] preimagesOf(long rangeValue) const {
        ensureSparseSideValue(rangeLookup, rangeValue, "range");
        return storage.select([0, rangeValue]);
    }

    int[] variables() const {
        return storage.variables;
    }

    long[][] edges() const {
        return storage.indices;
    }
}

/**
 * A compact Boolean encoding of a finite mapping.
 */
final class BinaryMapping {
    private VariableBlock storage;
    private size_t domainSize;
    private size_t rangeSize;
    private size_t bitCount;
    private BinaryMappingOptions options;

    package this(
        VariableBlock storage,
        size_t domainSize,
        size_t rangeSize,
        size_t bitCount,
        BinaryMappingOptions options
    ) {
        this.storage = storage;
        this.domainSize = domainSize;
        this.rangeSize = rangeSize;
        this.bitCount = bitCount;
        this.options = options;
    }

    /**
     * Return the variable for a mathematical bit position.
     *
     * Position zero is always the least-significant bit. Allocation order is
     * controlled independently by `bitOrder`.
     */
    int bit(size_t domainIndex, size_t bitPosition) const {
        if (bitPosition >= bitCount) {
            throw new ModelException("Binary mapping bit position is outside its domain");
        }
        const storageIndex =
            options.bitOrder == BinaryBitOrder.mostSignificantFirst
                ? bitCount - bitPosition
                : bitPosition + 1;
        return storage(domainIndex, storageIndex);
    }

    /**
     * Return a bit variable by its one-based allocation ordinal.
     */
    int storageBit(size_t domainIndex, size_t ordinal) const {
        return storage(domainIndex, ordinal);
    }

    /**
     * Return the clause which forbids `domainIndex -> value`.
     *
     * Values outside the declared range but inside the bit capacity are
     * accepted so `forceCompleteMapping` can exclude them explicitly.
     */
    int[] forbid(size_t domainIndex, size_t value) const {
        if (
            domainIndex == 0 ||
            domainIndex > domainSize
        ) {
            throw new ModelException("Binary mapping index is outside its domain");
        }
        const base = valueBase;
        if (value < base) {
            throw new ModelException(
                "Binary mapping value is below its configured base"
            );
        }
        const code = value - base;
        if (code >= capacity) {
            throw new ModelException(
                "Binary mapping value exceeds its bit representation"
            );
        }

        int[] clause;
        foreach (ordinal; 1 .. bitCount + 1) {
            const bitPosition =
                options.bitOrder == BinaryBitOrder.mostSignificantFirst
                    ? bitCount - ordinal
                    : ordinal - 1;
            const variable = storage(domainIndex, ordinal);
            const selected =
                (code & (cast(size_t) 1 << bitPosition)) != 0;
            clause ~= selected ? -variable : variable;
        }
        return clause;
    }

    size_t domain() const {
        return domainSize;
    }

    size_t range() const {
        return rangeSize;
    }

    size_t bitsPerValue() const {
        return bitCount;
    }

    size_t valueBase() const {
        return cast(size_t) options.valueBase;
    }

    size_t firstValue() const {
        return valueBase;
    }

    size_t lastValue() const {
        return valueBase + rangeSize - 1;
    }

    size_t capacity() const {
        return cast(size_t) 1 << bitCount;
    }

    BinaryBitOrder bitOrder() const {
        return options.bitOrder;
    }

    BinaryMappingOptions policy() const {
        return options;
    }
}

/**
 * Low-level formula-builder facade for ports of CNFgen-style generators.
 *
 * It uses exact DIMACS literals at the surface but compiles through the same
 * Model, API client, hydration, and local verification pipeline as domain
 * models.
 */
final class CnfFormula {
    private Model _model;
    private BoolExpr[] booleanExpressions;
    private string[] variableLabels;
    private string[] decisionNames;
    private size_t clauseSequence;
    private size_t constraintSequence;
    private size_t rawLiteralCount;
    private FormulaLimits limits;

    this(
        string name = "cnf-formula",
        FormulaLimits limits = FormulaLimits()
    ) {
        if (
            limits.maxVariables > int.max ||
            limits.maxVariables == 0 ||
            limits.maxClauses == 0 ||
            limits.maxLiterals == 0 ||
            limits.maxIndexedTuples == 0 ||
            limits.maxIndexArity == 0 ||
            limits.maxPseudoBooleanTerms == 0
        ) {
            throw new ModelException(
                "Formula limits must be positive and maxVariables cannot " ~
                "exceed int.max"
            );
        }
        _model = new Model(name);
        this.limits = limits;
    }

    package Model internalModel() {
        return _model;
    }

    size_t numberOfVariables() const {
        return booleanExpressions.length;
    }

    int newVariable(string label = "") {
        if (booleanExpressions.length >= limits.maxVariables) {
            throw new ModelException(
                "Formula exceeds its configured variable limit"
            );
        }
        const id = cast(int) booleanExpressions.length + 1;
        string requestedLabel = label.length == 0
            ? "x" ~ id.to!string
            : label;
        string resolvedLabel = requestedLabel;
        size_t suffix = id;
        while (_model.hasVariable(resolvedLabel)) {
            resolvedLabel =
                requestedLabel ~ "#" ~ suffix.to!string;
            ++suffix;
        }
        booleanExpressions ~= _model.booleanVar(resolvedLabel);
        // VarId is the identity. Labels are metadata and need not be unique.
        variableLabels ~= requestedLabel;
        decisionNames ~= resolvedLabel;
        return id;
    }

    string labelOf(int literal) const {
        const id = checkedVariableId(literal);
        validateKnownVariable(id);
        return variableLabels[id - 1];
    }

    /**
     * Return the unique key used in hydrated Solution objects.
     *
     * It differs from `labelOf` only when optional source labels collide.
     */
    string decisionNameOf(int literal) const {
        const id = checkedVariableId(literal);
        validateKnownVariable(id);
        return decisionNames[id - 1];
    }

    VariableBlock newBlock(
        string labelPrefix,
        const(size_t)[] dimensions
    ) {
        if (dimensions.length == 0) {
            throw new ModelException(
                "A variable block needs at least one dimension"
            );
        }
        if (dimensions.length > limits.maxIndexArity) {
            throw new ModelException(
                "Variable block exceeds the configured index arity"
            );
        }

        size_t count = 1;
        foreach (extent; dimensions) {
            count = checkedBlockProduct(count, extent);
        }
        if (
            count > limits.maxVariables - booleanExpressions.length
        ) {
            throw new ModelException(
                "Variable block exceeds DIMACS variable range"
            );
        }

        const first = cast(int) booleanExpressions.length + 1;
        auto block = new VariableBlock(this, first, dimensions);
        foreach (offset; 0 .. count) {
            auto index = block.toIndex(first + cast(int) offset);
            newVariable(blockLabel(labelPrefix, index));
        }
        return block;
    }

    VariableBlock newBlock(string labelPrefix, size_t first) {
        return newBlock(labelPrefix, [first]);
    }

    VariableBlock newBlock(
        string labelPrefix,
        size_t first,
        size_t second
    ) {
        return newBlock(labelPrefix, [first, second]);
    }

    VariableBlock newBlock(
        string labelPrefix,
        size_t first,
        size_t second,
        size_t third
    ) {
        return newBlock(labelPrefix, [first, second, third]);
    }

    VariableBlock newMapping(
        string labelPrefix,
        size_t domainSize,
        size_t rangeSize
    ) {
        return newBlock(labelPrefix, domainSize, rangeSize);
    }

    SparseMapping newSparseMapping(
        string labelPrefix,
        const(long)[] domainValues,
        const(long)[] rangeValues,
        long[][] edges
    ) {
        validateSparseSide(
            domainValues,
            limits.maxIndexedTuples,
            "domain"
        );
        validateSparseSide(
            rangeValues,
            limits.maxIndexedTuples,
            "range"
        );

        bool[long] domainLookup;
        bool[long] rangeLookup;
        foreach (value; domainValues) {
            domainLookup[value] = true;
        }
        foreach (value; rangeValues) {
            rangeLookup[value] = true;
        }
        foreach (edge; edges) {
            if (edge.length != 2) {
                throw new ModelException(
                    "Sparse mapping edges must contain one domain and one " ~
                    "range value"
                );
            }
            if (
                (edge[0] in domainLookup) is null ||
                (edge[1] in rangeLookup) is null
            ) {
                throw new ModelException(format(
                    "Sparse mapping edge (%s) references a value outside its " ~
                    "declared sides",
                    tupleDisplay(edge)
                ));
            }
        }

        auto indexed = newIndexedGroup(labelPrefix, edges);
        return new SparseMapping(
            this,
            indexed,
            domainValues,
            rangeValues
        );
    }

    SparseMapping newSparseMapping(
        string labelPrefix,
        size_t domainSize,
        size_t rangeSize,
        long[][] edges
    ) {
        if (
            domainSize > limits.maxIndexedTuples ||
            rangeSize > limits.maxIndexedTuples ||
            domainSize > cast(size_t) long.max ||
            rangeSize > cast(size_t) long.max
        ) {
            throw new ModelException(
                "Sparse mapping sides exceed their configured size limit"
            );
        }
        return newSparseMapping(
            labelPrefix,
            oneBasedValues(domainSize),
            oneBasedValues(rangeSize),
            edges
        );
    }

    IndexedVariableGroup newIndexedGroup(
        string labelPrefix,
        long[][] tuples
    ) {
        if (tuples.length > limits.maxIndexedTuples) {
            throw new ModelException(
                "Indexed group exceeds its configured tuple limit"
            );
        }
        if (
            tuples.length >
            limits.maxVariables - booleanExpressions.length
        ) {
            throw new ModelException(
                "Indexed group exceeds its configured variable limit"
            );
        }

        // Validate the whole group before committing any variables so a bad
        // late tuple cannot leave the formula partially mutated.
        bool[string] seen;
        foreach (tuple; tuples) {
            if (tuple.length > limits.maxIndexArity) {
                throw new ModelException(
                    "Indexed tuple exceeds the configured arity"
                );
            }
            foreach (index; tuple) {
                if (index <= 0) {
                    throw new ModelException(
                        "Indexed variable coordinates must be positive"
                    );
                }
            }
            const key = tupleKey(tuple);
            if ((key in seen) !is null) {
                throw new ModelException(
                    "Duplicate indexed variable tuple (" ~
                    tupleDisplay(tuple) ~ ")"
                );
            }
            seen[key] = true;
        }

        int[string] lookup;
        long[][] copied;
        const first = booleanExpressions.length < limits.maxVariables
            ? cast(int) booleanExpressions.length + 1
            : cast(int) limits.maxVariables;
        foreach (tuple; tuples) {
            const key = tupleKey(tuple);
            const id = newVariable(
                labelPrefix ~ "[" ~ tupleDisplay(tuple) ~ "]"
            );
            lookup[key] = id;
            copied ~= tuple.dup;
        }
        return new IndexedVariableGroup(this, first, copied, lookup);
    }

    IndexedVariableGroup newCombinations(
        string labelPrefix,
        size_t n,
        size_t k
    ) {
        if (k > n) {
            throw new ModelException("Combination size cannot exceed n");
        }
        validateCombinatorialArity(k);
        ensureCoordinateRange(n, k);
        ensureCombinatorialCount(
            cappedBinomial(n, k, availableIndexedCapacity()),
            "Combination group"
        );
        long[][] tuples;
        long[] current;
        appendCombinations(
            tuples,
            current,
            1,
            n,
            k,
            false,
            limits.maxIndexedTuples
        );
        return newIndexedGroup(labelPrefix, tuples);
    }

    IndexedVariableGroup newCombinationsWithReplacement(
        string labelPrefix,
        size_t n,
        size_t k
    ) {
        validateCombinatorialArity(k);
        ensureCoordinateRange(n, k);
        size_t count;
        if (k == 0) {
            count = 1;
        } else if (n == 0) {
            count = 0;
        } else {
            if (n > size_t.max - (k - 1)) {
                throw new ModelException(
                    "Combination-with-replacement parameters overflow size_t"
                );
            }
            count = cappedBinomial(
                n + k - 1,
                k,
                availableIndexedCapacity()
            );
        }
        ensureCombinatorialCount(
            count,
            "Combination-with-replacement group"
        );
        long[][] tuples;
        long[] current;
        appendCombinations(
            tuples,
            current,
            1,
            n,
            k,
            true,
            limits.maxIndexedTuples
        );
        return newIndexedGroup(labelPrefix, tuples);
    }

    IndexedVariableGroup newPermutations(
        string labelPrefix,
        size_t n,
        size_t k
    ) {
        if (k > n) {
            throw new ModelException("Permutation size cannot exceed n");
        }
        validateCombinatorialArity(k);
        ensureCoordinateRange(n, k);
        ensureCombinatorialCount(
            cappedFallingFactorial(n, k, availableIndexedCapacity()),
            "Permutation group"
        );
        long[][] tuples;
        long[] current;
        bool[] used;
        if (k != 0) {
            used = new bool[](n + 1);
        }
        appendWords(
            tuples,
            current,
            used,
            n,
            k,
            false,
            limits.maxIndexedTuples
        );
        return newIndexedGroup(labelPrefix, tuples);
    }

    IndexedVariableGroup newWords(
        string labelPrefix,
        size_t n,
        size_t k
    ) {
        validateCombinatorialArity(k);
        ensureCoordinateRange(n, k);
        ensureCombinatorialCount(
            cappedPower(n, k, availableIndexedCapacity()),
            "Word group"
        );
        long[][] tuples;
        long[] current;
        bool[] unused;
        appendWords(
            tuples,
            current,
            unused,
            n,
            k,
            true,
            limits.maxIndexedTuples
        );
        return newIndexedGroup(labelPrefix, tuples);
    }

    BinaryMapping newBinaryMapping(
        string labelPrefix,
        size_t domainSize,
        size_t rangeSize
    ) {
        return newBinaryMapping(
            labelPrefix,
            domainSize,
            rangeSize,
            BinaryMappingOptions.standard()
        );
    }

    BinaryMapping newBinaryMapping(
        string labelPrefix,
        size_t domainSize,
        size_t rangeSize,
        BinaryMappingOptions options
    ) {
        if (domainSize == 0 || rangeSize == 0) {
            throw new ModelException(
                "Binary mappings need positive domain and range sizes"
            );
        }
        if (
            domainSize > limits.maxIndexedTuples ||
            rangeSize > limits.maxIndexedTuples
        ) {
            throw new ModelException(
                "Binary mapping sides exceed their configured size limit"
            );
        }
        if (
            (
                options.valueBase != BinaryValueBase.zero &&
                options.valueBase != BinaryValueBase.one
            ) ||
            (
                options.bitOrder != BinaryBitOrder.mostSignificantFirst &&
                options.bitOrder != BinaryBitOrder.leastSignificantFirst
            )
        ) {
            throw new ModelException("Binary mapping policy is invalid");
        }

        size_t bits;
        size_t capacity = 1;
        while (capacity < rangeSize) {
            if (bits >= size_t.sizeof * 8 - 1) {
                throw new ModelException(
                    "Binary mapping range is too large"
                );
            }
            capacity *= 2;
            ++bits;
        }
        if (options.enforceDeclaredRange) {
            const invalidValues = capacity - rangeSize;
            const addedClauses =
                BigInt(domainSize) * BigInt(invalidValues);
            preflightRawAddition(
                addedClauses,
                addedClauses * BigInt(bits),
                "Binary mapping range constraints"
            );
        }

        // A singleton range has no information bits. Keep a zero-width block
        // so the mapping still has a uniform representation.
        auto storage = newBlock(labelPrefix, [domainSize, bits]);
        auto mapping = new BinaryMapping(
            storage,
            domainSize,
            rangeSize,
            bits,
            options
        );
        if (options.enforceDeclaredRange) {
            forceCompleteMapping(mapping);
        }
        return mapping;
    }

    /**
     * Explicit constructor retaining the initial one-based Navokoj policy.
     */
    BinaryMapping newLegacyBinaryMapping(
        string labelPrefix,
        size_t domainSize,
        size_t rangeSize
    ) {
        return newBinaryMapping(
            labelPrefix,
            domainSize,
            rangeSize,
            BinaryMappingOptions.legacyOneBased()
        );
    }

    void addClause(int[] literals, string name = "") {
        if (clauseSequence >= limits.maxClauses) {
            throw new ModelException(
                "Formula exceeds its configured clause limit"
            );
        }
        if (
            literals.length > limits.maxLiterals ||
            rawLiteralCount > limits.maxLiterals - literals.length
        ) {
            throw new ModelException(
                "Formula exceeds its configured raw-literal limit"
            );
        }
        BoolExpr[] expressions;
        foreach (literal; literals) {
            const id = checkedVariableId(literal);
            validateKnownVariable(id);
            auto expression = booleanExpressions[id - 1];
            expressions ~= literal > 0
                ? expression
                : logicalNot(expression);
        }

        ++clauseSequence;
        rawLiteralCount += literals.length;
        const resolvedName = name.length == 0
            ? "$clause:" ~ clauseSequence.to!string
            : name;
        _model.requireClause(resolvedName, expressions);
    }

    void addClauses(int[][] clauses) {
        foreach (clause; clauses) {
            addClause(clause);
        }
    }

    void addParity(int[] literals, int target, string name = "") {
        if (target != 0 && target != 1) {
            throw new ModelException("Parity target must be zero or one");
        }

        bool[int] active;
        int[] order;
        foreach (literal; literals) {
            const id = checkedVariableId(literal);
            validateKnownVariable(id);
            if (literal < 0) {
                target ^= 1;
            }
            auto found = id in active;
            if (found is null) {
                active[id] = true;
                order ~= id;
            } else {
                *found = !*found;
            }
        }

        BoolExpr[] variables;
        foreach (id; order) {
            if (active[id]) {
                variables ~= booleanExpressions[id - 1];
            }
        }
        const resolvedName = nextConstraintName(name, "$parity:");
        if (variables.length == 0) {
            if (target != 0) {
                addClause([], resolvedName);
            }
            return;
        }
        _model.parity(resolvedName, variables, target);
    }

    void addLinear(
        int[] literals,
        LinearRelation relation,
        long rightHandSide,
        string name = ""
    ) {
        WeightedLiteral[] terms;
        foreach (literal; literals) {
            terms ~= WeightedLiteral(1, literal);
        }
        addPseudoBoolean(terms, relation, rightHandSide, name);
    }

    void cardinalityAtMost(
        int[] literals,
        long count,
        string name = ""
    ) {
        addLinear(literals, LinearRelation.lessEqual, count, name);
    }

    void cardinalityAtLeast(
        int[] literals,
        long count,
        string name = ""
    ) {
        addLinear(literals, LinearRelation.greaterEqual, count, name);
    }

    void cardinalityExactly(
        int[] literals,
        long count,
        string name = ""
    ) {
        addLinear(literals, LinearRelation.equal, count, name);
    }

    void cardinalityAnythingBut(
        int[] literals,
        long count,
        string name = ""
    ) {
        addLinear(literals, LinearRelation.notEqual, count, name);
    }

    void looseMajority(int[] literals, string name = "") {
        cardinalityAtLeast(
            literals,
            cast(long) (literals.length + 1) / 2,
            name
        );
    }

    void strictMajority(int[] literals, string name = "") {
        cardinalityAtLeast(
            literals,
            cast(long) literals.length / 2 + 1,
            name
        );
    }

    void looseMinority(int[] literals, string name = "") {
        cardinalityAtMost(
            literals,
            cast(long) literals.length / 2,
            name
        );
    }

    void strictMinority(int[] literals, string name = "") {
        cardinalityAtMost(
            literals,
            literals.length == 0
                ? -1
                : cast(long) (literals.length - 1) / 2,
            name
        );
    }

    void addPseudoBoolean(
        WeightedLiteral[] terms,
        LinearRelation relation,
        long rightHandSide,
        string name = ""
    ) {
        if (terms.length > limits.maxPseudoBooleanTerms) {
            throw new ModelException(
                "Pseudo-Boolean expression exceeds its configured term limit"
            );
        }
        auto expression = weightedExpression(terms);
        auto right = integer(rightHandSide);
        BoolExpr predicate;
        final switch (relation) {
            case LinearRelation.less:
                predicate = reify.model.lessThan(expression, right);
                break;
            case LinearRelation.lessEqual:
                predicate = reify.model.lessEqual(expression, right);
                break;
            case LinearRelation.equal:
                predicate = reify.model.equal(expression, right);
                break;
            case LinearRelation.notEqual:
                predicate = reify.model.notEqual(expression, right);
                break;
            case LinearRelation.greaterEqual:
                predicate = reify.model.greaterEqual(expression, right);
                break;
            case LinearRelation.greater:
                predicate = reify.model.greaterThan(expression, right);
                break;
        }
        _model.require(
            nextConstraintName(name, "$linear:"),
            predicate
        );
    }

    void maximize(
        string name,
        WeightedLiteral[] terms,
        int priority = 0
    ) {
        _model.maximize(name, weightedExpression(terms), priority);
    }

    void minimize(
        string name,
        WeightedLiteral[] terms,
        int priority = 0
    ) {
        _model.minimize(name, weightedExpression(terms), priority);
    }

    void forceCompleteMapping(VariableBlock mapping) {
        auto shape = validateMapping(this, mapping);
        foreach (domainIndex; 1 .. shape[0] + 1) {
            addClause(
                mapping.select([
                    cast(long) domainIndex,
                    0
                ]),
                "$mapping-complete:" ~ domainIndex.to!string
            );
        }
    }

    void forceFunctionalMapping(VariableBlock mapping) {
        auto shape = validateMapping(this, mapping);
        foreach (domainIndex; 1 .. shape[0] + 1) {
            foreach (left; 1 .. shape[1] + 1) {
                foreach (right; left + 1 .. shape[1] + 1) {
                    addClause([
                        -mapping(domainIndex, left),
                        -mapping(domainIndex, right)
                    ]);
                }
            }
        }
    }

    void forceSurjectiveMapping(VariableBlock mapping) {
        auto shape = validateMapping(this, mapping);
        foreach (rangeIndex; 1 .. shape[1] + 1) {
            addClause(
                mapping.select([
                    0,
                    cast(long) rangeIndex
                ]),
                "$mapping-surjective:" ~ rangeIndex.to!string
            );
        }
    }

    void forceInjectiveMapping(VariableBlock mapping) {
        auto shape = validateMapping(this, mapping);
        foreach (rangeIndex; 1 .. shape[1] + 1) {
            foreach (left; 1 .. shape[0] + 1) {
                foreach (right; left + 1 .. shape[0] + 1) {
                    addClause([
                        -mapping(left, rangeIndex),
                        -mapping(right, rangeIndex)
                    ]);
                }
            }
        }
    }

    void forceNondecreasingMapping(VariableBlock mapping) {
        auto shape = validateMapping(this, mapping);
        foreach (leftDomain; 1 .. shape[0] + 1) {
            foreach (rightDomain; leftDomain + 1 .. shape[0] + 1) {
                foreach (leftRange; 1 .. shape[1] + 1) {
                    foreach (rightRange; 1 .. leftRange) {
                        addClause([
                            -mapping(leftDomain, leftRange),
                            -mapping(rightDomain, rightRange)
                        ]);
                    }
                }
            }
        }
    }

    void forceCompleteMapping(SparseMapping mapping) {
        validateSparseMapping(this, mapping);
        preflightRawAddition(
            BigInt(mapping.domainValues.length),
            BigInt(mapping.storage.length),
            "Sparse mapping completeness"
        );
        foreach (domainValue; mapping.domainValues) {
            addClause(
                mapping.imagesOf(domainValue),
                "$sparse-complete:" ~ domainValue.to!string
            );
        }
    }

    void forceFunctionalMapping(SparseMapping mapping) {
        validateSparseMapping(this, mapping);
        BigInt addedClauses;
        foreach (domainValue; mapping.domainValues) {
            const degree = mapping.imagesOf(domainValue).length;
            addedClauses += pairCount(degree);
        }
        preflightRawAddition(
            addedClauses,
            addedClauses * 2,
            "Sparse mapping functionality"
        );

        foreach (domainValue; mapping.domainValues) {
            auto variables = mapping.imagesOf(domainValue);
            foreach (left; 0 .. variables.length) {
                foreach (right; left + 1 .. variables.length) {
                    addClause([-variables[left], -variables[right]]);
                }
            }
        }
    }

    void forceSurjectiveMapping(SparseMapping mapping) {
        validateSparseMapping(this, mapping);
        preflightRawAddition(
            BigInt(mapping.rangeValues.length),
            BigInt(mapping.storage.length),
            "Sparse mapping surjectivity"
        );
        foreach (rangeValue; mapping.rangeValues) {
            addClause(
                mapping.preimagesOf(rangeValue),
                "$sparse-surjective:" ~ rangeValue.to!string
            );
        }
    }

    void forceInjectiveMapping(SparseMapping mapping) {
        validateSparseMapping(this, mapping);
        BigInt addedClauses;
        foreach (rangeValue; mapping.rangeValues) {
            const degree = mapping.preimagesOf(rangeValue).length;
            addedClauses += pairCount(degree);
        }
        preflightRawAddition(
            addedClauses,
            addedClauses * 2,
            "Sparse mapping injectivity"
        );

        foreach (rangeValue; mapping.rangeValues) {
            auto variables = mapping.preimagesOf(rangeValue);
            foreach (left; 0 .. variables.length) {
                foreach (right; left + 1 .. variables.length) {
                    addClause([-variables[left], -variables[right]]);
                }
            }
        }
    }

    /**
     * Enforce monotonicity using the order of the explicitly supplied sides.
     */
    void forceNondecreasingMapping(SparseMapping mapping) {
        validateSparseMapping(this, mapping);
        BigInt addedClauses;
        foreach (leftDomain; 0 .. mapping.domainValues.length) {
            foreach (
                rightDomain;
                leftDomain + 1 .. mapping.domainValues.length
            ) {
                foreach (higherRange; 0 .. mapping.rangeValues.length) {
                    foreach (lowerRange; 0 .. higherRange) {
                        if (
                            mapping.hasEdge(
                                mapping.domainValues[leftDomain],
                                mapping.rangeValues[higherRange]
                            ) &&
                            mapping.hasEdge(
                                mapping.domainValues[rightDomain],
                                mapping.rangeValues[lowerRange]
                            )
                        ) {
                            ++addedClauses;
                        }
                    }
                }
            }
        }
        preflightRawAddition(
            addedClauses,
            addedClauses * 2,
            "Sparse mapping monotonicity"
        );

        foreach (leftDomain; 0 .. mapping.domainValues.length) {
            foreach (
                rightDomain;
                leftDomain + 1 .. mapping.domainValues.length
            ) {
                foreach (higherRange; 0 .. mapping.rangeValues.length) {
                    foreach (lowerRange; 0 .. higherRange) {
                        const leftValue =
                            mapping.domainValues[leftDomain];
                        const rightValue =
                            mapping.domainValues[rightDomain];
                        const highValue =
                            mapping.rangeValues[higherRange];
                        const lowValue =
                            mapping.rangeValues[lowerRange];
                        if (
                            mapping.hasEdge(leftValue, highValue) &&
                            mapping.hasEdge(rightValue, lowValue)
                        ) {
                            addClause([
                                -mapping(leftValue, highValue),
                                -mapping(rightValue, lowValue)
                            ]);
                        }
                    }
                }
            }
        }
    }

    /**
     * Exclude bit patterns which do not denote a declared mapping value.
     */
    void forceCompleteMapping(BinaryMapping mapping) {
        validateBinaryMapping(this, mapping);
        const invalidValues = mapping.capacity - mapping.rangeSize;
        const addedClauses =
            BigInt(mapping.domainSize) * BigInt(invalidValues);
        preflightRawAddition(
            addedClauses,
            addedClauses * BigInt(mapping.bitCount),
            "Binary mapping completeness"
        );

        const firstIllegal = mapping.valueBase + mapping.rangeSize;
        const pastLastCode = mapping.valueBase + mapping.capacity;
        foreach (domainIndex; 1 .. mapping.domainSize + 1) {
            foreach (value; firstIllegal .. pastLastCode) {
                addClause(
                    mapping.forbid(domainIndex, value),
                    "$binary-complete:" ~ domainIndex.to!string
                );
            }
        }
    }

    /**
     * A bit vector denotes at most one value by construction.
     */
    void forceFunctionalMapping(BinaryMapping mapping) {
        validateBinaryMapping(this, mapping);
    }

    void forceInjectiveMapping(BinaryMapping mapping) {
        validateBinaryMapping(this, mapping);
        const addedClauses =
            pairCount(mapping.domainSize) * BigInt(mapping.rangeSize);
        preflightRawAddition(
            addedClauses,
            addedClauses * BigInt(mapping.bitCount) * 2,
            "Binary mapping injectivity"
        );

        foreach (left; 1 .. mapping.domainSize + 1) {
            foreach (right; left + 1 .. mapping.domainSize + 1) {
                foreach (
                    value;
                    mapping.firstValue .. mapping.lastValue + 1
                ) {
                    addClause(
                        mapping.forbid(left, value) ~
                            mapping.forbid(right, value)
                    );
                }
            }
        }
    }

    void forceNondecreasingMapping(BinaryMapping mapping) {
        validateBinaryMapping(this, mapping);
        const addedClauses =
            pairCount(mapping.domainSize) *
            pairCount(mapping.rangeSize);
        preflightRawAddition(
            addedClauses,
            addedClauses * BigInt(mapping.bitCount) * 2,
            "Binary mapping monotonicity"
        );

        foreach (left; 1 .. mapping.domainSize + 1) {
            foreach (right; left + 1 .. mapping.domainSize + 1) {
                foreach (
                    higher;
                    mapping.firstValue .. mapping.lastValue + 1
                ) {
                    foreach (
                        lower;
                        mapping.firstValue .. higher
                    ) {
                        addClause(
                            mapping.forbid(left, higher) ~
                                mapping.forbid(right, lower)
                        );
                    }
                }
            }
        }
    }

    CompiledModel compile(CompileOptions options = CompileOptions()) {
        return compilerModule.compile(_model, options);
    }

    private IntExpr weightedExpression(WeightedLiteral[] terms) {
        if (terms.length > limits.maxPseudoBooleanTerms) {
            throw new ModelException(
                "Pseudo-Boolean expression exceeds its configured term limit"
            );
        }
        IntExpr[] expressions;
        foreach (term; terms) {
            const id = checkedVariableId(term.literal);
            validateKnownVariable(id);
            auto expression = booleanExpressions[id - 1];
            if (term.literal < 0) {
                // c * truth(!x) = c - c * truth(x). Keeping the negation out
                // of booleanAsInteger lets the affine compiler retain it as a
                // checked linear expression.
                expressions ~=
                    term.coefficient -
                    term.coefficient * asInteger(expression);
            } else {
                expressions ~=
                    term.coefficient * asInteger(expression);
            }
        }
        return balancedSum(expressions, 0, expressions.length);
    }

    private void validateKnownVariable(int id) const {
        if (id <= 0 || cast(size_t) id > booleanExpressions.length) {
            throw new ModelException(format(
                "Literal references variable %s, but the formula has %s variables",
                id,
                booleanExpressions.length
            ));
        }
    }

    private string nextConstraintName(
        string requested,
        string prefix
    ) {
        if (requested.length != 0) {
            return requested;
        }
        ++constraintSequence;
        return prefix ~ constraintSequence.to!string;
    }

    private void validateCombinatorialArity(size_t k) {
        if (k > limits.maxIndexArity) {
            throw new ModelException(
                "Combinatorial group exceeds the configured index arity"
            );
        }
    }

    private size_t availableIndexedCapacity() const {
        const variableCapacity =
            limits.maxVariables - booleanExpressions.length;
        return variableCapacity < limits.maxIndexedTuples
            ? variableCapacity
            : limits.maxIndexedTuples;
    }

    private void ensureCombinatorialCount(
        size_t count,
        string context
    ) const {
        const available = availableIndexedCapacity();
        if (count > available) {
            throw new ModelException(format(
                "%s needs more than %s variables, above the available " ~
                "formula capacity",
                context,
                available
            ));
        }
    }

    private void ensureCoordinateRange(size_t n, size_t k) const {
        if (k != 0 && n > cast(size_t) long.max) {
            throw new ModelException(
                "Combinatorial coordinates exceed the signed index range"
            );
        }
    }

    private void preflightRawAddition(
        BigInt addedClauses,
        BigInt addedLiterals,
        string context
    ) const {
        const clauseCapacity =
            BigInt(limits.maxClauses - clauseSequence);
        const literalCapacity =
            BigInt(limits.maxLiterals - rawLiteralCount);
        if (
            addedClauses > clauseCapacity ||
            addedLiterals > literalCapacity
        ) {
            throw new ModelException(
                context ~ " exceeds the configured clause/literal limits"
            );
        }
    }
}

private void validateSparseSide(
    const(long)[] values,
    size_t maximumLength,
    string sideName
) {
    if (values.length > maximumLength) {
        throw new ModelException(
            "Sparse mapping " ~ sideName ~
            " exceeds its configured size limit"
        );
    }
    bool[long] seen;
    foreach (value; values) {
        if (value <= 0) {
            throw new ModelException(
                "Sparse mapping side values must be positive"
            );
        }
        if ((value in seen) !is null) {
            throw new ModelException(format(
                "Sparse mapping %s contains duplicate value %s",
                sideName,
                value
            ));
        }
        seen[value] = true;
    }
}

private void ensureSparseSideValue(
    const(bool[long]) values,
    long requested,
    string sideName
) {
    if ((requested in values) is null) {
        throw new ModelException(format(
            "Value %s is not in the sparse mapping %s",
            requested,
            sideName
        ));
    }
}

private long[] oneBasedValues(size_t count) {
    long[] result;
    result.reserve(count);
    foreach (value; 1 .. count + 1) {
        result ~= cast(long) value;
    }
    return result;
}

private BigInt pairCount(size_t count) {
    if (count < 2) {
        return BigInt(0);
    }
    return BigInt(count) * BigInt(count - 1) / 2;
}

private size_t cappedBinomial(
    size_t n,
    size_t k,
    size_t maximum
) {
    if (k > n) {
        return 0;
    }
    auto reduced = k < n - k ? k : n - k;
    BigInt result = 1;
    const cap = BigInt(maximum);
    foreach (step; 1 .. reduced + 1) {
        result *= BigInt(n - reduced + step);
        result /= BigInt(step);
        if (result > cap) {
            return maximum + 1;
        }
    }
    return result.to!size_t;
}

private size_t cappedFallingFactorial(
    size_t n,
    size_t k,
    size_t maximum
) {
    size_t result = 1;
    foreach (offset; 0 .. k) {
        const factor = n - offset;
        if (factor != 0 && result > maximum / factor) {
            return maximum + 1;
        }
        result *= factor;
        if (result > maximum) {
            return maximum + 1;
        }
    }
    return result;
}

private size_t cappedPower(
    size_t base,
    size_t exponent,
    size_t maximum
) {
    size_t result = 1;
    foreach (_; 0 .. exponent) {
        if (base != 0 && result > maximum / base) {
            return maximum + 1;
        }
        result *= base;
        if (result > maximum) {
            return maximum + 1;
        }
    }
    return result;
}

private size_t[] validateMapping(
    CnfFormula expectedOwner,
    VariableBlock mapping
) {
    if (
        mapping is null ||
        mapping.owner !is expectedOwner ||
        mapping.dimensions != 2
    ) {
        throw new ModelException(
            "Mapping constraints require a two-dimensional variable block " ~
            "owned by the receiving formula"
        );
    }
    return mapping.ranges;
}

private void validateSparseMapping(
    CnfFormula expectedOwner,
    SparseMapping mapping
) {
    if (
        mapping is null ||
        mapping.owner !is expectedOwner ||
        mapping.storage.owner !is expectedOwner
    ) {
        throw new ModelException(
            "Sparse mapping must be owned by the receiving formula"
        );
    }
}

private void validateBinaryMapping(
    CnfFormula expectedOwner,
    BinaryMapping mapping
) {
    if (
        mapping is null ||
        mapping.storage.owner !is expectedOwner
    ) {
        throw new ModelException(
            "Binary mapping must be owned by the receiving formula"
        );
    }
}

private int checkedVariableId(int literal) {
    if (literal == 0) {
        throw new ModelException("DIMACS literal zero terminates a clause");
    }
    if (literal == int.min) {
        throw new ModelException("DIMACS literal magnitude exceeds int range");
    }
    return literal < 0 ? -literal : literal;
}

private size_t checkedBlockProduct(size_t left, size_t right) {
    if (right != 0 && left > size_t.max / right) {
        throw new ModelException("Variable block size overflows size_t");
    }
    return left * right;
}

private string blockLabel(string prefix, const(size_t)[] indices) {
    string[] values;
    foreach (index; indices) {
        values ~= index.to!string;
    }
    return prefix ~ "[" ~ values.join(",") ~ "]";
}

private string tupleKey(const(long)[] tuple) {
    string result;
    foreach (index, value; tuple) {
        if (index != 0) {
            result ~= ",";
        }
        result ~= value.to!string;
    }
    return result;
}

private string tupleDisplay(const(long)[] tuple) {
    return tupleKey(tuple);
}

private void appendCombinations(
    ref long[][] output,
    ref long[] current,
    size_t next,
    size_t n,
    size_t remaining,
    bool replacement,
    size_t maximumTuples
) {
    if (remaining == 0) {
        if (output.length >= maximumTuples) {
            throw new ModelException(
                "Combinatorial group exceeds its configured tuple limit"
            );
        }
        output ~= current.dup;
        return;
    }
    if (next == 0 || next > n) {
        return;
    }

    foreach (candidate; next .. n + 1) {
        current ~= cast(long) candidate;
        appendCombinations(
            output,
            current,
            replacement ? candidate : candidate + 1,
            n,
            remaining - 1,
            replacement,
            maximumTuples
        );
        current.length = current.length - 1;
    }
}

private void appendWords(
    ref long[][] output,
    ref long[] current,
    ref bool[] used,
    size_t n,
    size_t remaining,
    bool replacement,
    size_t maximumTuples
) {
    if (remaining == 0) {
        if (output.length >= maximumTuples) {
            throw new ModelException(
                "Combinatorial group exceeds its configured tuple limit"
            );
        }
        output ~= current.dup;
        return;
    }
    foreach (candidate; 1 .. n + 1) {
        if (!replacement && used[candidate]) {
            continue;
        }
        current ~= cast(long) candidate;
        if (!replacement) {
            used[candidate] = true;
        }
        appendWords(
            output,
            current,
            used,
            n,
            remaining - 1,
            replacement,
            maximumTuples
        );
        if (!replacement) {
            used[candidate] = false;
        }
        current.length = current.length - 1;
    }
}

private IntExpr balancedSum(
    IntExpr[] expressions,
    size_t begin,
    size_t end
) {
    if (begin == end) {
        return integer(0);
    }
    if (end - begin == 1) {
        return expressions[begin];
    }
    const middle = begin + (end - begin) / 2;
    return balancedSum(expressions, begin, middle) +
        balancedSum(expressions, middle, end);
}