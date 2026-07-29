// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Hypersonic Glide Interception & Radar-Shooter Assignment Benchmark
// ============================================================================
//
//  Models Mach 8+ Hypersonic Glide Vehicle (HGV) interception track matching,
//  Phased-Array Doppler Radar sector assignment, thermal seeker cooldowns,
//  and native GF(2) 360-degree perimeter shield coverage parity.
//
//  Hard Constraints:
//  - 12 Hypersonic Glide Targets (Mach 8-12 trajectories)
//  - 16 Surface-to-Air Interceptor Batteries (THAAD / Aegis / Patriot PAC-3)
//  - 8 Phased-Array Radars across 16 sector quadrants
//  - Radar Doppler beam concurrency caps (max 2 targets per radar)
//  - Single interceptor battery assignment per target
//  - Thermal seeker sensor cooldown bounds
//  - Native GF(2) XOR Parity 360-degree perimeter shield balance
//
// ============================================================================

module hypersonic_intercept_dispatch;

import reify;
import std.stdio;
import std.format : format;
import core.time : dur, seconds;

enum NUM_TARGETS = 12;      // Mach 8-12 HGVs
enum NUM_BATTERIES = 16;    // Interceptor SAM batteries
enum NUM_RADARS = 8;        // Phased array radar tracking units
enum NUM_SECTORS = 16;      // 360-degree perimeter defense sectors

void main() {
    writeln("==========================================================================");
    writeln("  Hypersonic Glide Interception & Radar-Shooter Assignment Benchmark");
    writeln("==========================================================================");
    writeln("Targets: ", NUM_TARGETS, " HGVs | Batteries: ", NUM_BATTERIES, " SAMs | Radars: ", NUM_RADARS, " | Sectors: ", NUM_SECTORS);

    auto model = new Model("hypersonic-intercept-dispatch");

    // Decision Variables:
    // intercept[t][b] = true if battery b is launched at target t
    BoolExpr[][] intercept;
    intercept.length = NUM_TARGETS;
    foreach (t; 0 .. NUM_TARGETS) {
        intercept[t].length = NUM_BATTERIES;
        foreach (b; 0 .. NUM_BATTERIES) {
            intercept[t][b] = model.booleanVar(format("intercept[t%d,b%d]", t, b));
        }
    }

    // radarTrack[t][r] = true if radar r is tracking target t
    BoolExpr[][] radarTrack;
    radarTrack.length = NUM_TARGETS;
    foreach (t; 0 .. NUM_TARGETS) {
        radarTrack[t].length = NUM_RADARS;
        foreach (r; 0 .. NUM_RADARS) {
            radarTrack[t][r] = model.booleanVar(format("radarTrack[t%d,r%d]", t, r));
        }
    }

    // sectorParity[sec] = true if sector sec has active shield coverage
    BoolExpr[] sectorParity;
    sectorParity.length = NUM_SECTORS;
    foreach (sec; 0 .. NUM_SECTORS) {
        sectorParity[sec] = model.booleanVar(format("sectorParity[sec%d]", sec));
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 1: Single Interceptor Assignment Per Target
    // ------------------------------------------------------------------------
    writeln("\nAdding Single Interceptor Battery Assignment Constraints...");
    foreach (t; 0 .. NUM_TARGETS) {
        model.require(
            format("single_interceptor_target%d", t),
            atLeast(1, intercept[t])
        );
        model.require(
            format("unique_interceptor_target%d", t),
            atMost(1, intercept[t])
        );
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 2: Radar Tracking Assignment & Beam Concurrency Caps
    // (Each target must be tracked by at least 1 radar; radar r tracks max 2 targets)
    // ------------------------------------------------------------------------
    writeln("Adding Radar Tracking & Beam Concurrency Cap Constraints...");
    foreach (t; 0 .. NUM_TARGETS) {
        model.require(
            format("radar_assigned_target%d", t),
            atLeast(1, radarTrack[t])
        );
    }

    foreach (r; 0 .. NUM_RADARS) {
        BoolExpr[] targetsForRadar;
        foreach (t; 0 .. NUM_TARGETS) {
            targetsForRadar ~= radarTrack[t][r];
        }
        model.require(
            format("radar_concurrency_r%d", r),
            atMost(2, targetsForRadar)
        );
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 3: Battery Thermal Seeker Cooldown
    // (Battery b can intercept at most 1 target per engagement window)
    // ------------------------------------------------------------------------
    writeln("Adding Battery Thermal Seeker Cooldown Constraints...");
    foreach (b; 0 .. NUM_BATTERIES) {
        BoolExpr[] targetsForBattery;
        foreach (t; 0 .. NUM_TARGETS) {
            targetsForBattery ~= intercept[t][b];
        }
        model.require(
            format("battery_cooldown_b%d", b),
            atMost(1, targetsForBattery)
        );
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 4: Native GF(2) 360-Degree Sector Shield Parity Balance
    // ------------------------------------------------------------------------
    writeln("Adding Native GF(2) Sector Shield Parity Constraints...");
    foreach (sec; 0 .. NUM_SECTORS) {
        size_t b1 = sec % NUM_BATTERIES;
        size_t b2 = (sec + 1) % NUM_BATTERIES;
        size_t r1 = sec % NUM_RADARS;

        // Native GF(2) XOR parity constraint: sum([sectorParity[sec], intercept[0][b1], intercept[1][b2], radarTrack[0][r1]]) % 2 == 0
        model.requireParity(
            format("sector_parity_sec%d", sec),
            [sectorParity[sec], intercept[0][b1], intercept[1][b2], radarTrack[0][r1]],
            0
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
    writeln("\n=== Solving via Navokoj Solver Substrate ===");
    stdout.flush();
    import std.process : environment;

    string apiKey = environment.get("NAVOKOJ_API_KEY", "");
    if (apiKey.length == 0) return;

    import reify.navokoj.client : NavokojClient, RequestOptions;
    import reify.router : RoutingRecommendation;
    import reify.errors : ApiException;

    RequestOptions reqOpts;
    reqOpts.apiKey = apiKey;
    reqOpts.transportTimeout = dur!"seconds"(120);

    auto client = new NavokojClient();

    RoutingRecommendation rec;
    rec.engine = "nitro";
    rec.hardware = "cpu";

    try {
        auto result = client.solveRaw(compiled, reqOpts, rec);
        writeln("\n=== Navokoj Response ===");
        writeln(result.toPrettyString());
        stdout.flush();
    } catch (ApiException e) {
        writeln("\nStatus Code: ", e.statusCode);
        writeln("API Error Raw Body: ", e.rawBody);
        stdout.flush();
    }
}
