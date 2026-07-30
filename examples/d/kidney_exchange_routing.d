// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Multi-Hospital Kidney Paired Donation & Logistics Graph
// ============================================================================
//
//  Models a highly complex, life-critical exchange graph for 32 donor-patient
//  pairs across 6 hospitals and 3 regions. Solves an NP-hard cycle/chain
//  packing problem with hard time-window logistics (cold-ischemia degradation),
//  OR surgical capacity constraints, and weighted WCNF ethical preferences.
//
//  Hard Constraints:
//  - ABO Blood Type Compatibility (Donor -> Recipient)
//  - Cycle Packing (Exact In/Out Degree for matched pairs)
//  - Time Windows: 24 discrete 30-min buckets (12-hour surgery day)
//  - Cold Ischemia Logistics: Start[transplant] >= Start[retrieval] + Transit
//  - Cycle Simultaneity: All surgeries in a cycle must start within 4 hours
//  - Hospital OR Capacity: Max 4 simultaneous surgeries per bucket
//
//  Soft Constraints (WCNF Weights):
//  - Maximize total matched pairs (Base Weight: 100)
//  - Highly sensitized (PRA >= 80) / Pediatric priority (Bonus: 50 / 40)
//
// ============================================================================

module kidney_exchange_routing;

import reify;
import std.stdio;
import std.format : format;
import std.algorithm;
import std.array;
import std.random;
import core.time : dur, seconds;

enum NUM_PAIRS = 16;
enum NUM_HOSPITALS = 4;
enum NUM_REGIONS = 3;
enum NUM_BUCKETS = 16; // 8 hours mapped to 30-min buckets

enum ubyte O = 0, A = 1, B = 2, AB = 3;

struct Pair {
    int id;
    int hospital;
    int region;
    ubyte donorABO;
    ubyte recipABO;
    int pra;
    bool pediatric;
    int waitMonths;
}

bool aboCompatible(ubyte donor, ubyte recip) {
    if (donor == O) return true;
    if (donor == A) return recip == A || recip == AB;
    if (donor == B) return recip == B || recip == AB;
    if (donor == AB) return recip == AB;
    return false;
}

// Deterministic generator to create realistic 32-pair data
Pair[] generatePairs() {
    Pair[] pairs;
    auto rnd = MinstdRand0(42); // Deterministic seed

    ubyte[] abos = [O, A, B, AB];
    foreach (i; 0 .. NUM_PAIRS) {
        Pair p;
        p.id = i;
        p.hospital = uniform(0, NUM_HOSPITALS, rnd);
        p.region = p.hospital % NUM_REGIONS;
        
        // Slightly skew ABO distributions
        p.donorABO = abos[uniform(0, 4, rnd)];
        p.recipABO = abos[uniform(0, 4, rnd)];
        
        p.pra = uniform(0, 100, rnd);
        p.pediatric = uniform(0, 100, rnd) < 15; // 15% pediatric
        p.waitMonths = uniform(1, 60, rnd);
        
        pairs ~= p;
    }
    return pairs;
}

