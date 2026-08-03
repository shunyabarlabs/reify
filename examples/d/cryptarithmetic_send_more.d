// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Cryptarithmetic: SEND + MORE = MONEY
// ============================================================================
//
//  Classic alphametic puzzle. Each letter is a distinct digit 0-9. S and M
//  cannot be 0 because they are leading digits. The unique solution is
//  9567 + 1085 = 10652  (S=9 E=5 N=6 D=7 M=1 O=0 R=8 Y=2).
//
//  Column-by-column reasoning the solver must rediscover:
//    D + E        = Y + 10 * c1
//    N + R + c1   = E + 10 * c2
//    E + O + c2   = N + 10 * c3
//    S + M + c3   = O + 10 * c4
//    c4           = M         (top of column produces a 5-digit sum)
//
//  Hard constraints:
//    - distinctness on {S,E,N,D,M,O,R,Y}
//    - S != 0, M != 0
//    - 1000*S + 100*E + 10*N + D + 1000*M + 100*O + 10*R + E
//        == 10000*M + 1000*O + 100*N + 10*E + Y
//
// ============================================================================

module cryptarithmetic_send_more;

import reify;
import reify.navokoj.client : NavokojClient, RequestOptions;
import reify.router : RoutingRecommendation;
import reify.result : SolveResult, Solution, DecisionStatus, buildSolveResult;

import std.json : JSONValue;
import std.process : environment;
import std.stdio;
import std.format : format;

