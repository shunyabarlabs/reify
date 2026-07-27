// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.router;

import reify.diagnostics;
import reify.compiler;

import std.algorithm : max, min;
import std.format : format;
import std.json : JSONValue;

/**
 * Recommended Navokoj backend execution route and hardware pre-flight estimate.
 */
struct RoutingRecommendation {
    string engine;                // "qstate", "nitro", "sutra", "hybrid"
    string hardware;              // "gpu_l4", "gpu_h100", "cpu_native"
    string targetEndpoint;        // "/v1/solve", "solve_qstate_l4", "solve_sat_h100", "solve_sat_l4"
    double estimatedSolveTimeMs;
    double estimatedVramMb;
    double estimatedCreditCost;
    string rationale;

    JSONValue toJson() const {
        JSONValue[string] val;
        val["engine"] = JSONValue(engine);
        val["hardware"] = JSONValue(hardware);
        val["target_endpoint"] = JSONValue(targetEndpoint);
        val["estimated_solve_time_ms"] = JSONValue(estimatedSolveTimeMs);
        val["estimated_vram_mb"] = JSONValue(estimatedVramMb);
        val["estimated_credit_cost"] = JSONValue(estimatedCreditCost);
        val["rationale"] = JSONValue(rationale);
        return JSONValue(val);
    }
}

/**
 * Recommends optimal solver routing and capacity estimates based on topology analysis.
 */
RoutingRecommendation recommendRoute(const ref TopologyAnalysis topology, CompileOptions options = CompileOptions()) {
    RoutingRecommendation rec;

    // 1. Q-State Categorical Routing
    if (topology.structureClassification == "qstate_categorical" && options.preferQState) {
        rec.engine = "qstate";
        rec.hardware = "gpu_l4";
        rec.targetEndpoint = "solve_qstate_l4";
        rec.estimatedVramMb = max(128.0, cast(double) topology.logicalVariables * 0.05);
        rec.estimatedSolveTimeMs = max(5.0, cast(double) topology.logicalVariables * 0.02);
        rec.estimatedCreditCost = 1.0;
        rec.rationale = "Categorical graph coloring / all-diff constraints detected. Routing to Modal L4 Q-State solver for continuous O(1) relaxation.";
        return rec;
    }

    // 2. Massive High-Clause CPU Instance -> SUTRA C Engine (Handles 113M+ clauses natively)
    if (topology.clauseCount > 5_000_000 && topology.objectiveCount == 0) {
        rec.engine = "nitro";
        rec.hardware = "cpu_native";
        rec.targetEndpoint = "/v1/solve";
        rec.estimatedVramMb = max(1024.0, cast(double) topology.clauseCount * 0.00005);
        rec.estimatedSolveTimeMs = max(100.0, cast(double) topology.clauseCount * 0.00001);
        rec.estimatedCreditCost = 3.0;
        rec.rationale = format(
            "Massive CNF instance (%s clauses). Routing to SUTRA high-throughput native CPU C engine (abstracted as 'nitro').",
            topology.clauseCount
        );
        return rec;
    }

    // 3. Heavy WCNF or Large Soft Constraint Instance -> H100 GPU
    if (topology.clauseCount > 100_000 || topology.objectiveCount > 0) {
        rec.engine = "nitro";
        rec.hardware = "gpu_h100";
        rec.targetEndpoint = "solve_sat_h100";
        rec.estimatedVramMb = max(512.0, cast(double) topology.clauseCount * 0.012);
        rec.estimatedSolveTimeMs = max(50.0, cast(double) topology.clauseCount * 0.0005);
        rec.estimatedCreditCost = 5.0;
        rec.rationale = format(
            "Large soft-constraint problem (%s clauses, %s objectives). Routing to Modal H100 GPU anytime continuous flow solver.",
            topology.clauseCount,
            topology.objectiveCount
        );
        return rec;
    }

    // 4. Hybrid XOR Parity Systems -> NitroSAT v3
    if (topology.structureClassification == "hybrid_xor" || topology.highXorFrustration) {
        rec.engine = "hybrid";
        rec.hardware = "gpu_l4";
        rec.targetEndpoint = "solve_sat_l4";
        rec.estimatedVramMb = max(256.0, cast(double) topology.parityCount * 0.08);
        rec.estimatedSolveTimeMs = max(10.0, cast(double) topology.parityCount * 0.1);
        rec.estimatedCreditCost = 2.0;
        rec.rationale = "Parity constraint system detected. Routing to NitroSAT v3 hybrid solver with integrated Gaussian elimination.";
        return rec;
    }

    // 5. Standard SUTRA / NitroSAT Micro-kernel CPU Routing
    rec.engine = "nitro";
    rec.hardware = "cpu_native";
    rec.targetEndpoint = "/v1/solve";
    rec.estimatedVramMb = 32.0;
    rec.estimatedSolveTimeMs = max(0.5, cast(double) topology.clauseCount * 0.001);
    rec.estimatedCreditCost = 0.5;
    rec.rationale = "Small-to-medium symbolic instance. Routing to low-latency SUTRA CPU micro-kernel (abstracted as 'nitro').";
    return rec;
}