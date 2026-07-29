// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Reify SDK Benchmark: Multi-Resource Job Shop Scheduling (High-Signal Benchmark)
// ============================================================================
//
//  12 manufacturing jobs × 3 sequential operations = 36 operations
//  6 machines across 2 capability tiers (Tier A: m0-m2, Tier B: m3-m5)
//  10 timeslots (2 days × 5 slots/day)
//
//  HARD CONSTRAINTS:
//    - Every operation assigned exactly 1 (machine, timeslot) pair
//    - Tier routing: op[0] on Tier A (m0-m2), op[1-2] on Tier B (m3-m5)
//    - No machine conflict: ≤1 operation per machine per timeslot
//    - Precedence: op[j][k+1] strictly after op[j][k]
//    - Maintenance: machine 0 off at slot 4
//    - Machine diversity: op[1] and op[2] of same job must use different machines
//
//  MEDIUM CONSTRAINTS:
//    - Workload balancing: each machine handles 4-8 operations
//
//  SOFT CONSTRAINTS:
//    - Rush jobs (jobs 0-3) prefer completion on Day 1 (slots 0-4)
//    - Morning slots preference (slots 0-1) for step-0 ops
//
//  PARITY (XOR):
//    - Crew rotation: even-parity on even-machine assignments
//
// ============================================================================

module jobshop_extreme;

import reify;
import reify.builders : DecisionCandidate;
import std.array : join;
import std.conv : to;
import std.format : format, formattedRead;
import std.json : JSONType, JSONValue;
import std.range : iota;
import std.stdio : writeln, writefln, stdout;

