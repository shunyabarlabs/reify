// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module tests.formula_mapping_tests;

import reify.compiler : CompiledModel;
import reify.errors : ModelException;
import reify.formula;

import std.json : JSONValue;
import std.stdio : writeln;

private size_t assertions;

private void check(bool condition, string message) {
    ++assertions;
    if (!condition) {
        throw new Exception("Assertion failed: " ~ message);
    }
}

private bool satisfies(CompiledModel compiled, bool[] assignment) {
    foreach (clause; compiled.request.object["clauses"].array) {
        bool clauseSatisfied;
        foreach (literalValue; clause.array) {
            const literal = cast(int) literalValue.integer;
            const variable = literal < 0 ? -literal : literal;
            if (
                variable <= 0 ||
                cast(size_t) variable > assignment.length
            ) {
                throw new Exception("Test assignment is missing a variable");
            }
            const value = assignment[variable - 1];
            if (literal < 0 ? !value : value) {
                clauseSatisfied = true;
                break;
            }
        }
        if (!clauseSatisfied) {
            return false;
        }
    }
    return true;
}

private bool[] binaryAssignment(
    size_t variableCount,
    BinaryMapping mapping,
    const(size_t)[] values
) {
    auto assignment = new bool[](variableCount);
    foreach (domainOffset, value; values) {
        const code = value - mapping.valueBase;
        foreach (bitPosition; 0 .. mapping.bitsPerValue) {
            const variable = mapping.bit(
                domainOffset + 1,
                bitPosition
            );
            assignment[variable - 1] =
                (code & (cast(size_t) 1 << bitPosition)) != 0;
        }
    }
    return assignment;
}

private void testCompatibleBinaryMapping() {
    auto rawFormula = new CnfFormula("raw-compatible-binary");
    auto raw = rawFormula.newBinaryMapping("b", 2, 3);

    check(raw.valueBase == 0, "Compatible binary values start at zero");
    check(
        raw.bitOrder == BinaryBitOrder.mostSignificantFirst,
        "Compatible binary IDs are allocated most-significant-bit first"
    );
    check(
        raw.bit(1, 1) == 1 && raw.bit(1, 0) == 2,
        "Mathematical bit positions map to compatible DIMACS IDs"
    );
    check(
        raw.forbid(1, 0) == [1, 2] &&
        raw.forbid(1, 3) == [-1, -2],
        "Forbid clauses use zero-based codes and allocation order"
    );

    auto rawCompiled = rawFormula.compile();
    check(
        rawCompiled.request.object["clauses"].array.length == 0,
        "Allocating a compatible binary mapping adds no implicit clauses"
    );

    auto formula = new CnfFormula("binary-properties");
    auto mapping = formula.newBinaryMapping("m", 2, 3);
    formula.forceCompleteMapping(mapping);
    formula.forceFunctionalMapping(mapping);
    formula.forceInjectiveMapping(mapping);
    formula.forceNondecreasingMapping(mapping);
    auto compiled = formula.compile();

    foreach (left; 0 .. mapping.capacity) {
        foreach (right; 0 .. mapping.capacity) {
            const expected =
                left < mapping.range &&
                right < mapping.range &&
                left < right;
            check(
                satisfies(
                    compiled,
                    binaryAssignment(
                        compiled.generatedVariableCount,
                        mapping,
                        [left, right]
                    )
                ) == expected,
                "Binary mapping helpers preserve their mathematical semantics"
            );
        }
    }
}

private void testLegacyBinaryMapping() {
    auto formula = new CnfFormula("legacy-binary");
    auto mapping = formula.newLegacyBinaryMapping("legacy", 1, 3);
    check(mapping.valueBase == 1, "Legacy binary values remain one-based");
    check(
        mapping.bitOrder == BinaryBitOrder.leastSignificantFirst &&
        mapping.storageBit(1, 1) == mapping.bit(1, 0),
        "Legacy allocation remains least-significant-bit first"
    );

    auto compiled = formula.compile();
    foreach (value; 1 .. mapping.valueBase + mapping.capacity) {
        const expected = value <= mapping.lastValue;
        check(
            satisfies(
                compiled,
                binaryAssignment(
                    compiled.generatedVariableCount,
                    mapping,
                    [value]
                )
            ) == expected,
            "Legacy constructor retains automatic declared-range enforcement"
        );
    }
}

