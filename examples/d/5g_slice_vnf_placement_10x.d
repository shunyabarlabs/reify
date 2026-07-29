// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  10x Scaled 5G Network Slicing & Edge VNF Placement Extreme Benchmark
// ============================================================================
//
//  Models dynamic placement of 5G Virtual Network Function (VNF) chains across
//  160 Multi-access Edge Computing (MEC) data centers across 16 geographic regions
//  for 40 network slices spanning URLLC, eMBB, and mMTC QoS tiers.
//
//  Dimensions:
//  - 160 MEC Edge Nodes across 16 Geographic Regions (10 nodes per region)
//  - 40 GPU-Accelerated Edge Nodes
//  - 40 5G Network Slices (15 URLLC, 15 eMBB, 10 mMTC)
//  - 140 VNF Instances
//  - 22,400 Logical Decision Variables
//  - ~835,000 Encoded CNF Clauses
//
// ============================================================================

module slice_vnf_placement_10x;

import reify;
import std.stdio;
import std.array : array;
import std.range : iota;
import std.format : format;
import std.conv : to;
import core.time : dur, seconds;

enum NUM_NODES = 160;
enum NUM_REGIONS = 16; // 10 nodes per region

bool isGpuNode(size_t nodeIdx) {
    return (nodeIdx % 4) == 2;
}

size_t regionOf(size_t nodeIdx) {
    return nodeIdx / 10;
}

size_t[] nodesInRegion(size_t regIdx) {
    size_t[] nodes;
    foreach (n; regIdx * 10 .. (regIdx + 1) * 10) {
        nodes ~= n;
    }
    return nodes;
}

struct VnfInstance {
    size_t id;
    string name;
    size_t sliceId;
    string sliceType; // "urllc", "embb", "mmtc"
    string vnfType;   // "vRAN", "vUPF", "vUPF_bak", "vFW", "vCDN"
}

