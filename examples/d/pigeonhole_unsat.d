// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Pigeonhole Principle - Explicit Proof of UNSAT Benchmark
// ============================================================================
//
//  Places N+1 pigeons into N holes. This is the canonical example of a
//  problem that is logically impossible to satisfy. It is used to prove
//  that the compiler and solver engine gracefully detect, handle, and report
//  'infeasible' / UNSAT states, ensuring the verifier catches corrupted solutions.
//
//  Hard Constraints:
//  - Every pigeon must be in exactly one hole.
//  - Every hole can contain at most one pigeon.
//
// ============================================================================

module pigeonhole_unsat;

import reify;
import std.stdio;
import std.format : format;
import std.json;
import core.time : dur, seconds;

enum NUM_PIGEONS = 12;
enum NUM_HOLES = 11;

void main() {
    writeln("==========================================================================");
    writeln("  Pigeonhole Principle (Proof of UNSAT) Benchmark");
    writeln("==========================================================================");
    writeln("Attempting to place ", NUM_PIGEONS, " pigeons into ", NUM_HOLES, " holes...");
    
    auto model = new Model("pigeonhole-unsat");

    // Decision Variables: place[p][h] = true if pigeon p is in hole h
    BoolExpr[][] place;
    place.length = NUM_PIGEONS;
    foreach (p; 0 .. NUM_PIGEONS) {
        place[p].length = NUM_HOLES;
        foreach (h; 0 .. NUM_HOLES) {
            place[p][h] = model.booleanVar(format("place[p%d,h%d]", p, h));
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 1: Every pigeon must be in exactly one hole
    // ------------------------------------------------------------------------
    writeln("Adding Pigeon Assignment Constraints (Exactly One Hole per Pigeon)...");
    foreach (p; 0 .. NUM_PIGEONS) {
        model.require(
            format("pigeon_%d_assigned", p),
            atLeast(1, place[p])
        );
        model.require(
            format("pigeon_%d_unique", p),
            atMost(1, place[p])
        );
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 2: Every hole can contain at most one pigeon
    // ------------------------------------------------------------------------
    writeln("Adding Hole Capacity Constraints (At Most One Pigeon per Hole)...");
    foreach (h; 0 .. NUM_HOLES) {
        BoolExpr[] pigeonsInHole;
        foreach (p; 0 .. NUM_PIGEONS) {
            pigeonsInHole ~= place[p][h];
        }
        model.require(
            format("hole_%d_capacity", h),
            atMost(1, pigeonsInHole)
        );
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
    writeln("\n=== Solving via Navokoj Solver Substrate (EXPECTING UNSAT) ===");
    stdout.flush();
    import std.process : environment;

    string apiKey = environment.get("NAVOKOJ_API_KEY", "");
    if (apiKey.length == 0) return;

    import reify.navokoj.client : NavokojClient, RequestOptions;
    import reify.router : RoutingRecommendation;
    import reify.errors : ApiException;

    RequestOptions reqOpts;
    reqOpts.apiKey = apiKey;
    reqOpts.transportTimeout = dur!"seconds"(30);

    auto client = new NavokojClient();

    RoutingRecommendation rec;
    rec.engine = "nitro";
    rec.hardware = "cpu";

    try {
        auto result = client.solveRaw(compiled, reqOpts, rec);
        writeln("\n=== Navokoj Response ===");
        
        bool isFeasible = result["solution"]["feasible"].type == std.json.JSONType.true_;
        if (!isFeasible) {
            writeln("SUCCESS: Solver correctly proved the model is INFEASIBLE (UNSAT)!");
        } else {
            writeln("ERROR: Solver returned FEASIBLE for an impossible model!");
        }
        
        writeln(result.toPrettyString());
        stdout.flush();
    } catch (ApiException e) {
        writeln("\nStatus Code: ", e.statusCode);
        writeln("API Error Raw Body: ", e.rawBody);
        stdout.flush();
    }
}
