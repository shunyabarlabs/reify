module test_scaling;

import reify;
import std.stdio;
import std.array : array;
import std.range : iota;
import std.format : format;
import std.conv : to;
import core.time : dur, seconds;

enum N = 90;   // nurses
enum D = 20;   // days
enum S = 3;    // shifts

void main() {
    writeln("=== Scaling test: ", N, " nurses × ", D, " days × ", S, " shifts ===");
    auto model = new Model("scaling");

    auto nurses = iota(0, N).array;
    auto days = iota(0, D).array;
    auto shifts = iota(0, S).array;

    BoolExpr[][][] works;
    works.length = N;
    foreach (n; nurses) {
        works[n] = new BoolExpr[][](D, S);
        foreach (d; days) {
            foreach (s; shifts) {
                works[n][d][s] = model.booleanVar(format("w[%d,%d,%d]", n, d, s));
            }
        }
    }

    // Coverage: each shift 4-8 nurses
    foreach (d; days) {
        foreach (s; shifts) {
            BoolExpr[] onShift;
            foreach (n; nurses) onShift ~= works[n][d][s];
            model.require(format("cov_min_%d_%d", d, s), atLeast(4, onShift));
            model.require(format("cov_max_%d_%d", d, s), atMost(8, onShift));
        }
    }

    // Per-day uniqueness
    foreach (n; nurses) {
        foreach (d; days) {
            BoolExpr[] dayShifts;
            foreach (s; shifts) dayShifts ~= works[n][d][s];
            model.require(format("atmost1_%d_%d", n, d), atMostOne(dayShifts));
        }
    }

    // Max shifts
    foreach (n; nurses) {
        BoolExpr[] all;
        foreach (d; days) foreach (s; shifts) all ~= works[n][d][s];
        model.require(format("max_%d", n), atMost(15, all));
    }

    writeln("Compiling...");
    CompileOptions opts;
    opts.maxBddNodesPerConstraint = 50_000_000;
    auto compiled = compile(model, opts);
    writeln(compiled.summary().toPrettyString());

    writeln("\n=== Solving via Navokoj ===");
    import std.process : environment;
    import std.file : write;

    string apiKey = environment.get("NAVOKOJ_API_KEY", "");
    if (apiKey.length == 0) {
        writeln("Set NAVOKOJ_API_KEY to solve");
        return;
    }

    import reify.navokoj.client : NavokojClient, RequestOptions;
    import reify.router : RoutingRecommendation;

    RequestOptions reqOpts;
    reqOpts.apiKey = apiKey;
    reqOpts.transportTimeout = dur!"seconds"(180);

    auto client = new NavokojClient();
    RoutingRecommendation rec;
    rec.engine = "nitro";
    rec.hardware = "cpu";

    auto result = client.solveRaw(compiled, reqOpts, rec);
    writeln(result.toPrettyString());
}