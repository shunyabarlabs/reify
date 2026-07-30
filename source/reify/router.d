// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.router;

import reify.diagnostics;
import reify.compiler;
import reify.backend : Capabilities;

import std.algorithm : max, min;
import std.format : format;
import std.json : JSONValue;
import std.string : startsWith;

/**
 * Recommended Navokoj backend execution route and hardware pre-flight estimate.
 *
 * When `refused` is true, callers (notably `NavokojApp.solveAuto`) must not
 * transmit a request — use the `rationale` field to surface why.
 */
struct RoutingRecommendation {
    string engine;                // "qstate", "nitro", "sutra", "hybrid"
    string hardware;              // "gpu_l4", "gpu_h100", "cpu_native"
    string targetEndpoint;        // "/v1/solve", "solve_qstate_l4", "solve_sat_h100", "solve_sat_l4"
    double estimatedSolveTimeMs;
    double estimatedVramMb;
    double estimatedCreditCost;
    string rationale;

    /// Set by `applyAccountLimits` when the model exceeds the account envelope.
    /// Distinguishes "router refused" from "no recommendation supplied" (the
    /// default state where engine/endpoint are empty strings but the request
    /// is still valid).
    bool refused = false;

    /// True when the recommendation must not be transmitted (limit violation).
    bool isRefusal() const {
        return refused;
    }

    JSONValue toJson() const {
        JSONValue[string] val;
        val["engine"] = JSONValue(engine);
        val["hardware"] = JSONValue(hardware);
        val["target_endpoint"] = JSONValue(targetEndpoint);
        val["estimated_solve_time_ms"] = JSONValue(estimatedSolveTimeMs);
        val["estimated_vram_mb"] = JSONValue(estimatedVramMb);
        val["estimated_credit_cost"] = JSONValue(estimatedCreditCost);
        val["rationale"] = JSONValue(rationale);
        val["is_refusal"] = JSONValue(isRefusal());
        return JSONValue(val);
    }
}

/**
 * Recommends optimal solver routing and capacity estimates based on topology
 * analysis and (optionally) the live account capability envelope.
 *
 * Backwards compatible: callers that omit `caps` get the same topology-driven
 * selection as before — `caps` is checked only when `hasAccountLimits()` is
 * true. This preserves all existing test fixtures.
 */
RoutingRecommendation recommendRoute(
    const ref TopologyAnalysis topology,
    CompileOptions options = CompileOptions(),
    Capabilities caps = Capabilities()
) {
    auto rec = recommendRouteByTopology(topology, options);
    if (caps.hasAccountLimits()) {
        applyAccountLimits(rec, topology, caps);
    }
    return rec;
}

/**
 * Topology-driven selection without account-limit reconciliation. Exposed for
 * tests that want to exercise the pure topology branches in isolation.
 */
RoutingRecommendation recommendRouteByTopology(
    const ref TopologyAnalysis topology,
    CompileOptions options = CompileOptions()
) {
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

    // 2. Hardware Verification / BMC Domain Protection
    // As established by the Lane Discipline architecture: Navokoj is an OR/Combinatorial platform.
    // Massive, pure-logic deep pipelines (Hardware BMC, Cryptography) require CDCL solvers (Minisat/Kissat)
    // for exact trace logic. We explicitly detect and refuse these instances to prevent stochastic
    // engines from plateauing on flat gradients, enforcing architectural boundaries at the API layer.
    if (topology.structureClassification == "hardware_bmc") {
        import reify.errors : UnsupportedDomainException;
        throw new UnsupportedDomainException(
            "Hardware Verification / Deep Logic pipeline detected. " ~
            "Navokoj is an OR/Combinatorial optimization platform. Please route " ~
            "this instance to an exact offline CDCL solver like Minisat, Kissat, or CaDiCaL."
        );
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

/**
 * Reconcile a topology-derived recommendation against the live account
 * capability envelope. Mutates `rec` in place:
 *   - Refuses the request when the model is bigger than the account can host.
 *   - Downgrades GPU selections to CPU when the account lacks GPU access.
 *
 * An empty `hardwareAccess` list is treated as "unknown" and lets the
 * topology choice stand — better to attempt and surface a server-side error
 * than to silently downgrade an instance the user explicitly asked for.
 */
private void applyAccountLimits(
    ref RoutingRecommendation rec,
    const ref TopologyAnalysis topology,
    const ref Capabilities caps
) {
    const sizeLimit = caps.maxVariables > 0
        ? cast(size_t) caps.maxVariables
        : size_t.max;
    const clauseLimit = caps.maxClauses > 0
        ? cast(size_t) caps.maxClauses
        : size_t.max;
    const vars = max(topology.encodedVariables, topology.logicalVariables);

    // Hard refusal: instance exceeds the account envelope entirely.
    if (vars > sizeLimit || topology.clauseCount > clauseLimit) {
        rec.refused = true;
        rec.estimatedSolveTimeMs = 0.0;
        rec.estimatedVramMb = 0.0;
        rec.estimatedCreditCost = 0.0;
        rec.rationale = format(
            "Refusing: model exceeds account limits (vars=%s > max=%s, clauses=%s > max=%s).",
            vars, sizeLimit, topology.clauseCount, clauseLimit
        );
        return;
    }

    // Soft downgrade: GPU selection but account lacks GPU access.
    if (rec.hardware != "cpu_native" && rec.hardware.length > 0
        && caps.hardwareAccess.length > 0)
    {
        bool hasHwAccess = false;
        foreach (h; caps.hardwareAccess) {
            if (h == rec.hardware || h == "any") { hasHwAccess = true; break; }
        }
        if (!hasHwAccess) {
            const oldHw = rec.hardware;
            rec.hardware = "cpu_native";
            if (rec.targetEndpoint.startsWith("solve_")) {
                rec.targetEndpoint = "/v1/solve";
            }
            rec.estimatedVramMb = max(64.0, rec.estimatedVramMb * 0.1);
            rec.rationale = format(
                "%s (downgraded from %s to cpu_native due to account hardware access list).",
                rec.rationale, oldHw
            );
        }
    }
}
