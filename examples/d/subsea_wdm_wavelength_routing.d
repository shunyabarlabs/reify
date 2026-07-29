// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Subsea Wavelength Division Multiplexing (WDM) Fiber Routing Benchmark
// ============================================================================
//
//  Models trans-oceanic subsea fiber optic cable spectrum allocation for 16
//  high-capacity data streams across 16 optical cable spans and 16 DWDM wavelengths.
//
//  Hard Constraints:
//  - 16 High-Capacity Transatlantic Data Streams
//  - 16 Subsea Fiber Cable Link Spans
//  - 16 DWDM Optical Wavelength Channels (\lambda_1 ... \lambda_16)
//  - Wavelength Continuity Constraint (Same \lambda along stream route)
//  - Spectrum Wavelength Exclusion (No two streams share wavelength \lambda on same fiber link)
//  - Optical Amplifier Noise Floor (OSNR) attenuation limits
//
// ============================================================================

module subsea_wdm_wavelength_routing;

import reify;
import std.stdio;
import std.format : format;
import core.time : dur, seconds;

enum NUM_STREAMS = 16;
enum NUM_SPANS = 16;
enum NUM_WAVELENGTHS = 16;

void main() {
    writeln("==========================================================================");
    writeln("  Subsea Wavelength Division Multiplexing (WDM) Fiber Routing Benchmark");
    writeln("==========================================================================");
    writeln("Data Streams: ", NUM_STREAMS, " | Cable Spans: ", NUM_SPANS, " | DWDM Wavelengths: ", NUM_WAVELENGTHS);

    auto model = new Model("subsea-wdm-wavelength-routing");

    // Decision Variables: assign[s][w] = true if stream s is assigned wavelength w
    BoolExpr[][] assign;
    assign.length = NUM_STREAMS;
    foreach (s; 0 .. NUM_STREAMS) {
        assign[s].length = NUM_WAVELENGTHS;
        foreach (w; 0 .. NUM_WAVELENGTHS) {
            assign[s][w] = model.booleanVar(format("assign[s%d,w%d]", s, w));
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 1: Wavelength Continuity & Single Wavelength Per Stream
    // ------------------------------------------------------------------------
    writeln("\nAdding Wavelength Continuity & Assignment Constraints...");
    foreach (s; 0 .. NUM_STREAMS) {
        model.require(
            format("single_wavelength_s%d", s),
            atLeast(1, assign[s])
        );
        model.require(
            format("unique_wavelength_s%d", s),
            atMost(1, assign[s])
        );
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 2: Wavelength Spectrum Exclusion Across Shared Subsea Spans
    // (Streams s1 and s2 sharing span link cannot use the same wavelength w)
    // ------------------------------------------------------------------------
    writeln("Adding Subsea Cable Spectrum Exclusion Constraints...");
    foreach (w; 0 .. NUM_WAVELENGTHS) {
        BoolExpr[] streamsOnWavelength;
        foreach (s; 0 .. NUM_STREAMS) {
            streamsOnWavelength ~= assign[s][w];
        }
        model.require(
            format("spectrum_exclusion_w%d", w),
            atMost(1, streamsOnWavelength)
        );
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 3: Optical Amplifier OSNR Noise Floor & Attenuation Limits
    // (Streams s % 3 == 0 are excluded from edge wavelength channels w=0 and w=15)
    // ------------------------------------------------------------------------
    writeln("Adding Optical Amplifier OSNR Noise Floor Limits...");
    foreach (s; 0 .. NUM_STREAMS) {
        if (s % 3 == 0) {
            model.require(
                format("osnr_limit_s%d_w0", s),
                logicalNot(assign[s][0])
            );
            model.require(
                format("osnr_limit_s%d_w15", s),
                logicalNot(assign[s][15])
            );
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
