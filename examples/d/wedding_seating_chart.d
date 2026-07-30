// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Wedding Seating Chart (Relatable Constraints Demo)
// ============================================================================
//
//  A fun, instantly understandable benchmark demonstrating hard logic 
//  constraints: families must sit together, enemies must sit apart, and 
//  each table has an exact capacity.
//
//  Hard Constraints:
//  - 16 guests, 2 tables of 8.
//  - Each guest sits at exactly 1 table.
//  - Families sit at the same table.
//  - Enemies cannot sit at the same table.
//
// ============================================================================

module wedding_seating_chart;

import reify;
import std.stdio;
import std.format : format;
import core.time : dur, seconds;

enum NUM_GUESTS = 16;
enum NUM_TABLES = 2;
enum TABLE_CAPACITY = 8;

void main() {
    writeln("==========================================================================");
    writeln("  Wedding Seating Chart (Relatable Demo)");
    writeln("==========================================================================");
    
    auto model = new Model("wedding-seating");

    // Decision Variables: sit[g][t] = true if guest g sits at table t
    BoolExpr[][] sit;
    sit.length = NUM_GUESTS;
    foreach (g; 0 .. NUM_GUESTS) {
        sit[g].length = NUM_TABLES;
        foreach (t; 0 .. NUM_TABLES) {
            sit[g][t] = model.booleanVar(format("sit[g%d,t%d]", g, t));
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 1: Each guest sits at exactly one table
    // ------------------------------------------------------------------------
    writeln("Adding Guest Assignment Constraints...");
    foreach (g; 0 .. NUM_GUESTS) {
        model.require(format("guest_%d_assigned", g), atLeast(1, sit[g]));
        model.require(format("guest_%d_unique", g), atMost(1, sit[g]));
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 2: Table Capacity is exactly 8
    // ------------------------------------------------------------------------
    writeln("Adding Table Capacity Constraints...");
    foreach (t; 0 .. NUM_TABLES) {
        BoolExpr[] guestsAtTable;
        foreach (g; 0 .. NUM_GUESTS) {
            guestsAtTable ~= sit[g][t];
        }
        model.require(format("table_%d_min_cap", t), atLeast(TABLE_CAPACITY, guestsAtTable));
        model.require(format("table_%d_max_cap", t), atMost(TABLE_CAPACITY, guestsAtTable));
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 3: Families sit together
    // ------------------------------------------------------------------------
    writeln("Adding 'Families Together' Constraints...");
    // Family A: 0-3, Family B: 4-7, Family C: 8-11, Family D: 12-15
    for (int fam = 0; fam < 4; fam++) {
        int base = fam * 4;
        // For each table, if base sits at table t, base+1, base+2, base+3 must also sit at table t
        foreach (t; 0 .. NUM_TABLES) {
            foreach (member; 1 .. 4) {
                model.require(
                    format("family_%d_together_t%d_m%d", fam, t, member),
                    equivalent(sit[base][t], sit[base + member][t])
                );
            }
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 4: Enemies sit apart
    // ------------------------------------------------------------------------
    writeln("Adding 'Enemies Apart' Constraints...");
    // Enemy pairs:
    // Guest 0 (Fam A) hates Guest 4 (Fam B)
    // Guest 8 (Fam C) hates Guest 12 (Fam D)
    int[][] enemies = [
        [0, 4],
        [8, 12]
    ];

    foreach (idx, pair; enemies) {
        int e1 = pair[0];
        int e2 = pair[1];
        foreach (t; 0 .. NUM_TABLES) {
            // Cannot both be true -> at most 1
            model.require(
                format("enemies_apart_%d_t%d", idx, t),
                atMost(1, [sit[e1][t], sit[e2][t]])
            );
        }
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
