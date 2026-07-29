// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Reify SDK Benchmark: Autonomous Satellite Orbital Payload & Power Dispatch
// ============================================================================
//
//  Problem Domain:
//    - 12 Orbital Time Steps alternating between Sunlit and Eclipse phases
//    - Battery State-of-Charge (SoC) management across orbital ticks
//    - Onboard SSD Buffer Storage & Downlink Ground-Station Window Allocation
//    - Thermal Non-Overlap Rules (e.g. SAR & Optical Telescope cannot co-operate)
//    - Multi-Tiered Soft Science Objectives solved via Navokoj Nitro Engine
//
// ============================================================================

module satellite_orbital_dispatch;

import reify;
import std.conv : to;
import std.format : format;
import std.process : environment;
import std.stdio : writefln, writeln;

struct PayloadInfo {
    string id;
    string name;
    int powerDraw;     // Watts/units per tick
    int dataRate;      // GB/tick (positive = generate, negative = downlink)
    double scienceWeight;
    bool isThermalHeavy;
    int[] visibilityTicks;
}

int main(string[] args) {
    writeln("==========================================================================");
    writeln("  Reify SDK Benchmark: Autonomous Satellite Orbital Payload Dispatch");
    writeln("==========================================================================");

    enum int NUM_TICKS = 12;
    enum int BASE_POWER_DRAW = 10;
    enum int BATTERY_MIN = 20;   // 20% safe reserve floor
    enum int BATTERY_MAX = 100;  // 100% capacity ceiling
    enum int BATTERY_INIT = 80;  // Initial 80% charge
    enum int SSD_CAPACITY = 200; // 200 GB SSD storage buffer cap

    // Solar generation profile per tick (Sunlit = 35 power units, Eclipse = 0 power units)
    int[NUM_TICKS] solarGen = [
        35, 35, 35, 35, // Ticks 0-3: Sunlit phase
         0,  0,  0,  0, // Ticks 4-7: Eclipse phase
        35, 35, 35, 35  // Ticks 8-11: Sunlit phase
    ];

    PayloadInfo[] payloads = [
        PayloadInfo("sar", "Synthetic Aperture Radar", 40,  50, 4.0, true,  [2, 6, 10]),
        PayloadInfo("hsi", "Hyperspectral Imager",     25,  35, 3.0, false, [1, 5, 9]),
        PayloadInfo("opt", "Optical High-Res Camera", 30,  40, 3.5, true,  [0, 3, 7, 11]),
        PayloadInfo("tx",  "Ka-Band Downlink Tx",     20, -60, 2.0, false, [3, 7, 11]) // Clears 60GB data
    ];

    auto model = new Model("satellite_orbital_dispatch");

    // 1. DECISION VARIABLES
    // active[p][t] = True if payload p is operational at orbital tick t
    BoolExpr[][string] activeVars;
    foreach (payload; payloads) {
        activeVars[payload.id] = new BoolExpr[](NUM_TICKS);
        foreach (t; 0 .. NUM_TICKS) {
            activeVars[payload.id][t] = model.booleanVar(format("active_%s_t%02d", payload.id, t));
        }
    }

    // 2. HARD CONSTRAINTS: VISIBILITY WINDOWS & THERMAL NON-OVERLAP
    foreach (payload; payloads) {
        foreach (t; 0 .. NUM_TICKS) {
            bool isVisible = false;
            foreach (v; payload.visibilityTicks) {
                if (v == t) { isVisible = true; break; }
            }
            if (!isVisible) {
                // Force active = false outside payload visibility window
                model.require(format("vis_gate_%s_t%02d", payload.id, t), ~activeVars[payload.id][t]);
            }
        }
    }

    // Thermal safety: SAR and OPT high-thermal payloads cannot run simultaneously
    foreach (t; 0 .. NUM_TICKS) {
        model.require(
            format("thermal_safety_t%02d", t),
            ~(activeVars["sar"][t] & activeVars["opt"][t])
        );
    }

    // 3. HARD CONSTRAINTS: CUMULATIVE ENERGY BALANCE & SSD BUFFER CAPACITY
    IntExpr[] socAtTick;
    IntExpr[] bufferAtTick;

    // Helper cumulative power & solar counters
    int cumulativeSolar = 0;

    foreach (t; 0 .. NUM_TICKS + 1) {
        if (t > 0) {
            cumulativeSolar += solarGen[t - 1];
        }

        // Calculate cumulative power drain up to tick t
        IntExpr cumPowerDrain = integer(cast(long) (10 * t)); // Base draw
        IntExpr cumDataGen = integer(0);

        foreach (payload; payloads) {
            foreach (k; 0 .. t) {
                cumPowerDrain = cumPowerDrain + asInteger(activeVars[payload.id][k]) * payload.powerDraw;
                cumDataGen = cumDataGen + asInteger(activeVars[payload.id][k]) * payload.dataRate;
            }
        }

        IntExpr currentSoc = integer(BATTERY_INIT) + integer(cumulativeSolar) - cumPowerDrain;
        IntExpr currentBuffer = cumDataGen;

        socAtTick ~= currentSoc;
        bufferAtTick ~= currentBuffer;

        // Enforce battery boundaries [BATTERY_MIN, BATTERY_MAX]
        model.require(format("soc_min_t%02d", t), greaterEqual(currentSoc, integer(BATTERY_MIN)));
        model.require(format("soc_max_t%02d", t), lessEqual(currentSoc, integer(BATTERY_MAX)));

        // Enforce SSD Buffer storage boundaries [0, SSD_CAPACITY]
        model.require(format("buffer_min_t%02d", t), greaterEqual(currentBuffer, integer(0)));
        model.require(format("buffer_max_t%02d", t), lessEqual(currentBuffer, integer(SSD_CAPACITY)));
    }

    // 4. SOFT OBJECTIVES: MAXIMIZE SCIENCE YIELD & MAINTAIN BATTERY HEALTH
    foreach (payload; payloads) {
        if (payload.id == "tx") continue; // Science payloads only
        foreach (t; 0 .. NUM_TICKS) {
            model.prefer(
                format("science_target_%s_t%02d", payload.id, t),
                activeVars[payload.id][t],
                payload.scienceWeight
            );
        }
    }

    // Soft objective: Prefer maintaining battery level >= 50% during Eclipse phase (ticks 4..7)
    foreach (t; 4 .. 8) {
        model.prefer(format("eclipse_battery_health_t%02d", t), greaterEqual(socAtTick[t], integer(50)), 2.0);
    }

    // 5. COMPILATION & TOPOLOGY ANALYSIS
    CompileOptions opts;
    auto compiled = compile(model, opts);

    writeln("\n--------------------------------------------------------------------------");
    writeln("  Compiler Topology & Lowering Analysis");
    writeln("--------------------------------------------------------------------------");
    writefln("  Backend Selected:    %s", compiled.backend);
    writefln("  Logical Variables:   %d", model.variables.length);
    writefln("  Encoded SAT Vars:    %d", compiled.generatedVariableCount);
    writefln("  Encoded CNF Clauses:  %d", compiled.clauses.length);
    writeln("--------------------------------------------------------------------------\n");

    // 6. SOLVE VIA NAVOKOJ API & LOCAL RE-VERIFICATION
    string apiKey = environment.get("NAVOKOJ_API_KEY", "nvkj_api_369299b8ae2b177dc03795d234b63865");
    if (apiKey.length > 0) {
        writeln("Submitting orbital dispatch model to Navokoj Nitro engine...");
        RequestOptions reqOpts;
        reqOpts.apiKey = apiKey;

        auto client = new NavokojClient();
        RoutingRecommendation rec;
        rec.engine = "nitro";
        rec.hardware = "cpu";

        SolveResult result = client.solve(compiled, reqOpts, rec);

        writeln("\n==========================================================================");
        writeln("  Navokoj Solver Manifest & Verification Report");
        writeln("==========================================================================");
        writefln("  Status:               %s", result.status);
        writefln("  Hard Constraints:     %d / %d satisfied", 
            result.verification.hardSatisfied, 
            result.verification.hardSatisfied + result.verification.hardViolated);
        writefln("  Server Satisfaction:  %.2f%%", result.server.satisfactionRate * 100.0);
        writefln("  Server Solve Time:    %d ms", cast(int)(result.server.solveTimeSeconds * 1000));
        writeln("--------------------------------------------------------------------------");

        // Compute hydrated values locally from solution assignment
        writeln("\n🛰️  Orbital Payload Dispatch Schedule (12 Ticks):");
        writeln(" Tick | Phase   | Solar | Battery SoC | SSD Buffer | Active Payloads");
        writeln("------+---------+-------+-------------+------------+----------------------------------");

        int cumSol = 0;
        int cumDrain = 0;
        int cumData = 0;

        for (int t = 0; t < NUM_TICKS; t++) {
            string phaseStr = (t >= 4 && t <= 7) ? "Eclipse " : "Sunlit  ";
            cumSol += solarGen[t];
            cumDrain += BASE_POWER_DRAW;

            string[] activeList;
            foreach (payload; payloads) {
                string key = format("active_%s_t%02d", payload.id, t);
                if (result.solution.has(key) && 
                    result.solution.get(key).status == DecisionStatus.assigned && 
                    result.solution.get(key).booleanValue) {
                    activeList ~= payload.id;
                    cumDrain += payload.powerDraw;
                    cumData += payload.dataRate;
                }
            }

            int currentSocVal = BATTERY_INIT + cumSol - cumDrain;
            int currentBufVal = cumData;

            string activeStr = activeList.length > 0 ? activeList.to!string : "[idle]";
            writefln("  %02d  | %s |  +%02dW |    %03d%%    |   %03d GB   | %s",
                t, phaseStr, solarGen[t], currentSocVal, currentBufVal, activeStr);
        }

        writeln("--------------------------------------------------------------------------");
        if (result.verification.hardViolated == 0) {
            writeln("✅ Success: All orbital energy, SSD storage, and thermal safety rules 100% verified!");
        } else {
            writeln("❌ Verification Failure: Hard constraint violations detected!");
        }
    } else {
        writeln("NAVOKOJ_API_KEY environment variable not set. Lowering and model build succeeded.");
    }

    return 0;
}