void main() {
    writeln("==========================================================================");
    writeln("  Reify SDK Example: Cryptarithmetic  SEND + MORE = MONEY");
    writeln("==========================================================================");

    auto model = new Model("cryptarithmetic-send-more-money");

    // Each letter is a bounded integer variable in 0..9.
    auto S = model.integerVar("S", 1, 9); // leading, nonzero
    auto E = model.integerVar("E", 0, 9);
    auto N = model.integerVar("N", 0, 9);
    auto D = model.integerVar("D", 0, 9);
    auto M = model.integerVar("M", 1, 9); // leading and result's first digit
    auto O = model.integerVar("O", 0, 9);
    auto R = model.integerVar("R", 0, 9);
    auto Y = model.integerVar("Y", 0, 9);

    IntExpr[] letters = [S, E, N, D, M, O, R, Y];

    // Pairwise distinctness: 8 letters -> 28 inequalities.
    writeln("Adding pairwise distinctness (28 inequalities)...");
    size_t pairIdx = 0;
    foreach (i; 0 .. letters.length) {
        foreach (j; i + 1 .. letters.length) {
            model.require(
                format("distinct_%02d", pairIdx),
                notEqual(letters[i], letters[j])
            );
            ++pairIdx;
        }
    }

    // SEND = 1000*S + 100*E + 10*N + D
    auto SEND = S * 1000 + E * 100 + N * 10 + D;

    // MORE = 1000*M + 100*O + 10*R + E
    auto MORE = M * 1000 + O * 100 + R * 10 + E;

    // MONEY = 10000*M + 1000*O + 100*N + 10*E + Y
    auto MONEY = M * 10000 + O * 1000 + N * 100 + E * 10 + Y;

    // SEND + MORE == MONEY
    writeln("Adding SEND + MORE = MONEY column equation...");
    model.require("send_more_equals_money", equal(SEND + MORE, MONEY));

    // Compile
    writeln("\nCompiling model via Reify Decision Compiler...");
    stdout.flush();
    CompileOptions opts;
    auto compiled = compile(model, opts);

    writeln("\n=== Compilation Summary ===");
    writeln(compiled.summary().toPrettyString());

    // ----- Submit to Navokoj -----
    string apiKey = environment.get("NAVOKOJ_API_KEY", "");
    if (apiKey.length == 0) {
        writeln("\nNAVOKOJ_API_KEY not set; skipping solve. Export it (e.g.");
        writeln("  export NAVOKOJ_API_KEY=\"$(cat .public_api_key)\")");
        writeln("and re-run to dispatch this model to the Navokoj nitro engine.");
        return;
    }

    RequestOptions reqOpts;
    reqOpts.apiKey = apiKey;

    RoutingRecommendation rec;
    rec.engine = "nitro";
    rec.hardware = "cpu_native"; // cpu_native | gpu_l4 | gpu_h100

    writeln("\nDispatching to Navokoj (nitro / cpu_native)...");
    stdout.flush();

    auto client = new NavokojClient();
    SolveResult result;
    bool usedNavokoj = false;
    try {
        result = client.solve(compiled, reqOpts, rec);
        usedNavokoj = true;
    } catch (Exception navokojError) {
        writeln(format("\nNavokoj dispatch failed: %s", navokojError.msg));
        writeln("Falling back to local MiniSat...");
        stdout.flush();
    }

    if (!usedNavokoj) {
        import std.file : write, remove, exists;
        import std.process : execute;

        // Export CNF using the same shape warehouse_mapf_20x_extreme.d uses.
        auto cnfPath = "cryptarithmetic.cnf";
        {
            import std.stdio : File;
            auto f = File(cnfPath, "w");
            f.writefln("p cnf %d %d",
                compiled.generatedVariableCount,
                compiled.clauses.length);
            foreach (clause; compiled.clauses) {
                foreach (lit; clause.literals) f.write(lit, " ");
                f.writeln("0");
            }
        }
        writeln(format("Wrote %s", cnfPath));

        auto res = execute(["minisat", cnfPath, "cryptarithmetic.sol"]);
        // minisat returns 10 for SATISFIABLE, 20 for UNSATISFIABLE.
        if (res.status != 10) {
            writeln(format("MiniSat did not return SAT (exit=%d). Aborting.", res.status));
            return;
        }

        // Parse MiniSat's "v <literals>" lines into a JSONValue array and
        // hand it to the standard hydration pipeline.
        import std.string : lineSplitter, strip;
        import std.algorithm : map, filter, splitter;
        import std.range : array;
        import std.conv : to;

        // minisat prints "SAT"/"UNSAT" + a stats banner to stdout. Read the .sol
        // file we asked it to write instead — its format is stable: first
        // line "SAT" or "UNSAT", second line signed integers ending in 0.
        import std.file : readText;
        auto solText = readText("cryptarithmetic.sol");
        long[] litValues;
        foreach (line; solText.lineSplitter) {
            auto s = line.strip;
            if (s.length == 0) continue;
            if (s == "SAT" || s == "UNSAT") continue;
            foreach (tok; s.splitter(' ')) {
                auto t = tok.strip;
                if (t.length == 0) continue;
                litValues ~= t.to!long;
            }
        }
        while (litValues.length && litValues[$-1] == 0) {
            litValues = litValues[0 .. $-1];
        }

        // hydrateCnf expects an array of booleans indexed by (SAT-var - 1).
        // Convert minisat's signed-literal vector to that shape.
        auto vs = new bool[](compiled.generatedVariableCount);
        foreach (lit; litValues) {
            if (lit == 0) continue;
            if (lit > 0) vs[cast(size_t)(lit - 1)] = true;
        }
        JSONValue[] arr;
        foreach (b; vs) arr ~= JSONValue(b);

        // Wrap in the same wire envelope normalizeResponse expects.
        JSONValue[string] nested;
        nested["assignment"] = JSONValue(arr);
        JSONValue[string] outer;
        outer["solution"] = JSONValue(nested);
        outer["success"] = JSONValue(true);
        JSONValue rawResp = JSONValue(outer);

        result = buildSolveResult(compiled, rawResp);
    }

    writeln("\n=== Solve Result ===");
    writeln(result.toJson().toPrettyString());

    if (result.solution is null || !result.solution.complete()) {
        writeln("\nSolver returned no complete assignment.");
        return;
    }

    auto digit = (string letter) {
        return result.solution.get(letter).integerValue;
    };

    writeln("\n========================================================");
    writeln("                SOLUTION");
    writeln("========================================================");
    writeln(format("  S=%d  E=%d  N=%d  D=%d", digit("S"), digit("E"), digit("N"), digit("D")));
    writeln(format("  M=%d  O=%d  R=%d  Y=%d", digit("M"), digit("O"), digit("R"), digit("Y")));
    writeln("--------------------------------------------------------");
    auto send = digit("S") * 1000 + digit("E") * 100 + digit("N") * 10 + digit("D");
    auto more = digit("M") * 1000 + digit("O") * 100 + digit("R") * 10 + digit("E");
    auto money = digit("M") * 10000 + digit("O") * 1000 + digit("N") * 100 + digit("E") * 10 + digit("Y");
    writeln(format("    %d",   send));
    writeln(format("  + %d", more));
    writeln(format("  -----"));
    writeln(format("    %d",  money));
    writeln("========================================================");

    writeln(format("\n  backend used : %s", usedNavokoj ? "Navokoj nitro/cpu_native" : "local MiniSat"));
    writeln(format("  feasible    : %s", result.feasible()));
    writeln(format("  hard sat    : %d / %d",
        result.verification.hardSatisfied,
        result.verification.hardSatisfied + result.verification.hardViolated));
    writeln(format("  hard viol   : %d", result.verification.hardViolated));
    if (usedNavokoj) {
        if (result.server.hasSolveTime) {
            writeln(format("  navokoj time: %.3f s", result.server.solveTimeSeconds));
        }
        if (result.server.requestId.length)
            writeln(format("  request id  : %s", result.server.requestId));
    }
}