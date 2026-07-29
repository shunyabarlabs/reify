// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

/**
 * Very hard problem: random 3-SAT at the phase transition.
 *
 * The clause-to-variable ratio alpha = M / N = 4.267 is the critical
 * threshold of random 3-SAT: instances are 50% SAT / 50% UNSAT, and
 * both classes lie on the NP-hard phase boundary where CDCL solvers
 * exhibit the longest runtimes observed in practice.
 *
 * Two instance sizes are generated and submitted:
 *   - medium: N=3000, M=12801
 *   - hard:   N=8000, M=34136
 *
 * Reproducibility: a fixed Mersenne Twister seed is used so the exact
 * instances are repeatable across runs.
 */

module very_hard;

import reify;
import std.algorithm : canFind;
import std.array : array;
import std.conv : to;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.process : environment;
import std.range : iota;
import std.random : Mt19937, uniform;
import std.stdio : writeln;
import core.time : MonoTime, dur, seconds;

import reify.navokoj.client : NavokojClient, RequestOptions;
import reify.router : RoutingRecommendation;

enum SEED = 20260729;

static void runInstance(string label, int nVars, int nClauses) {
    writeln("");
    writeln("---- ", label, " ----");
    writeln("Variables : ", nVars);
    writeln("Clauses   : ", nClauses);
    writeln("Alpha     : ", cast(double) nClauses / nVars);

    auto rng = Mt19937(SEED + nVars);
    auto model = new Model("random-3sat-" ~ label);

    // Build the boolean family via the indexed helpers.
    string[] keys;
    foreach (i; 0 .. nVars) keys ~= i.to!string;
    auto vs = model.booleanVars("v", keys);

    // Generate exactly-3 literal clauses with distinct variables.
    foreach (c; 0 .. nClauses) {
        size_t[3] picks;
        foreach (k; 0 .. 3) {
            while (true) {
                auto candidate = uniform(0, nVars, rng);
                bool duplicate;
                foreach (j; 0 .. k) {
                    if (picks[j] == candidate) { duplicate = true; break; }
                }
                if (!duplicate) { picks[k] = candidate; break; }
            }
        }
        BoolExpr[] literals;
        literals.reserve(3);
        foreach (k; 0 .. 3) {
            auto v = vs[picks[k].to!string];
            literals ~= (uniform(0, 2, rng) == 0) ? v : ~v;
        }
        model.requireClause(format("c%d", c), literals);
    }

    writeln("Compiling...");
    auto t1 = MonoTime.currTime;
    CompileOptions opts;
    opts.engine = "nitro";
    opts.maxBddNodesPerConstraint = 5_000_000;
    auto compiled = compile(model, opts);
    auto t2 = MonoTime.currTime;
    writeln("Compile time : ", (t2 - t1));

    JSONValue summary = compiled.summary();
    if (summary.type == JSONType.object) {
        foreach (key; ["variables", "clauses", "symbolic_constraints",
                       "parity_constraints", "objectives"]) {
            if (key in summary.object) {
                writeln("  ", key, " = ", summary[key]);
            }
        }
    }

    string apiKey = environment.get("NAVOKOJ_API_KEY", "");
    if (apiKey.length == 0) {
        writeln("ERROR: NAVOKOJ_API_KEY not set");
        return;
    }

    RequestOptions reqOpts;
    reqOpts.apiKey = apiKey;
    reqOpts.transportTimeout = dur!"seconds"(180);

    auto client = new NavokojClient();
    RoutingRecommendation rec;
    rec.engine = "nitro";
    rec.hardware = "cpu";

    writeln("Submitting to Navokoj (nitro / cpu)...");
    auto t3 = MonoTime.currTime;
    JSONValue raw;
    try {
        raw = client.solveRaw(compiled, reqOpts, rec);
    } catch (Exception error) {
        writeln("Submission failed: ", error.classinfo.name, " — ", error.msg);
        return;
    }
    auto t4 = MonoTime.currTime;
    writeln("Wall clock   : ", (t4 - t3));

    if (raw.type != JSONType.object) {
        writeln("Unexpected response type: ", raw.type);
        return;
    }

    if ("success" in raw.object)
        writeln("API success   : ", raw["success"]);
    if ("satisfiable" in raw.object)
        writeln("Satisfiable   : ", raw["satisfiable"]);
    if ("engine_used" in raw.object)
        writeln("Engine used   : ", raw["engine_used"]);
    if ("method" in raw.object)
        writeln("Method        : ", raw["method"]);
    if ("request_id" in raw.object)
        writeln("Request ID    : ", raw["request_id"]);
    if ("solve_time_seconds" in raw.object)
        writeln("Server solve  : ", raw["solve_time_seconds"], " s");
    if ("timeout_budget_hit" in raw.object)
        writeln("Timeout hit   : ", raw["timeout_budget_hit"]);

    if ("solution" in raw.object && raw["solution"].type == JSONType.object) {
        auto sol = raw["solution"];
        if ("satisfaction_rate" in sol.object)
            writeln("Satisfaction  : ", sol["satisfaction_rate"]);
        if ("assignment" in sol.object) {
            auto assign = sol["assignment"];
            if (assign.type == JSONType.array) {
                size_t trues;
                foreach (entry; assign.array) {
                    if (entry.type == JSONType.true_) ++trues;
                    else if (entry.type == JSONType.integer && entry.integer == 1) ++trues;
                    else if (entry.type == JSONType.uinteger && entry.uinteger == 1) ++trues;
                }
                writeln("True literals : ", trues, " / ", assign.array.length);
            } else if (assign.type == JSONType.object) {
                writeln("Named assignment keys: ", assign.object.length);
            }
        }
    }
}

void main() {
    writeln("=====================================================");
    writeln(" Reify — random 3-SAT at the phase transition");
    writeln(" alpha = M / N ≈ 4.267 (critical SAT/UNSAT boundary)");
    writeln("=====================================================");
    runInstance("medium", 3_000, 12_801);
    runInstance("hard",   8_000, 34_136);
}
