// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Hardware Bounded Model Checking (BMC) - 15 Million Clauses
// ============================================================================
//
//  This benchmark simulates a massive hardware equivalence checking task
//  over a deep cryptographic diffusion pipeline (Majority gate network).
//  It is designed to intentionally push the Navokoj Nitro engine and the HTTP
//  transport layer to their absolute limits, reaching scales typical of offline
//  academic SAT competitions (~15 million clauses).
//
// ============================================================================

module hardware_bmc_15m;

import reify;
import std.stdio;
import std.format : format;
import core.time : dur, seconds;

enum PIPELINE_DEPTH = 100;
enum DATAPATH_WIDTH = 25000;

void main(string[] args) {
    writeln("==========================================================================");
    writeln("  Hardware BMC Verification (Scale: ", PIPELINE_DEPTH, "x", DATAPATH_WIDTH, ")");
    writeln("==========================================================================");
    
    auto model = new Model("hardware-bmc-15m");

    // We will bypass AST BDD expansion by using raw boolean variables and Native Clauses
    // to instantly generate the 15 million CNF clauses.
    BoolExpr[][] state = new BoolExpr[][](PIPELINE_DEPTH + 1, DATAPATH_WIDTH);
    
    writeln("Initializing ", (PIPELINE_DEPTH + 1) * DATAPATH_WIDTH, " logical variables...");
    foreach (t; 0 .. PIPELINE_DEPTH + 1) {
        foreach (i; 0 .. DATAPATH_WIDTH) {
            state[t][i] = model.booleanVar(format("s_t%d_i%d", t, i));
        }
    }

    writeln("Unrolling pipeline transitions (Building ~15M native clauses instantly)...");
    foreach (t; 1 .. PIPELINE_DEPTH + 1) {
        if (t % 20 == 0) {
            writeln("  Built up to cycle ", t, "/", PIPELINE_DEPTH, "...");
        }
        foreach (i; 0 .. DATAPATH_WIDTH) {
            auto C = state[t][i];
            auto A = state[t-1][i];
            auto B = state[t-1][(i + 1) % DATAPATH_WIDTH];
            auto D = state[t-1][(i + 2) % DATAPATH_WIDTH];
            
            auto notA = logicalNot(A);
            auto notB = logicalNot(B);
            auto notC = logicalNot(C);
            auto notD = logicalNot(D);

            // Majority Gate CNF: C <-> (A+B+D >= 2)
            model.requireClause("maj", [notC, A, B]);
            model.requireClause("maj", [notC, A, D]);
            model.requireClause("maj", [notC, B, D]);
            model.requireClause("maj", [C, notA, notB]);
            model.requireClause("maj", [C, notA, notD]);
            model.requireClause("maj", [C, notB, notD]);
        }
    }

    writeln("Adding boundary assertions (Input vectors and Output property)...");
    
    // We remove the fixed input state. 
    // This turns the problem into a true SAT search: "Does there exist ANY initial 
    // input vector at cycle 0 that produces the desired output property at cycle 100?"

    // Require the output state (Cycle D) to have a specific property
    foreach (i; 0 .. 100) {
        model.requireClause("property", [state[PIPELINE_DEPTH][i]]);
    }

    writeln("\nCompiling model via Reify Decision Compiler...");
    stdout.flush();
    CompileOptions opts;
    opts.maxEncodedVariables = 10_000_000;
    opts.maxEncodedClauses = 25_000_000;
    auto compiled = compile(model, opts);

    writeln("\n=== Compilation Summary ===");
    writeln(compiled.summary().toPrettyString());
    stdout.flush();

    writeln("\n=== Writing 15M CNF Clauses to Disk ===");
    stdout.flush();
    import std.stdio : File;
    auto f = File("hardware_bmc_15m.cnf", "w");
    
    // DIMACS Header
    f.writefln("p cnf %d %d", compiled.generatedVariableCount, compiled.clauses.length);
    
    // Write Clauses
    foreach (clause; compiled.clauses) {
        foreach (lit; clause.literals) {
            f.write(lit, " ");
        }
        f.writeln("0");
    }
    f.close();
    
    writeln("Successfully wrote hardware_bmc_15m.cnf!");
    writeln("You can now test this ~15M clause benchmark on an offline academic solver like Kissat.");
}
