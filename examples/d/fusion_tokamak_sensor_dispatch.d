// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Nuclear Fusion Tokamak Plasma Diagnostic & Magnetic Coil Array Dispatch
// ============================================================================
//
//  Models dynamic assignment of 16 diagnostic sensors across 16 toroidal vacuum
//  sectors over a 4-tick plasma discharge shot cycle in a tokamak reactor (ITER/SPARC).
//
//  Biophysical & Physics Constraints:
//  - 16 Toroidal Sectors (Sectors 2, 6, 10, 14 host high-energy Neutral Beam Injectors)
//  - 4 Discharge Time Ticks
//  - 16 Diagnostic Probes (Soft X-Ray, Thomson Scattering, Mirnov Probes, Bolometers)
//  - Neutral Beam Injector Radiation Shielding (No optical sensors in NBI sectors)
//  - MHD Instability Safety Margin (Mirnov probe quadrant coverage at every tick)
//  - Thermal Sensor Duty Cycles (No 3 consecutive ticks in the same sector)
//  - Superconducting Poloidal Magnetic Coil GF(2) Parity Circuit Balance
//
// ============================================================================

module fusion_tokamak_sensor_dispatch;

import reify;
import std.stdio;
import std.array : array;
import std.range : iota;
import std.format : format;
import std.conv : to;
import core.time : dur, seconds;

enum NUM_SECTORS = 16;
enum NUM_TICKS = 4;
enum NUM_SENSORS = 16;

bool isNbiSector(size_t sectorIdx) {
    return (sectorIdx % 4) == 2; // Sectors 2, 6, 10, 14
}

struct Sensor {
    size_t id;
    string name;
    string type; // "sxr", "ts", "mp", "bol"
}

void main() {
    writeln("==========================================================================");
    writeln("  Nuclear Fusion Tokamak Diagnostic Sensor Dispatch Benchmark");
    writeln("==========================================================================");
    writeln("Toroidal Sectors: ", NUM_SECTORS, " (4 NBI Heating Ports at Sectors 2, 6, 10, 14)");
    writeln("Discharge Time Horizon: ", NUM_TICKS, " ticks (100ms plasma shot window)");

    // Sensor suite catalog
    Sensor[] sensors;
    foreach (i; 0 .. 4) sensors ~= Sensor(sensors.length, format("sxr_%d", i), "sxr");
    foreach (i; 0 .. 4) sensors ~= Sensor(sensors.length, format("ts_%d", i), "ts");
    foreach (i; 0 .. 4) sensors ~= Sensor(sensors.length, format("mp_%d", i), "mp");
    foreach (i; 0 .. 4) sensors ~= Sensor(sensors.length, format("bol_%d", i), "bol");

    writeln("Total Diagnostic Sensors: ", sensors.length);
    writeln("Logical Decision Variables: ", sensors.length * NUM_SECTORS * NUM_TICKS, " boolean activation flags");
    stdout.flush();

    auto model = new Model("fusion-tokamak-sensor-dispatch");

    // Decision Variables: active[i][s][t] = true if sensor i is active in sector s at tick t
    BoolExpr[][][] active;
    active.length = NUM_SENSORS;
    foreach (i; 0 .. NUM_SENSORS) {
        active[i].length = NUM_SECTORS;
        foreach (s; 0 .. NUM_SECTORS) {
            active[i][s] = new BoolExpr[](NUM_TICKS);
            foreach (t; 0 .. NUM_TICKS) {
                active[i][s][t] = model.booleanVar(format("active[%s,sec%d,t%d]", sensors[i].name, s, t));
            }
        }
    }

    // HARD CONSTRAINT 1: Sensor Uniqueness (At most 1 sector per sensor per tick)
    foreach (i; 0 .. NUM_SENSORS) {
        foreach (t; 0 .. NUM_TICKS) {
            BoolExpr[] sectorsForSensor;
            foreach (s; 0 .. NUM_SECTORS) {
                sectorsForSensor ~= active[i][s][t];
            }
            model.require(
                format("unique_sector_sensor%d_t%d", i, t),
                atMost(1, sectorsForSensor)
            );
        }
    }

    // HARD CONSTRAINT 2: NBI High-Energy Radiation Shielding Exclusions
    foreach (i; 0 .. NUM_SENSORS) {
        if (sensors[i].type == "sxr" || sensors[i].type == "bol") {
            foreach (s; 0 .. NUM_SECTORS) {
                if (isNbiSector(s)) {
                    foreach (t; 0 .. NUM_TICKS) {
                        model.require(
                            format("nbi_shielding_sensor%d_sec%d_t%d", i, s, t),
                            logicalNot(active[i][s][t])
                        );
                    }
                }
            }
        }
    }

    // HARD CONSTRAINT 3: MHD Instability Quadrant Coverage (Mirnov Probes)
    foreach (t; 0 .. NUM_TICKS) {
        foreach (quad; 0 .. 4) {
            BoolExpr[] quadProbes;
            foreach (s; quad * 4 .. (quad + 1) * 4) {
                foreach (i; 0 .. NUM_SENSORS) {
                    if (sensors[i].type == "mp") {
                        quadProbes ~= active[i][s][t];
                    }
                }
            }
            model.require(
                format("mhd_quad_coverage_q%d_t%d", quad, t),
                atLeast(1, quadProbes)
            );
        }
    }

    // HARD CONSTRAINT 4: Thermal Sensor Duty Cycles
    foreach (i; 0 .. NUM_SENSORS) {
        foreach (s; 0 .. NUM_SECTORS) {
            foreach (t; 0 .. NUM_TICKS - 2) {
                model.require(
                    format("thermal_cooldown_sensor%d_sec%d_t%d", i, s, t),
                    logicalNot(active[i][s][t] & active[i][s][t+1] & active[i][s][t+2])
                );
            }
        }
    }

    // HARD CONSTRAINT 5: Superconducting Poloidal Magnetic Coil GF(2) Parity Balance
    foreach (t; 0 .. NUM_TICKS) {
        BoolExpr[] evenSectorActivations;
        foreach (i; 0 .. NUM_SENSORS) {
            foreach (s; 0 .. NUM_SECTORS) {
                if (s % 2 == 0) {
                    evenSectorActivations ~= active[i][s][t];
                }
            }
        }
        model.requireParity(format("poloidal_field_parity_t%d", t), evenSectorActivations, false);
    }

    // COMPILATION
    writeln("\nCompiling model via Reify Decision Compiler...");
    stdout.flush();
    CompileOptions opts;
    opts.maxBddNodesPerConstraint = 10_000_000;
    auto compiled = compile(model, opts);

    writeln("\n=== Compilation Summary ===");
    writeln(compiled.summary().toPrettyString());
    stdout.flush();

    // SOLVE VIA NAVOKOJ SOLVER ENGINE
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
