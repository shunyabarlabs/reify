// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Car Sequencing Benchmark (CSPLib #1)
// ============================================================================
//
//  The canonical Constraint Satisfaction Problem benchmark. Sequences cars
//  on an assembly line such that sliding window station capacities are respected.
//
//  Hard Constraints:
//  - Exactly N cars of each class must be scheduled (Demand Satisfaction).
//  - Station Capacity Ratios (e.g., max 1 sunroof out of any 2 consecutive cars).
//
// ============================================================================

module car_sequencing_classic;

import reify;
import std.stdio;
import std.format : format;
import core.time : dur, seconds;

enum NUM_SLOTS = 12;
enum NUM_CLASSES = 4;

// Demand for each class
// Class 0: Sunroof only (2 cars)
// Class 1: Radio only (4 cars)
// Class 2: Both Sunroof & Radio (4 cars)
// Class 3: Neither (2 cars)
int[NUM_CLASSES] DEMAND = [2, 4, 4, 2];

// Feature requirements for each class
bool[NUM_CLASSES] REQUIRES_SUNROOF = [true, false, true, false];
bool[NUM_CLASSES] REQUIRES_RADIO   = [false, true, true, false];

// Sliding Window Capacities
enum SUNROOF_CAPACITY_NUM = 1;
enum SUNROOF_CAPACITY_DEN = 2; // At most 1 in any 2 consecutive cars

enum RADIO_CAPACITY_NUM = 2;
enum RADIO_CAPACITY_DEN = 3;   // At most 2 in any 3 consecutive cars

void main() {
    writeln("==========================================================================");
    writeln("  Car Sequencing Benchmark (CSPLib #1)");
    writeln("==========================================================================");
    
    auto model = new Model("car-sequencing");

    // Decision Variables: assign[s][c] = true if slot s builds a car of class c
    BoolExpr[][] assign;
    assign.length = NUM_SLOTS;
    foreach (s; 0 .. NUM_SLOTS) {
        assign[s].length = NUM_CLASSES;
        foreach (c; 0 .. NUM_CLASSES) {
            assign[s][c] = model.booleanVar(format("assign[s%d,c%d]", s, c));
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 1: Exactly one class assigned per slot
    // ------------------------------------------------------------------------
    writeln("Adding Slot Assignment Constraints...");
    foreach (s; 0 .. NUM_SLOTS) {
        model.require(
            format("slot_%d_assigned", s),
            atLeast(1, assign[s])
        );
        model.require(
            format("slot_%d_unique", s),
            atMost(1, assign[s])
        );
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 2: Demand Satisfaction
    // ------------------------------------------------------------------------
    writeln("Adding Demand Satisfaction Constraints...");
    // Since Reify provides symbolic sumExpr, we can just say sum == demand,
    // but atMost / atLeast is purer CNF.
    foreach (c; 0 .. NUM_CLASSES) {
        BoolExpr[] classSlots;
        foreach (s; 0 .. NUM_SLOTS) {
            classSlots ~= assign[s][c];
        }
        // Demand must be met exactly
        model.require(format("demand_min_c%d", c), atLeast(DEMAND[c], classSlots));
        model.require(format("demand_max_c%d", c), atMost(DEMAND[c], classSlots));
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 3: Sliding Window Capacities
    // ------------------------------------------------------------------------
    writeln("Adding Sliding Window Capacity Constraints...");
    
    // Feature variables: hasSunroof[s], hasRadio[s]
    BoolExpr[] hasSunroof;
    BoolExpr[] hasRadio;
    hasSunroof.length = NUM_SLOTS;
    hasRadio.length = NUM_SLOTS;

    foreach (s; 0 .. NUM_SLOTS) {
        BoolExpr[] sunroofClasses;
        BoolExpr[] radioClasses;
        foreach (c; 0 .. NUM_CLASSES) {
            if (REQUIRES_SUNROOF[c]) sunroofClasses ~= assign[s][c];
            if (REQUIRES_RADIO[c]) radioClasses ~= assign[s][c];
        }
        
        hasSunroof[s] = model.booleanVar(format("hasSunroof_s%d", s));
        hasRadio[s] = model.booleanVar(format("hasRadio_s%d", s));
        
        // hasSunroof[s] <-> (assign[s][c_with_sunroof] or ...)
        model.require(format("sunroof_def_s%d", s), equivalent(hasSunroof[s], atLeast(1, sunroofClasses)));
        model.require(format("radio_def_s%d", s), equivalent(hasRadio[s], atLeast(1, radioClasses)));
    }

    // Apply capacity windows
    // Sunroof: max 1 in any window of 2
    for (size_t s = 0; s <= NUM_SLOTS - SUNROOF_CAPACITY_DEN; s++) {
        BoolExpr[] window;
        foreach (w; 0 .. SUNROOF_CAPACITY_DEN) {
            window ~= hasSunroof[s + w];
        }
        model.require(format("cap_sunroof_w%d", s), atMost(SUNROOF_CAPACITY_NUM, window));
    }

    // Radio: max 2 in any window of 3
    for (size_t s = 0; s <= NUM_SLOTS - RADIO_CAPACITY_DEN; s++) {
        BoolExpr[] window;
        foreach (w; 0 .. RADIO_CAPACITY_DEN) {
            window ~= hasRadio[s + w];
        }
        model.require(format("cap_radio_w%d", s), atMost(RADIO_CAPACITY_NUM, window));
    }

    // ------------------------------------------------------------------------
    // COMPILATION & EXECUTION
    // ------------------------------------------------------------------------
    writeln("\nCompiling model via Reify Decision Compiler...");
    stdout.flush();
    CompileOptions opts;
    auto compiled = compile(model, opts);

    writeln("\n=== Compilation Summary ===");
    writeln(compiled.summary().toPrettyString());
    stdout.flush();

    writeln("\n=== Solving via Navokoj Solver Substrate ===");
    stdout.flush();
    import std.process : environment;

    string apiKey = environment.get("NAVOKOJ_API_KEY", "");
    if (apiKey.length == 0) return;

    import reify.navokoj.client : NavokojClient, RequestOptions;
    import reify.router : RoutingRecommendation;

    RequestOptions reqOpts;
    reqOpts.apiKey = apiKey;
    reqOpts.transportTimeout = dur!"seconds"(30);

    auto client = new NavokojClient();

    RoutingRecommendation rec;
    rec.engine = "nitro";
    rec.hardware = "cpu";

    auto result = client.solveRaw(compiled, reqOpts, rec);
    writeln("\n=== Navokoj Response ===");
    writeln(result.toPrettyString());
}