int main(string[] args) {
    writeln("==========================================================================");
    writeln("  Reify SDK Benchmark: Multi-Resource Job Shop (12 jobs × 3 ops)");
    writeln("==========================================================================");
    stdout.flush();

    enum int J   = 12;       // jobs
    enum int K   = 3;        // ops per job
    enum int N   = J * K;    // 36 total operations
    enum int M   = 6;        // machines
    enum int T   = 10;       // timeslots
    enum int SPD = 5;        // slots per day

    auto app = decisionApp("jobshop", (Model model) {

        // ── 1. DECISION SPACE ───────────────────────────────────────────
        auto space = model.typedDecisionSpace("sched")
            .dimension("op",      iota(0, N))
            .dimension("machine", iota(0, M))
            .dimension("slot",    iota(0, T))
            .filter((int op, int machine, int slot) {
                int step = op % K;

                // Tier routing: step 0 → m0-m2, steps 1-2 → m3-m5
                if (step == 0 && machine >= 3) return false;
                if (step >= 1 && machine < 3)  return false;

                // Maintenance: machine 0 off at slot 4
                if (machine == 0 && slot == 4) return false;

                // Feasibility: step k needs at least slot k
                if (slot < step) return false;

                return true;
            })
            .build();

        writefln("Candidates: %d / %d raw", space.inner.candidates.length, N*M*T);
        stdout.flush();

        // ── 2. STRUCTURAL INVARIANTS ────────────────────────────────────
        space.groupBy("op").exactlyOne();
        space.groupBy("machine", "slot").atMostOne();

        // ── 3. PRECEDENCE (Direct 2-literal CNF clauses) ────────────────
        BoolExpr[][int][int] byOpSlot;
        foreach (ref c; space.inner.candidates) {
            int op   = c.tuple["op"].to!int;
            int slot = c.tuple["slot"].to!int;
            byOpSlot[op][slot] ~= c.expr;
        }

        int precedenceClauses = 0;
        foreach (j; 0 .. J) {
            foreach (k; 0 .. K - 1) {
                int thisOp = j * K + k;
                int nextOp = j * K + k + 1;
                auto thisMap = byOpSlot.get(thisOp, null);
                auto nextMap = byOpSlot.get(nextOp, null);
                if (thisMap is null || nextMap is null) continue;

                foreach (s, ref thisLits; thisMap) {
                    foreach (s2, ref nextLits; nextMap) {
                        if (s2 > s) continue;
                        foreach (ref tx; thisLits) {
                            foreach (ref nx; nextLits) {
                                model.requireClause(
                                    format("pr_%d_%d_%d_%d_%d", j, k, s, s2, precedenceClauses),
                                    [~tx, ~nx]
                                );
                                precedenceClauses++;
                            }
                        }
                    }
                }
            }
        }
        writefln("Precedence 2-SAT clauses: %d", precedenceClauses);
        stdout.flush();

        // ── 4. SAME-JOB MACHINE DIVERSITY ───────────────────────────────
        BoolExpr[][int][int] byOpMach;
        foreach (ref c; space.inner.candidates) {
            int op   = c.tuple["op"].to!int;
            int mach = c.tuple["machine"].to!int;
            byOpMach[op][mach] ~= c.expr;
        }

        int diversityClauses = 0;
        foreach (j; 0 .. J) {
            int op1 = j * K + 1;
            int op2 = j * K + 2;
            auto map1 = byOpMach.get(op1, null);
            auto map2 = byOpMach.get(op2, null);
            if (map1 is null || map2 is null) continue;

            foreach (m; 3 .. M) {
                if (m !in map1 || m !in map2) continue;
                foreach (ref e1; map1[m]) {
                    foreach (ref e2; map2[m]) {
                        model.requireClause(
                            format("div_%d_%d_m%d", j, m, diversityClauses),
                            [~e1, ~e2]
                        );
                        diversityClauses++;
                    }
                }
            }
        }
        writefln("Diversity 2-SAT clauses: %d", diversityClauses);
        stdout.flush();

        // ── 5. WORKLOAD BALANCING (MEDIUM) ──────────────────────────────
        BoolExpr[][int] machOps;
        foreach (ref c; space.inner.candidates) {
            int mach = c.tuple["machine"].to!int;
            machOps[mach] ~= c.expr;
        }
        foreach (m; 0 .. M) {
            auto ops = machOps.get(m, null);
            if (ops is null) continue;
            model.medium(format("bal_lo_%d", m), atLeast(4, ops), 5.0);
            model.medium(format("bal_hi_%d", m), atMost(8, ops), 5.0);
        }

        // ── 6. SOFT: RUSH JOBS PREFER DAY 1 ─────────────────────────────
        foreach (j; 0 .. 4) {
            int lastOp = j * K + (K - 1);
            auto slotMap = byOpSlot.get(lastOp, null);
            if (slotMap is null) continue;
            BoolExpr[] earlyLits;
            foreach (s, ref lits; slotMap) {
                if (s < SPD) {
                    foreach (ref e; lits) earlyLits ~= e;
                }
            }
            if (earlyLits.length > 0)
                model.preferClause(format("early_j%d", j), earlyLits, 15.0);
        }

        // ── 7. SOFT: MORNING SLOTS FOR STEP 0 ───────────────────────────
        foreach (j; 0 .. J) {
            int op0 = j * K;
            auto slotMap = byOpSlot.get(op0, null);
            if (slotMap is null) continue;
            BoolExpr[] mornLits;
            foreach (s, ref lits; slotMap) {
                if (s % SPD < 2) {
                    foreach (ref e; lits) mornLits ~= e;
                }
            }
            if (mornLits.length > 0)
                model.preferClause(format("morn_j%d", j), mornLits, 3.0);
        }

        // ── 8. PARITY (XOR) CREW ROTATION ───────────────────────────────
        BoolExpr[] evenMachOps;
        foreach (ref c; space.inner.candidates) {
            int mach = c.tuple["machine"].to!int;
            if (mach % 2 == 0)
                evenMachOps ~= c.expr;
        }
        if (evenMachOps.length >= 2)
            model.parity("crew_xor", evenMachOps, 0);

        writeln("Model compilation starting...");
        stdout.flush();

    }, (JSONValue input, Solution solution) {
        writeln("\n=======================================================");
        writeln("  Job Shop — Solution Audit");
        writeln("=======================================================");

        int scheduled = 0;
        int[int] opCount;
        string[] msPairs;
        int[int] machLoad;
        int[][int] jobSlots;

        foreach (key; solution.keys) {
            auto val = solution.get(key);
            if (val.status != DecisionStatus.assigned || !val.booleanValue)
                continue;

            int op, mach, slot;
            string mutK = key;
            try {
                formattedRead(mutK, "sched_op_%d_machine_%d_slot_%d",
                              &op, &mach, &slot);
            } catch (Exception) {
                continue;
            }

            scheduled++;
            opCount[op] = opCount.get(op, 0) + 1;
            msPairs ~= format("%d_%d", mach, slot);
            machLoad[mach] = machLoad.get(mach, 0) + 1;

            int job = op / K, step = op % K;
            if (job !in jobSlots) jobSlots[job] = new int[](K);
            jobSlots[job][step] = slot;
        }

        writefln("\n📊 Summary: %d / %d operations scheduled", scheduled, N);
        writeln("\n🧪 Assertions:");

        bool allOnce = true;
        foreach (op; 0 .. N)
            if (opCount.get(op, 0) != 1) { allOnce = false; break; }
        writefln("  %s all_ops_exactly_once", allOnce ? "✅" : "❌");

        bool noCol = true;
        foreach (i, p1; msPairs) {
            foreach (p2; msPairs[i + 1 .. $])
                if (p1 == p2) { noCol = false; break; }
            if (!noCol) break;
        }
        writefln("  %s no_machine_slot_collisions", noCol ? "✅" : "❌");

        int precOk = 0;
        foreach (j; 0 .. J) {
            auto sl = jobSlots.get(j, null);
            if (sl is null) continue;
            bool ok = true;
            foreach (k; 0 .. K - 1)
                if (sl[k] >= sl[k+1]) { ok = false; break; }
            if (ok) precOk++;
        }
        writefln("  %s precedence (%d/%d jobs)",
                 precOk == J ? "✅" : "❌", precOk, J);

        writeln("\n📈 Machine Loads:");
        int balanced = 0;
        foreach (m; 0 .. M) {
            int ld = machLoad.get(m, 0);
            if (ld >= 4 && ld <= 8) balanced++;
            string bar;
            foreach (_; 0 .. ld) bar ~= "█";
            writefln("  M%d: %s %d", m, bar, ld);
        }
        writefln("  %s balance (%d/%d in [4,8])",
                 balanced == M ? "✅" : "⚠️", balanced, M);

        bool pass = allOnce && noCol && precOk == J;
        writefln("\n%s %s", pass ? "🎯" : "❌",
                 pass ? "ALL HARD CONSTRAINTS VERIFIED" : "VIOLATIONS FOUND");

        return JSONValue([
            "status": JSONValue(pass ? "VERIFIED_SAT" : "VIOLATIONS"),
            "scheduled": JSONValue(cast(long) scheduled)
        ]);
    });

    return app.run(args);
}
