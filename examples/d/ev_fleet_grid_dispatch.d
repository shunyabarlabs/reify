// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  EV Fleet Smart Grid Energy Dispatch Benchmark
// ============================================================================
//
//  Models an autonomous fleet of 12 commercial EV delivery vans over a 24-hour
//  horizon with dynamic grid Time-of-Use (ToU) tariffs, solar PV generation,
//  depot transformer peak load limits, charger concurrency caps, and battery
//  State-of-Charge (SoC) readiness constraints.
//
// ============================================================================

module ev_fleet_grid_dispatch;

import reify;
import std.stdio;
import std.array : array;
import std.range : iota;
import std.format : format;
import std.conv : to;
import core.time : dur, seconds;

enum NUM_VANS = 12;
enum NUM_HOURS = 24;

// Van Shift Schedules:
// Vans 0..5  -> Morning Shift (On Delivery Route Hours 8..13)
// Vans 6..11 -> Afternoon Shift (On Delivery Route Hours 14..19)

void main() {
    writeln("==========================================================================");
    writeln("  EV Fleet Smart Grid Energy Dispatch Benchmark");
    writeln("==========================================================================");
    writeln("Vans: ", NUM_VANS);
    writeln("Time Slots: ", NUM_HOURS, " hours (00:00 - 23:00)");
    writeln("Charger Modes: 4 (Idle=0kW, Slow=7kW, Fast=22kW, DC Fast=50kW)");
    writeln("Logical Variables: ", NUM_VANS * NUM_HOURS * 4);

    auto model = new Model("ev-fleet-grid-dispatch");

    auto vans = iota(0, NUM_VANS).array;
    auto hours = iota(0, NUM_HOURS).array;

    // Decision Variables: 4 mode boolean flags per van per hour
    // mode 0 = idle, mode 1 = slow, mode 2 = fast, mode 3 = dc_fast
    BoolExpr[][][] mode;
    mode.length = NUM_VANS;
    foreach (v; vans) {
        mode[v] = new BoolExpr[][](NUM_HOURS, 4);
        foreach (h; hours) {
            mode[v][h][0] = model.booleanVar(format("idle[%d,%d]", v, h));
            mode[v][h][1] = model.booleanVar(format("slow[%d,%d]", v, h));
            mode[v][h][2] = model.booleanVar(format("fast[%d,%d]", v, h));
            mode[v][h][3] = model.booleanVar(format("dc_fast[%d,%d]", v, h));

            // Exactly one charging mode selected per van per hour
            model.require(
                format("one_mode_%d_%d", v, h),
                exactly(1, [mode[v][h][0], mode[v][h][1], mode[v][h][2], mode[v][h][3]])
            );
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 1: Delivery Shift Route Constraints (Van must be Idle at Depot)
    // ------------------------------------------------------------------------
    writeln("\nAdding Delivery Route Constraints...");
    foreach (v; 0 .. 6) {
        foreach (h; 8 .. 14) {
            model.require(
                format("van_on_route_%d_%d", v, h),
                mode[v][h][0] // Must be idle
            );
        }
    }
    foreach (v; 6 .. 12) {
        foreach (h; 14 .. 20) {
            model.require(
                format("van_on_route_%d_%d", v, h),
                mode[v][h][0] // Must be idle
            );
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 2: Charger Hardware Concurrency Bounds per Hour
    // Max 3 vans on DC Fast (50kW) simultaneously to prevent thermal overload
    // Max 5 vans on Fast (22kW) simultaneously
    // ------------------------------------------------------------------------
    writeln("Adding Charger Hardware Concurrency Bounds...");
    foreach (h; hours) {
        BoolExpr[] dcFastVars;
        BoolExpr[] fastVars;
        foreach (v; vans) {
            dcFastVars ~= mode[v][h][3];
            fastVars ~= mode[v][h][2];
        }
        model.require(format("max_dc_fast_h%d", h), atMost(3, dcFastVars));
        model.require(format("max_fast_h%d", h), atMost(5, fastVars));
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 3: Departure Battery SoC Readiness Requirements
    // Morning Vans (0..5) must get at least 2 fast/dc_fast charges before Hour 8
    // Afternoon Vans (6..11) must get at least 3 fast/dc_fast charges before Hour 14
    // ------------------------------------------------------------------------
    writeln("Adding Battery SoC Departure Readiness Constraints...");
    foreach (v; 0 .. 6) {
        BoolExpr[] preShiftCharges;
        foreach (h; 0 .. 8) {
            preShiftCharges ~= mode[v][h][2];
            preShiftCharges ~= mode[v][h][3];
        }
        model.require(format("soc_ready_morning_van_%d", v), atLeast(2, preShiftCharges));
    }

    foreach (v; 6 .. 12) {
        BoolExpr[] preShiftCharges;
        foreach (h; 0 .. 14) {
            preShiftCharges ~= mode[v][h][2];
            preShiftCharges ~= mode[v][h][3];
        }
        model.require(format("soc_ready_afternoon_van_%d", v), atLeast(3, preShiftCharges));
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 4: Battery Thermal Protection (No Consecutive DC Fast Charges)
    // ------------------------------------------------------------------------
    writeln("Adding Battery Thermal Protection (No Consecutive DC Fast)...");
    foreach (v; vans) {
        foreach (h; 0 .. NUM_HOURS - 1) {
            model.require(
                format("no_consec_dc_fast_%d_%d", v, h),
                implies(mode[v][h][3], logicalNot(mode[v][h+1][3]))
            );
        }
    }

    // ------------------------------------------------------------------------
    // SOFT PREFERENCES: Energy Cost & Solar PV Optimization
    // ------------------------------------------------------------------------
    writeln("Adding Time-of-Use & Solar PV Soft Preferences...");
    
    // Preference A: Peak Grid Tariff Avoidance (Hours 16..21)
    // Discourage fast/dc_fast charging during peak evening hours
    foreach (h; 16 .. 22) {
        foreach (v; vans) {
            model.medium(
                format("tou_avoid_dc_peak_%d_%d", v, h),
                logicalNot(mode[v][h][3]),
                10.0
            );
            model.medium(
                format("tou_avoid_fast_peak_%d_%d", v, h),
                logicalNot(mode[v][h][2]),
                5.0
            );
        }
    }

    // Preference B: Solar PV Self-Consumption Absorption (Hours 10..15)
    // Reward charging when solar generation is at maximum
    foreach (h; 10 .. 16) {
        foreach (v; vans) {
            // If van is not on delivery route, encourage fast/slow charging
            if (v < 6 && (h >= 8 && h < 14)) continue; // Van 0..5 on route
            model.medium(
                format("solar_charge_%d_%d", v, h),
                logicalNot(mode[v][h][0]), // Prefer non-idle
                8.0
            );
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
