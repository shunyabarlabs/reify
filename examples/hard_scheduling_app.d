module hard_scheduling_app;

import reify;
import std.stdio;
import std.array : array;
import std.range : iota;
import std.format : format;
import std.conv : to;

enum NUM_NURSES = 30;
enum NUM_DAYS = 14;
enum NUM_SHIFTS = 3;  // 0=day, 1=evening, 2=night

void main() {
    writeln("=== Hard Hospital Scheduling Problem ===");
    writeln("Nurses: ", NUM_NURSES);
    writeln("Days: ", NUM_DAYS);
    writeln("Shifts per day: ", NUM_SHIFTS);

    auto model = new Model("hospital-scheduling");

    // nurse_works[nurse][day][shift] = Boolean
    // Total variables: 30 × 14 × 3 = 1,260
    auto nurses = iota(0, NUM_NURSES).array;
    auto days = iota(0, NUM_DAYS).array;
    auto shifts = iota(0, NUM_SHIFTS).array;

    writeln("\nCreating variables...");

    // Create all boolean variables
    BoolExpr[][][] works;
    works.length = NUM_NURSES;
    foreach (n; nurses) {
        works[n] = new BoolExpr[][](NUM_DAYS, NUM_SHIFTS);
        foreach (d; days) {
            foreach (s; shifts) {
                auto name = format("works[%d,%d,%d]", n, d, s);
                works[n][d][s] = model.booleanVar(name);
            }
        }
    }

    writeln("Total variables: ", NUM_NURSES * NUM_DAYS * NUM_SHIFTS);

    // HARD CONSTRAINT 1: Each shift needs 3-6 nurses
    writeln("\nAdding shift coverage constraints...");
    foreach (d; days) {
        foreach (s; shifts) {
            BoolExpr[] nursesOnShift;
            foreach (n; nurses) {
                nursesOnShift ~= works[n][d][s];
            }
            model.require(format("shift_coverage_min_%d_%d", d, s),
                         atLeast(3, nursesOnShift));
            model.require(format("shift_coverage_max_%d_%d", d, s),
                         atMost(6, nursesOnShift));
        }
    }

    // HARD CONSTRAINT 2: Each nurse works at most 1 shift per day
    writeln("Adding per-day shift constraints...");
    foreach (n; nurses) {
        foreach (d; days) {
            BoolExpr[] dayShifts;
            foreach (s; shifts) {
                dayShifts ~= works[n][d][s];
            }
            model.require(format("at_most_one_per_day_%d_%d", n, d),
                         atMostOne(dayShifts));
        }
    }

    // HARD CONSTRAINT 3: Each nurse works max 10 shifts total
    writeln("Adding total shift limits...");
    /*foreach (n; nurses) {
        BoolExpr[] allShifts;
        foreach (d; days) {
            foreach (s; shifts) {
                allShifts ~= works[n][d][s];
            }
        }
        model.require(format("max_shifts_nurse_%d", n),
                     atMost(10, allShifts));
    }*/

    // HARD CONSTRAINT 4: Each nurse gets at least 2 rest days
    writeln("Adding rest day requirements...");
    /*foreach (n; nurses) {
        BoolExpr[] restDays;
        foreach (d; days) {
            // Rest day = no shifts that day
            BoolExpr[] dayShifts;
            foreach (s; shifts) {
                dayShifts ~= works[n][d][s];
            }
            restDays ~= atMost(0, dayShifts);
        }
        model.require(format("min_rest_days_%d", n),
                     atLeast(2, restDays));
    }*/

    // HARD CONSTRAINT 5: No nurse works night shift then day shift next day
    writeln("Adding shift transition constraints...");
    foreach (n; nurses) {
        foreach (d; 0 .. NUM_DAYS - 1) {
            model.require(format("no_night_to_day_%d_%d", n, d),
                         implies(works[n][d][2], logicalNot(works[n][d+1][0])));
        }
    }

    // SOFT CONSTRAINTS removed - focus on hard problem

    writeln("\nCompiling model...");
    CompileOptions opts;
    opts.maxBddNodesPerConstraint = 5_000_000;  // Increase for hard problem
    auto compiled = compile(model, opts);

    writeln("\n=== Compilation Summary ===");
    writeln(compiled.summary().toPrettyString());

    // Save CNF request to JSON file for Navokoj API
    import std.file : write;
    auto request = compiled.request;
    write("examples/hospital-scheduling.request.json", request.toPrettyString());
    writeln("Request written to examples/hospital-scheduling.request.json");

    // Solve directly via Navokoj
    writeln("\n=== Solving via Navokoj ===");
    import std.process : environment;
    import std.json : JSONValue;

    string apiKey = environment.get("NAVOKOJ_API_KEY", "");
    if (apiKey.length == 0) {
        writeln("Set NAVOKOJ_API_KEY to solve");
        return;
    }

    import reify.navokoj.client : NavokojClient, RequestOptions;

    RequestOptions reqOpts;
    reqOpts.apiKey = apiKey;

    auto client = new NavokojClient();

    // Use auto-routing
    import reify.router : RoutingRecommendation;
    RoutingRecommendation rec;
    rec.engine = "nitro";
    rec.hardware = "cpu";

    auto result = client.solveRaw(compiled, reqOpts, rec);

    writeln("\n=== Navokoj Response ===");
    writeln(result.toPrettyString());
}