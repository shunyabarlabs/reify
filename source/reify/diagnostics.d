// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.diagnostics;

import reify.model;
import reify.compiler;

import std.algorithm : canFind, filter, max, min;
import std.format : format;
import std.json : JSONValue;
import std.math : log2;

/**
 * Geometric and topological analysis of a symbolic model or compiled matrix.
 */
struct TopologyAnalysis {
    size_t logicalVariables;
    size_t encodedVariables;
    size_t clauseCount;
    size_t parityCount;
    size_t symbolicConstraints;
    size_t objectiveCount;
    
    double alpha;                     // Clause-to-variable ratio (M / N)
    bool nearPhaseTransition;          // True if near 3-SAT phase transition (3.8 <= alpha <= 4.8)
    double xorDensity;                // Parity-to-variable ratio
    bool highXorFrustration;          // High XOR cycle density
    double categoricalEntropy;        // Average domain cardinality entropy
    
    string structureClassification;   // "qstate_categorical", "hybrid_xor", "wcnf_soft", "pure_sat", "dense_arithmetic"
    string[] bottleneckWarnings;
    string suggestedAction;

    JSONValue toJson() const {
        JSONValue[string] val;
        val["logical_variables"] = JSONValue(cast(long) logicalVariables);
        val["encoded_variables"] = JSONValue(cast(long) encodedVariables);
        val["clause_count"] = JSONValue(cast(long) clauseCount);
        val["parity_count"] = JSONValue(cast(long) parityCount);
        val["symbolic_constraints"] = JSONValue(cast(long) symbolicConstraints);
        val["objective_count"] = JSONValue(cast(long) objectiveCount);
        val["alpha_density"] = JSONValue(alpha);
        val["near_phase_transition"] = JSONValue(nearPhaseTransition);
        val["xor_density"] = JSONValue(xorDensity);
        val["high_xor_frustration"] = JSONValue(highXorFrustration);
        val["structure_classification"] = JSONValue(structureClassification);
        val["suggested_action"] = JSONValue(suggestedAction);
        
        JSONValue[] warningsArr;
        foreach (w; bottleneckWarnings) {
            warningsArr ~= JSONValue(w);
        }
        val["bottleneck_warnings"] = JSONValue(warningsArr);
        return JSONValue(val);
    }
}

/**
 * Analyze a symbolic Model before compilation.
 */
TopologyAnalysis analyzeModel(Model model) {
    TopologyAnalysis analysis;
    if (model is null) return analysis;

    analysis.logicalVariables = model.internalVariables.length;
    analysis.symbolicConstraints = model.internalConstraints.length;
    analysis.clauseCount = model.internalNativeClauses.length;
    analysis.parityCount = model.internalParityConstraints.length;
    analysis.objectiveCount = model.internalObjectives.length;

    const N = max(1, analysis.logicalVariables);
    const M = analysis.clauseCount + analysis.symbolicConstraints;
    analysis.alpha = cast(double) M / cast(double) N;
    analysis.nearPhaseTransition = (analysis.alpha >= 3.8 && analysis.alpha <= 4.8);

    analysis.xorDensity = cast(double) analysis.parityCount / cast(double) N;
    analysis.highXorFrustration = (analysis.xorDensity > 0.3);

    // Compute categorical domain entropy
    double totalEntropy = 0.0;
    size_t categoricalCount = 0;
    foreach (var; model.internalVariables) {
        if (var.kind == VariableKind.categorical) {
            ++categoricalCount;
            const domainSize = max(1, var.states.length);
            totalEntropy += log2(cast(double) domainSize);
        }
    }
    analysis.categoricalEntropy = categoricalCount > 0 ? totalEntropy / cast(double) categoricalCount : 0.0;

    // Classification logic
    if (categoricalCount == analysis.logicalVariables && analysis.logicalVariables > 0 && analysis.objectiveCount == 0 && analysis.parityCount == 0) {
        analysis.structureClassification = "qstate_categorical";
        analysis.suggestedAction = "Route to Modal L4 Q-State GPU solver for O(1) continuous state relaxation.";
    } else if (analysis.parityCount > 0 || analysis.xorDensity > 0.1) {
        analysis.structureClassification = "hybrid_xor";
        analysis.suggestedAction = "Route to NitroSAT v3 hybrid continuous engine with native Gaussian parity elimination.";
    } else if (analysis.objectiveCount > 0) {
        analysis.structureClassification = "wcnf_soft";
        analysis.suggestedAction = "Route to Modal H100 GPU anytime continuous flow with WalkSAT hard repair.";
    } else if (M > 10_000) {
        analysis.structureClassification = "dense_arithmetic";
        analysis.suggestedAction = "Route to Modal L4 GPU solver with order-encoding BDD reduction.";
    } else {
        analysis.structureClassification = "pure_sat";
        analysis.suggestedAction = "Route to NitroSAT micro-kernel for sub-millisecond solving.";
    }

    // Diagnostics & Bottlenecks
    if (analysis.nearPhaseTransition) {
        analysis.bottleneckWarnings ~= format(
            "Phase transition detected (alpha = %.2f). Instance lies in the NP-hard phase boundary.",
            analysis.alpha
        );
    }
    if (analysis.highXorFrustration) {
        analysis.bottleneckWarnings ~= format(
            "High XOR parity density (ratio = %.2f). Standard CDCL solvers will experience exponential branching.",
            analysis.xorDensity
        );
    }
    if (analysis.objectiveCount > 50) {
        analysis.bottleneckWarnings ~= "High objective count (>50). Soft constraint weights may cause precision loss in continuous solvers.";
    }

    return analysis;
}

/**
 * Analyze a CompiledModel matrix.
 */
TopologyAnalysis analyzeCompiled(CompiledModel compiled) {
    if (compiled is null || compiled.model is null) return TopologyAnalysis();
    auto analysis = analyzeModel(compiled.model);
    analysis.encodedVariables = compiled.generatedVariableCount;
    analysis.clauseCount = compiled.clauses.length;
    
    const N = max(1, analysis.encodedVariables);
    const M = analysis.clauseCount;
    analysis.alpha = cast(double) M / cast(double) N;
    analysis.nearPhaseTransition = (analysis.alpha >= 3.8 && analysis.alpha <= 4.8);

    if (compiled.generatedVariableCount > 100_000) {
        analysis.bottleneckWarnings ~= format(
            "Large encoded variable matrix (%s variables). GPU VRAM allocation required.",
            compiled.generatedVariableCount
        );
    }
    return analysis;
}