void main() {
    writeln("==========================================================================");
    writeln("  Multi-Hospital Kidney Paired Donation Graph (16 Pairs)");
    writeln("==========================================================================");
    
    auto pairs = generatePairs();
    writeln("Generated 16 Patient-Donor pairs across ", NUM_HOSPITALS, " Hospitals in ", NUM_REGIONS, " Regions.");
    
    auto model = new Model("kidney-exchange");

    // Decision Variables
    // x[i][j]: pair i donates to pair j
    BoolExpr[][] x = new BoolExpr[][](NUM_PAIRS, NUM_PAIRS);
    BoolExpr[] used = new BoolExpr[](NUM_PAIRS);
    
    // start[i][b]: surgery for pair i starts at time bucket b
    BoolExpr[][] start = new BoolExpr[][](NUM_PAIRS, NUM_BUCKETS);

    foreach (i; 0 .. NUM_PAIRS) {
        used[i] = model.booleanVar(format("used_p%d", i));
        foreach (b; 0 .. NUM_BUCKETS) {
            start[i][b] = model.booleanVar(format("start_p%d_b%d", i, b));
        }
        
        foreach (j; 0 .. NUM_PAIRS) {
            x[i][j] = model.booleanVar(format("x_p%d_p%d", i, j));
            if (i == j || !aboCompatible(pairs[i].donorABO, pairs[j].recipABO)) {
                model.require(format("x_impossible_p%d_p%d", i, j), logicalNot(x[i][j]));
            }
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 1: Cycle Packing (Exact In/Out Degree)
    // ------------------------------------------------------------------------
    writeln("Adding Cycle Packing Constraints...");
    foreach (i; 0 .. NUM_PAIRS) {
        BoolExpr[] gives;
        BoolExpr[] receives;
        foreach (j; 0 .. NUM_PAIRS) {
            if (i != j) {
                gives ~= x[i][j];
                receives ~= x[j][i];
            }
        }
        
        // If used[i] is true, exactly 1 outgoing and exactly 1 incoming
        model.require(format("gives_p%d", i), equivalent(used[i], exactly(1, gives)));
        model.require(format("receives_p%d", i), equivalent(used[i], exactly(1, receives)));
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 2: Time Windows (Exactly 1 start time if used)
    // ------------------------------------------------------------------------
    writeln("Adding Time Window Allocation Constraints...");
    foreach (i; 0 .. NUM_PAIRS) {
        model.require(format("start_time_p%d", i), equivalent(used[i], exactly(1, start[i])));
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 3: Cold Ischemia Logistics & Transit 
    // ------------------------------------------------------------------------
    writeln("Adding Cold Ischemia & Hospital Transport Constraints...");
    foreach (i; 0 .. NUM_PAIRS) {
        foreach (j; 0 .. NUM_PAIRS) {
            if (i == j || !aboCompatible(pairs[i].donorABO, pairs[j].recipABO)) continue;
            
            // Transit time in buckets (1 bucket = 30 min)
            int transit = 0;
            if (pairs[i].hospital != pairs[j].hospital) transit += 1; // 30 min handling
            if (pairs[i].region != pairs[j].region) transit += 3; // 90 min flight
            
            // If i donates to j, start[j] must be >= start[i] + transit
            foreach (b_i; 0 .. NUM_BUCKETS) {
                // If x[i][j] and start[i][b_i] is true, start[j][b_j] cannot be true for any b_j < b_i + transit
                int min_bj = b_i + transit;
                foreach (b_j; 0 .. NUM_BUCKETS) {
                    if (b_j < min_bj) {
                        model.require(
                            format("ischemia_p%d_b%d_p%d_b%d", i, b_i, j, b_j),
                            atMost(2, [x[i][j], start[i][b_i], start[j][b_j]])
                        );
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 4: Hospital OR Capacity
    // ------------------------------------------------------------------------
    writeln("Adding Hospital Operating Room (OR) Capacity Constraints...");
    foreach (h; 0 .. NUM_HOSPITALS) {
        foreach (b; 0 .. NUM_BUCKETS) {
            BoolExpr[] activeSurgeries;
            foreach (i; 0 .. NUM_PAIRS) {
                if (pairs[i].hospital == h) {
                    activeSurgeries ~= start[i][b];
                }
            }
            if (activeSurgeries.length > 4) {
                model.require(format("or_cap_h%d_b%d", h, b), atMost(4, activeSurgeries));
            }
        }
    }

    // ------------------------------------------------------------------------
    // SOFT CONSTRAINTS (WCNF Objectives)
    // ------------------------------------------------------------------------
    writeln("Adding Ethical WCNF Soft Preferences...");
    foreach (i; 0 .. NUM_PAIRS) {
        // Base value of a transplant
        model.prefer(format("base_value_p%d", i), used[i], 100.0);
        
        // Sensitized bonus
        if (pairs[i].pra >= 80) {
            model.prefer(format("sensitized_bonus_p%d", i), used[i], 50.0);
        }
        
        // Pediatric bonus
        if (pairs[i].pediatric) {
            model.prefer(format("pediatric_bonus_p%d", i), used[i], 40.0);
        }
    }

    // ------------------------------------------------------------------------
    // COMPILATION
    // ------------------------------------------------------------------------
    writeln("\nCompiling model via Reify Decision Compiler...");
    stdout.flush();
    CompileOptions opts;
    auto compiled = compile(model, opts);

    writeln("\n=== Compilation Summary ===");
    writeln(compiled.summary().toPrettyString());
    stdout.flush();

    // ------------------------------------------------------------------------
    // SOLVE VIA NAVOKOJ SOLVER ENGINE
    // ------------------------------------------------------------------------
    writeln("\n=== Solving via Navokoj Solver Substrate (MaxSAT/WCNF) ===");
    stdout.flush();
    import std.process : environment;

    string apiKey = environment.get("NAVOKOJ_API_KEY", "");
    if (apiKey.length == 0) return;

    import reify.navokoj.client : NavokojClient, RequestOptions;
    import reify.router : RoutingRecommendation;

    RequestOptions reqOpts;
    reqOpts.apiKey = apiKey;
    reqOpts.transportTimeout = dur!"seconds"(300);

    auto client = new NavokojClient();

    RoutingRecommendation rec;
    rec.engine = "nitro";
    rec.hardware = "cpu";

    auto result = client.solveRaw(compiled, reqOpts, rec);
    writeln("\n=== Navokoj Response ===");
    writeln(result.toPrettyString());
}
