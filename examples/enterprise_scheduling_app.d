module enterprise_scheduling_app;

import reify;
import std.stdio;
import std.array : array;
import std.range : iota;
import std.format : format;
import std.conv : to;
import core.time : dur, seconds;

enum NUM_NURSES = 100;
enum NUM_DAYS = 30;
enum NUM_SHIFTS = 4;  // 0=morning, 1=day, 2=evening, 3=night

void main() {
    writeln("=== Enterprise Hospital Scheduling ===");
    writeln("Nurses: ", NUM_NURSES);
    writeln("Days: ", NUM_DAYS);
    writeln("Shifts per day: ", NUM_SHIFTS);
    writeln("Logical variables: ", NUM_NURSES * NUM_DAYS * NUM_SHIFTS);

    auto model = new Model("enterprise-hospital");

    auto nurses = iota(0, NUM_NURSES).array;
    auto days = iota(0, NUM_DAYS).array;
    auto shifts = iota(0, NUM_SHIFTS).array;

    writeln("\nCreating variables...");
    BoolExpr[][][] works;
    works.length = NUM_NURSES;
    foreach (n; nurses) {
        works[n] = new BoolExpr[][](NUM_DAYS, NUM_SHIFTS);
        foreach (d; days) {
            foreach (s; shifts) {
                auto name = format("w[%d,%d,%d]", n, d, s);
                works[n][d][s] = model.booleanVar(name);
            }
        }
    }
    writeln("Total boolean variables: ", NUM_NURSES * NUM_DAYS * NUM_SHIFTS);

    // CONSTRAINT 1: Each shift needs 5-12 nurses
    writeln("\nAdding shift coverage constraints...");
    foreach (d; days) {
        foreach (s; shifts) {
            BoolExpr[] onShift;
            foreach (n; nurses) onShift ~= works[n][d][s];
            model.require(format("cov_min_%d_%d", d, s),
                         atLeast(5, onShift));
            model.require(format("cov_max_%d_%d", d, s),
                         atMost(12, onShift));
        }
    }

    // CONSTRAINT 2: Each nurse at most 1 shift per day
    writeln("Adding per-day uniqueness...");
    foreach (n; nurses) {
        foreach (d; days) {
            BoolExpr[] dayShifts;
            foreach (s; shifts) dayShifts ~= works[n][d][s];
            model.require(format("atmost1_%d_%d", n, d),
                         atMostOne(dayShifts));
        }
    }

    // CONSTRAINT 3: Max 20 shifts per nurse over the period
    writeln("Adding total shift caps...");
    foreach (n; nurses) {
        BoolExpr[] allShifts;
        foreach (d; days) {
            foreach (s; shifts) allShifts ~= works[n][d][s];
        }
        model.require(format("max_shifts_%d", n),
                     atMost(20, allShifts));
    }

    // CONSTRAINT 4: Min 4 rest days per nurse
    writeln("Adding rest day requirements...");
    foreach (n; nurses) {
        BoolExpr[] worksDay;
        foreach (d; days) {
            BoolExpr[] dayShifts;
            foreach (s; shifts) dayShifts ~= works[n][d][s];
            worksDay ~= atLeastOne(dayShifts);
        }
        // Prefer at least 4 rest days (soft)
        model.medium(format("rest_days_%d", n),
                    atMost(cast(size_t)(NUM_DAYS - 4), worksDay),
                    5.0);
    }

    // CONSTRAINT 5: No night-to-morning transitions
    writeln("Adding shift transition rules...");
    foreach (n; nurses) {
        foreach (d; 0 .. NUM_DAYS - 1) {
            model.require(format("no_nm_%d_%d", n, d),
                         implies(works[n][d][3], logicalNot(works[n][d+1][0])));
            // No evening-to-morning transitions
            model.require(format("no_em_%d_%d", n, d),
                         implies(works[n][d][2], logicalNot(works[n][d+1][0])));
        }
    }

    // CONSTRAINT 6: No 4 consecutive shifts
    writeln("Adding consecutive work limits...");
    foreach (n; nurses) {
        foreach (d; 0 .. NUM_DAYS - 3) {
            BoolExpr[] fourDays;
            foreach (offset; 0 .. 4) {
                BoolExpr[] dayShifts;
                foreach (s; shifts) dayShifts ~= works[n][d+offset][s];
                fourDays ~= atLeastOne(dayShifts);
            }
            // Soft: avoid 4 consecutive work days
            model.medium(format("rest_every_4_%d_%d", n, d),
                        exactly(cast(size_t)4, fourDays),
                        10.0);
        }
    }

    // CONSTRAINT 7: Skill matching - senior nurses (indices 0-19) prefer night shifts
    writeln("Adding skill matching...");
    foreach (d; days) {
        BoolExpr[] seniorsOnNight;
        foreach (n; 0 .. 20) {
            seniorsOnNight ~= works[n][d][3];
        }
        // Prefer at least 3 senior nurses on night shift
        model.medium(format("senior_night_%d", d),
                    atLeast(cast(size_t)3, seniorsOnNight),
                    8.0);
    }

    writeln("\nCompiling model...");
    CompileOptions opts;
    opts.maxBddNodesPerConstraint = 50_000_000;  // Large for hard problem
    auto compiled = compile(model, opts);

    writeln("\n=== Compilation Summary ===");
    writeln(compiled.summary().toPrettyString());

    // Save CNF request
    import std.file : write;
    write("examples/enterprise-scheduling.request.json", compiled.request.toPrettyString());
    writeln("Request written to examples/enterprise-scheduling.request.json");

    // Solve via Navokoj
    writeln("\n=== Solving via Navokoj ===");
    import std.process : environment;

    string apiKey = environment.get("NAVOKOJ_API_KEY", "");
    if (apiKey.length == 0) {
        writeln("Set NAVOKOJ_API_KEY to solve");
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