private void testSparseMappingWithIsolates() {
    auto completeFormula = new CnfFormula("sparse-complete");
    auto sparse = completeFormula.newSparseMapping(
        "edge",
        [10L, 20L, 30L],
        [5L, 9L, 12L],
        [
            [10L, 5L],
            [10L, 9L],
            [20L, 9L]
        ]
    );
    check(
        sparse.domain == [10L, 20L, 30L] &&
        sparse.range == [5L, 9L, 12L],
        "Sparse mappings retain explicit ordered sides including isolates"
    );
    check(
        sparse.hasEdge(10, 5) &&
        !sparse.hasEdge(20, 5) &&
        sparse.imagesOf(30).length == 0 &&
        sparse.preimagesOf(12).length == 0,
        "Sparse mapping lookup distinguishes absent edges and isolated values"
    );
    completeFormula.forceCompleteMapping(sparse);
    auto complete = completeFormula.compile();
    bool hasEmptyClause;
    foreach (clause; complete.request.object["clauses"].array) {
        if (clause.array.length == 0) {
            hasEmptyClause = true;
        }
    }
    check(
        hasEmptyClause,
        "Completeness exposes an isolated domain value as an empty clause"
    );

    auto surjectiveFormula = new CnfFormula("sparse-surjective");
    auto surjective = surjectiveFormula.newSparseMapping(
        "edge",
        [10L, 20L, 30L],
        [5L, 9L, 12L],
        [
            [10L, 5L],
            [10L, 9L],
            [20L, 9L]
        ]
    );
    surjectiveFormula.forceSurjectiveMapping(surjective);
    auto surjectiveCompiled = surjectiveFormula.compile();
    hasEmptyClause = false;
    foreach (clause; surjectiveCompiled.request.object["clauses"].array) {
        if (clause.array.length == 0) {
            hasEmptyClause = true;
        }
    }
    check(
        hasEmptyClause,
        "Surjectivity exposes an isolated range value as an empty clause"
    );

    auto orderedFormula = new CnfFormula("sparse-properties");
    auto ordered = orderedFormula.newSparseMapping(
        "edge",
        [10L, 20L],
        [5L, 9L],
        [
            [10L, 5L],
            [10L, 9L],
            [20L, 5L],
            [20L, 9L]
        ]
    );
    orderedFormula.forceCompleteMapping(ordered);
    orderedFormula.forceFunctionalMapping(ordered);
    orderedFormula.forceInjectiveMapping(ordered);
    orderedFormula.forceNondecreasingMapping(ordered);
    auto orderedCompiled = orderedFormula.compile();

    foreach (left; 0 .. 2) {
        foreach (right; 0 .. 2) {
            auto assignment =
                new bool[](orderedCompiled.generatedVariableCount);
            assignment[ordered(10, left == 0 ? 5 : 9) - 1] = true;
            assignment[ordered(20, right == 0 ? 5 : 9) - 1] = true;
            check(
                satisfies(orderedCompiled, assignment) == (left < right),
                "Sparse mapping properties respect explicit side order"
            );
        }
    }
}

private void testOwnershipAndAtomicity() {
    auto first = new CnfFormula("first");
    auto binary = first.newBinaryMapping("binary", 1, 2);
    auto sparse = first.newSparseMapping(
        "sparse",
        [1L],
        [1L],
        [[1L, 1L]]
    );
    auto second = new CnfFormula("second");

    bool caught;
    try {
        second.forceCompleteMapping(binary);
    } catch (ModelException) {
        caught = true;
    }
    check(caught, "Binary mappings cannot cross formula ownership");

    caught = false;
    try {
        second.forceCompleteMapping(sparse);
    } catch (ModelException) {
        caught = true;
    }
    check(caught, "Sparse mappings cannot cross formula ownership");

    auto atomic = new CnfFormula("atomic");
    atomic.newVariable("seed");
    caught = false;
    try {
        atomic.newIndexedGroup(
            "bad",
            [[1L], [2L], [1L]]
        );
    } catch (ModelException) {
        caught = true;
    }
    check(
        caught && atomic.numberOfVariables == 1,
        "Invalid indexed groups fail before committing any variables"
    );

    caught = false;
    try {
        atomic.newSparseMapping(
            "bad-edge",
            [1L],
            [1L],
            [[2L, 1L]]
        );
    } catch (ModelException) {
        caught = true;
    }
    check(
        caught && atomic.numberOfVariables == 1,
        "Invalid sparse mappings fail before committing any variables"
    );
}

private void testCombinatorialPreflights() {
    FormulaLimits limits;
    limits.maxVariables = 100;
    limits.maxIndexedTuples = 5;

    void expectAtomicFailure(
        scope void delegate(CnfFormula) operation,
        string message
    ) {
        auto formula = new CnfFormula("bounded", limits);
        formula.newVariable("seed");
        bool caught;
        try {
            operation(formula);
        } catch (ModelException) {
            caught = true;
        }
        check(
            caught && formula.numberOfVariables == 1,
            message
        );
    }

    expectAtomicFailure(
        (CnfFormula formula) {
            formula.newCombinations("c", 5, 2);
        },
        "Combination count is rejected before enumeration"
    );
    expectAtomicFailure(
        (CnfFormula formula) {
            formula.newCombinationsWithReplacement("r", 3, 2);
        },
        "Replacement-combination count is rejected before enumeration"
    );
    expectAtomicFailure(
        (CnfFormula formula) {
            formula.newPermutations("p", 4, 2);
        },
        "Permutation count is rejected before enumeration"
    );
    expectAtomicFailure(
        (CnfFormula formula) {
            formula.newWords("w", 3, 2);
        },
        "Word count is rejected before enumeration"
    );

    auto zeroArity = new CnfFormula("zero-arity", limits);
    auto emptyTuple = zeroArity.newCombinations("empty", 100, 0);
    check(
        emptyTuple.length == 1 &&
        emptyTuple.toIndex(emptyTuple.at([])).length == 0,
        "Zero-arity combinatorial groups retain their single empty tuple"
    );
}

int main() {
    testCompatibleBinaryMapping();
    testLegacyBinaryMapping();
    testSparseMappingWithIsolates();
    testOwnershipAndAtomicity();
    testCombinatorialPreflights();

    writeln(
        "formula mapping tests passed: ",
        assertions,
        " assertions"
    );
    return 0;
}