void main() {
    writeln("==========================================================================");
    writeln("  10x Scaled 5G Network Slicing & Edge VNF Placement Benchmark");
    writeln("==========================================================================");
    writeln("MEC Edge Nodes: ", NUM_NODES, " across ", NUM_REGIONS, " geographic regions");
    writeln("GPU-Accelerated Nodes: ", NUM_NODES / 4, " nodes");

    // Build VNF catalog for 40 slices
    VnfInstance[] vnfs;
    size_t currentId = 0;

    // Slices 0..14: URLLC (vRAN, vUPF, vUPF_bak, vFW)
    foreach (s; 0 .. 15) {
        vnfs ~= VnfInstance(currentId++, format("s%d_vRAN", s), s, "urllc", "vRAN");
        vnfs ~= VnfInstance(currentId++, format("s%d_vUPF", s), s, "urllc", "vUPF");
        vnfs ~= VnfInstance(currentId++, format("s%d_vUPF_bak", s), s, "urllc", "vUPF_bak");
        vnfs ~= VnfInstance(currentId++, format("s%d_vFW", s), s, "urllc", "vFW");
    }

    // Slices 15..29: eMBB (vRAN, vUPF, vFW, vCDN)
    foreach (s; 15 .. 30) {
        vnfs ~= VnfInstance(currentId++, format("s%d_vRAN", s), s, "embb", "vRAN");
        vnfs ~= VnfInstance(currentId++, format("s%d_vUPF", s), s, "embb", "vUPF");
        vnfs ~= VnfInstance(currentId++, format("s%d_vFW", s), s, "embb", "vFW");
        vnfs ~= VnfInstance(currentId++, format("s%d_vCDN", s), s, "embb", "vCDN");
    }

    // Slices 30..39: mMTC (vRAN, vUPF)
    foreach (s; 30 .. 40) {
        vnfs ~= VnfInstance(currentId++, format("s%d_vRAN", s), s, "mmtc", "vRAN");
        vnfs ~= VnfInstance(currentId++, format("s%d_vUPF", s), s, "mmtc", "vUPF");
    }

    const numVnfs = vnfs.length;
    writeln("Total Slices: 40 (15 URLLC, 15 eMBB, 10 mMTC)");
    writeln("Total VNF Chains to Place: ", numVnfs);
    writeln("Decision Variables: ", numVnfs * NUM_NODES, " boolean placement flags");

    auto model = new Model("5g-slice-vnf-placement-10x");

    // Decision Variables: host[v][n] = true if VNF v is hosted on MEC Node n
    BoolExpr[][] host;
    host.length = numVnfs;
    foreach (v; 0 .. numVnfs) {
        host[v] = new BoolExpr[](NUM_NODES);
        foreach (n; 0 .. NUM_NODES) {
            host[v][n] = model.booleanVar(format("host[%s,n%d]", vnfs[v].name, n));
        }

        // HARD CONSTRAINT 1: Exactly one MEC node per VNF instance
        model.require(
            format("unique_node_v%d", v),
            exactly(1, host[v])
        );
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 2: MEC Node Capacity Caps (Max 3 VNFs per Node)
    // ------------------------------------------------------------------------
    writeln("\nAdding MEC Node Capacity Limits (Max 3 VNFs per Node)...");
    foreach (n; 0 .. NUM_NODES) {
        BoolExpr[] nodeHostedVnfs;
        foreach (v; 0 .. numVnfs) {
            nodeHostedVnfs ~= host[v][n];
        }
        model.require(format("cap_max3_node_%d", n), atMost(3, nodeHostedVnfs));
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 3: GPU Hardware Accelerator Affinity for eMBB CDN VNFs
    // ------------------------------------------------------------------------
    writeln("Adding GPU Hardware Accelerator Affinity for eMBB vCDN...");
    foreach (v; 0 .. numVnfs) {
        if (vnfs[v].vnfType == "vCDN") {
            foreach (n; 0 .. NUM_NODES) {
                if (!isGpuNode(n)) {
                    model.require(
                        format("gpu_req_%s_n%d", vnfs[v].name, n),
                        logicalNot(host[v][n])
                    );
                }
            }
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 4: URLLC Low-Latency Regional Co-Location & HA Anti-Affinity
    // ------------------------------------------------------------------------
    writeln("Adding URLLC Regional Co-Location & HA Active-Standby Anti-Affinity...");
    foreach (s; 0 .. 15) {
        size_t vRanIdx = 0, vUpfIdx = 0, vUpfBakIdx = 0;
        foreach (v; 0 .. numVnfs) {
            if (vnfs[v].sliceId == s && vnfs[v].vnfType == "vRAN") vRanIdx = v;
            if (vnfs[v].sliceId == s && vnfs[v].vnfType == "vUPF") vUpfIdx = v;
            if (vnfs[v].sliceId == s && vnfs[v].vnfType == "vUPF_bak") vUpfBakIdx = v;
        }

        // vRAN -> vUPF Regional Co-Location
        foreach (n1; 0 .. NUM_NODES) {
            size_t reg = regionOf(n1);
            BoolExpr[] sameRegionUpfs;
            foreach (n2; nodesInRegion(reg)) {
                sameRegionUpfs ~= host[vUpfIdx][n2];
            }
            model.require(
                format("urllc_lat_s%d_n%d", s, n1),
                implies(host[vRanIdx][n1], atLeast(1, sameRegionUpfs))
            );
        }

        // HA Active-Standby Anti-Affinity: Primary vUPF and Backup vUPF_bak in DIFFERENT regions
        foreach (n1; 0 .. NUM_NODES) {
            size_t reg = regionOf(n1);
            BoolExpr[] sameRegionUpfBaks;
            foreach (n2; nodesInRegion(reg)) {
                sameRegionUpfBaks ~= host[vUpfBakIdx][n2];
            }
            model.require(
                format("urllc_ha_anti_s%d_n%d", s, n1),
                implies(host[vUpfIdx][n1], logicalNot(atLeast(1, sameRegionUpfBaks)))
            );
        }
    }

    // ------------------------------------------------------------------------
    // COMPILATION
    // ------------------------------------------------------------------------
    writeln("\nCompiling 10x scaled model via Reify Decision Compiler...");
    CompileOptions opts;
    opts.maxBddNodesPerConstraint = 50_000_000;
    auto compiled = compile(model, opts);

    writeln("\n=== Compilation Summary ===");
    writeln(compiled.summary().toPrettyString());

    // ------------------------------------------------------------------------
    // SOLVE VIA NAVOKOJ SOLVER ENGINE
    // ------------------------------------------------------------------------
    writeln("\n=== Solving via Navokoj Solver Substrate ===");
    import std.process : environment;

    string apiKey = environment.get("NAVOKOJ_API_KEY", "");
    if (apiKey.length == 0) {
        writeln("Set NAVOKOJ_API_KEY to execute solver.");
        return;
    }

    import reify.navokoj.client : NavokojClient, RequestOptions;
    import reify.router : RoutingRecommendation;

    RequestOptions reqOpts;
    reqOpts.apiKey = apiKey;
    reqOpts.transportTimeout = dur!"seconds"(180);

    auto client = new NavokojClient();

    RoutingRecommendation rec;
    rec.engine = "nitro";
    rec.hardware = "cpu";

    auto result = client.solveRaw(compiled, reqOpts, rec);

    writeln("\n=== Navokoj Response ===");
    writeln(result.toPrettyString());
}
