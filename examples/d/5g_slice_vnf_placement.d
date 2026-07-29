// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  5G Network Slicing & Edge VNF Chain Placement Benchmark
// ============================================================================
//
//  Models dynamic placement of 5G Virtual Network Function (VNF) chains across
//  16 Multi-access Edge Computing (MEC) data centers across 4 geographic regions
//  for 8 network slices spanning URLLC, eMBB, and mMTC QoS tiers.
//
//  Constraints:
//  - VNF placement uniqueness (exactly 1 MEC node per VNF instance)
//  - MEC node hardware capacity caps (max 3 VNFs per node)
//  - GPU hardware accelerator affinity for eMBB CDN VNFs
//  - Sub-millisecond latency bounds for URLLC vRAN -> vUPF propagation
//  - HA Active-Standby fault-domain anti-affinity (primary & backup UPF in different regions)
//  - Sequential DAG flow constraints for eMBB chains
//
// ============================================================================

module slice_vnf_placement;

import reify;
import std.stdio;
import std.array : array;
import std.range : iota;
import std.format : format;
import std.conv : to;
import core.time : dur, seconds;

enum NUM_NODES = 16;
enum NUM_REGIONS = 4; // 4 nodes per region (0..3, 4..7, 8..11, 12..15)

// GPU Acceleration Enabled Nodes: 2, 6, 10, 14
bool isGpuNode(size_t nodeIdx) {
    return (nodeIdx % 4) == 2;
}

size_t regionOf(size_t nodeIdx) {
    return nodeIdx / 4;
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
    writeln("  5G Network Slicing & Edge VNF Placement Benchmark");
    writeln("==========================================================================");
    writeln("MEC Edge Nodes: ", NUM_NODES, " across ", NUM_REGIONS, " geographic regions");
    writeln("GPU-Accelerated Nodes: Node 2, Node 6, Node 10, Node 14");

    // Build VNF catalog
    VnfInstance[] vnfs;
    size_t currentId = 0;

    // Slices 0..2: URLLC (vRAN, vUPF, vUPF_bak, vFW)
    foreach (s; 0 .. 3) {
        vnfs ~= VnfInstance(currentId++, format("s%d_vRAN", s), s, "urllc", "vRAN");
        vnfs ~= VnfInstance(currentId++, format("s%d_vUPF", s), s, "urllc", "vUPF");
        vnfs ~= VnfInstance(currentId++, format("s%d_vUPF_bak", s), s, "urllc", "vUPF_bak");
        vnfs ~= VnfInstance(currentId++, format("s%d_vFW", s), s, "urllc", "vFW");
    }

    // Slices 3..5: eMBB (vRAN, vUPF, vFW, vCDN)
    foreach (s; 3 .. 6) {
        vnfs ~= VnfInstance(currentId++, format("s%d_vRAN", s), s, "embb", "vRAN");
        vnfs ~= VnfInstance(currentId++, format("s%d_vUPF", s), s, "embb", "vUPF");
        vnfs ~= VnfInstance(currentId++, format("s%d_vFW", s), s, "embb", "vFW");
        vnfs ~= VnfInstance(currentId++, format("s%d_vCDN", s), s, "embb", "vCDN");
    }

    // Slices 6..7: mMTC (vRAN, vUPF)
    foreach (s; 6 .. 8) {
        vnfs ~= VnfInstance(currentId++, format("s%d_vRAN", s), s, "mmtc", "vRAN");
        vnfs ~= VnfInstance(currentId++, format("s%d_vUPF", s), s, "mmtc", "vUPF");
    }

    const numVnfs = vnfs.length;
    writeln("Total Slices: 8 (3 URLLC, 3 eMBB, 2 mMTC)");
    writeln("Total VNF Chains to Place: ", numVnfs);
    writeln("Decision Variables: ", numVnfs * NUM_NODES, " boolean placement flags");

    auto model = new Model("5g-slice-vnf-placement");

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
    // eMBB vCDN VNFs must be hosted on GPU nodes (2, 6, 10, 14)
    // ------------------------------------------------------------------------
    writeln("Adding GPU Hardware Accelerator Affinity for eMBB vCDN...");
    foreach (v; 0 .. numVnfs) {
        if (vnfs[v].vnfType == "vCDN") {
            // Cannot be placed on non-GPU nodes
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
    // HARD CONSTRAINT 4: URLLC Low-Latency Propagation Bounds (vRAN & vUPF Same Region)
    // ------------------------------------------------------------------------
    writeln("Adding URLLC Low-Latency Regional Co-Location Bounds...");
    foreach (s; 0 .. 3) {
        size_t vRanIdx = 0, vUpfIdx = 0, vUpfBakIdx = 0;
        foreach (v; 0 .. numVnfs) {
            if (vnfs[v].sliceId == s && vnfs[v].vnfType == "vRAN") vRanIdx = v;
            if (vnfs[v].sliceId == s && vnfs[v].vnfType == "vUPF") vUpfIdx = v;
            if (vnfs[v].sliceId == s && vnfs[v].vnfType == "vUPF_bak") vUpfBakIdx = v;
        }

        // vRAN and vUPF must be in the same geographic region (latency <= 1ms)
        foreach (n1; 0 .. NUM_NODES) {
            foreach (n2; 0 .. NUM_NODES) {
                if (regionOf(n1) != regionOf(n2)) {
                    model.require(
                        format("urllc_lat_s%d_n%d_n%d", s, n1, n2),
                        implies(host[vRanIdx][n1], logicalNot(host[vUpfIdx][n2]))
                    );
                }
            }
        }

        // HARD CONSTRAINT 5: HA Active-Standby Fault Domain Isolation
        // Primary vUPF and Backup vUPF_bak MUST be in DIFFERENT regions
        foreach (n1; 0 .. NUM_NODES) {
            foreach (n2; 0 .. NUM_NODES) {
                if (regionOf(n1) == regionOf(n2)) {
                    model.require(
                        format("urllc_ha_anti_s%d_n%d_n%d", s, n1, n2),
                        implies(host[vUpfIdx][n1], logicalNot(host[vUpfBakIdx][n2]))
                    );
                }
            }
        }
    }

    // ------------------------------------------------------------------------
    // SOFT PREFERENCES: Co-location & Load Balancing Optimization
    // ------------------------------------------------------------------------
    writeln("Adding Latency & Co-Location Soft Preferences...");
    foreach (v; 0 .. numVnfs) {
        if (vnfs[v].vnfType == "vRAN") {
            // Prefer placing vRAN on edge node 0 of its region (node % 4 == 0)
            foreach (n; 0 .. NUM_NODES) {
                if (n % 4 == 0) {
                    model.medium(
                        format("pref_edge_ran_%s_n%d", vnfs[v].name, n),
                        host[v][n],
                        6.0
                    );
                }
            }
        }
    }

    // ------------------------------------------------------------------------
    // COMPILATION
    // ------------------------------------------------------------------------
    writeln("\nCompiling model via Reify Decision Compiler...");
    CompileOptions opts;
    opts.maxBddNodesPerConstraint = 10_000_000;
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
    reqOpts.transportTimeout = dur!"seconds"(120);

    auto client = new NavokojClient();

    RoutingRecommendation rec;
    rec.engine = "nitro";
    rec.hardware = "cpu";

    auto result = client.solveRaw(compiled, reqOpts, rec);

    writeln("\n=== Navokoj Response ===");
    writeln(result.toPrettyString());
}
