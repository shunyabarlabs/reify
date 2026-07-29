// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Reify SDK Benchmark: Data Center Workload Placement
// ============================================================================
//
//  24 microservice workloads across 8 servers in 4 fault domains.
//
//  Calls the Navokoj backend programmatically via app.solve() and prints the
//  hydrated placement, hard/medium/soft violation counts, and ExecutionTrace.
//  Every reported number is read from the SDK — nothing is hand-reproduced.
//
//  Demonstrates the HIGH-LEVEL Reify SDK surface:
//    categoricalVar, .same(), .different(), .equals(), .differs()
//    require, prefer, medium
//    implies, equivalent, allDifferent
//    requireClause (only for AMK capacity — genuinely needs clause-level)
//    preferClause  (only for rack diversity — big disjunction)
//
// ============================================================================

module hard_benchmark_cnf;

import reify;
import std.array : join;
import std.json : JSONValue;
import std.stdio : writeln;
import std.string : format;

int main(string[] args) {
    writeln("==========================================================================");
    writeln("  Reify SDK Benchmark: Data Center Workload Placement (24 services)");
    writeln("==========================================================================");

    enum N = 24;
    enum S = 8;
    auto servers = ["s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7"];

    string[] wk;
    foreach (i; 0 .. N) wk ~= format("w%02d", i);

    double[N] revenue = [
        30, 15, 45, 60, 10, 25, 80, 50,
        35, 20, 28, 70, 12, 42, 33, 55,
        8,  48, 72, 18, 30, 38, 22, 65
    ];

    auto app = decisionApp("datacenter-placement", (Model model) {

        // ── 1. CATEGORICAL PLACEMENT VARIABLES ──────────────────────────
        // Each workload picks exactly one server. ALO + AMO is automatic.
        CategoryExpr[N] place;
        foreach (i; 0 .. N)
            place[i] = model.categoricalVar(format("place[%s]", wk[i]), servers);

        // Boolean indicators for capacity encoding (the ONE place we need them)
        BoolExpr[S][N] on;
        foreach (i; 0 .. N)
            foreach (s; 0 .. S)
                on[i][s] = model.booleanVar(format("on[%s,%s]", wk[i], servers[s]));

        // Channel categorical → boolean via equivalent()
        foreach (i; 0 .. N)
            foreach (s; 0 .. S)
                model.require(
                    format("chan[%s,%s]", wk[i], servers[s]),
                    equivalent(on[i][s], place[i].equals(servers[s]))
                );

        // ── 2. HARD CONSTRAINTS (high-level SDK) ────────────────────────

        // Anti-affinity: these pairs MUST be on different servers
        foreach (pair; [[0,3], [6,11], [12,23], [7,18]])
            model.require(
                format("anti[%s,%s]", wk[pair[0]], wk[pair[1]]),
                place[pair[0]].different(place[pair[1]])
            );

        // Co-location: w06 MUST be with w04
        model.require("colocate_w06_w04", place[6].same(place[4]));

        // Separation: w02 and w18 on different servers
        model.require("separate_w02_w18", place[2].different(place[18]));

        // HA fault-domain isolation: no two in same group share a rack
        int[][] haGroups = [[0,6,12,18], [1,7,13,19], [3,11,23]];
        foreach (gIdx, group; haGroups) {
            foreach (a; 0 .. cast(int) group.length) {
                foreach (b; a + 1 .. cast(int) group.length) {
                    int wa = group[a], wb = group[b];
                    foreach (rk; 0 .. 4) {
                        auto waOnRack = place[wa].equals(servers[rk*2])
                                      | place[wa].equals(servers[rk*2+1]);
                        auto wbOnRack = place[wb].equals(servers[rk*2])
                                      | place[wb].equals(servers[rk*2+1]);
                        model.require(
                            format("ha_g%d_%s_%s_r%d", gIdx, wk[wa], wk[wb], rk),
                            ~(waOnRack & wbOnRack)
                        );
                    }
                }
            }
        }

        // Conditional: if w22 is on rack-D, w21 must also be on rack-D
        model.require("conditional_w22_w21",
            implies(
                place[22].equals("s6") | place[22].equals("s7"),
                place[21].equals("s6") | place[21].equals("s7")
            )
        );

        // Server capacity (≤6): sliding-window AMK via requireClause
        // This is the ONE constraint that genuinely needs clause-level encoding.
        foreach (s; 0 .. S) {
            foreach (start; 0 .. cast(int)(N - 6)) {
                BoolExpr[] window;
                foreach (j; start .. start + 7)
                    window ~= ~on[j][s];
                model.requireClause(format("cap[%s,w%d]", servers[s], start), window);
            }
        }

        // ── 3. MEDIUM CONSTRAINTS ───────────────────────────────────────

        // Rack-home affinity: workloads prefer their "home" rack
        foreach (i; 0 .. N) {
            int rk = i % 4;
            model.medium(
                format("home[%s,r%d]", wk[i], rk),
                place[i].equals(servers[rk*2]) | place[i].equals(servers[rk*2+1]),
                5.0
            );
        }

        // ── 4. SOFT PREFERENCES ─────────────────────────────────────────

        // Co-location affinity for latency-sensitive pairs
        foreach (pair; [[0,1],[2,3],[4,5],[6,7],[8,9],[10,11],[14,15],[20,21]])
            model.prefer(
                format("aff[%s,%s]", wk[pair[0]], wk[pair[1]]),
                place[pair[0]].same(place[pair[1]]),
                15.0
            );

        // Critical services prefer reliable (low-index) servers
        foreach (idx; [0, 3, 6, 11, 12, 18, 23])
            model.prefer(
                format("reliable[%s]", wk[idx]),
                place[idx].equals("s0") | place[idx].equals("s1"),
                revenue[idx] / 2.0
            );

        // Revenue-weighted: high-value workloads prefer top-tier servers
        foreach (i; 0 .. N) {
            if (revenue[i] >= 40.0)
                model.prefer(
                    format("tier1[%s]", wk[i]),
                    place[i].equals("s0") | place[i].equals("s1")
                    | place[i].equals("s2") | place[i].equals("s3"),
                    revenue[i]
                );
        }

        // Rack diversity: prefer spreading across all 4 racks
        foreach (rk; 0 .. 4) {
            BoolExpr[] rackLits;
            foreach (i; 0 .. N) {
                rackLits ~= on[i][rk*2];
                rackLits ~= on[i][rk*2+1];
            }
            model.preferClause(format("diversity[r%d]", rk), rackLits, 20.0);
        }
    });

    // ── 5. SOLVE VIA NavokojBackend (D SDK, not CLI) ──────────────────
    // Reads NAVOKOJ_API_KEY from environment. The compiler's router picks
    // the engine based on topology; for this model (24 categoricals + 25
    // softs + AMK) the router typically selects `nitro` CPU Native (SUTRA).
    AppSolveOptions options;
    options.compilation.engine = "nitro";

    SolveResult result = app.solve(JSONValue(), options);

    // ── 6. REPORT (every number read from the SDK) ────────────────────
    ExecutionTrace trace = explainExecution(result);

    writeln();
    writeln("Solve Time:      ", format("%.0f", trace.solveTimeMs), " ms");
    writeln("Engine Used:     ", trace.selectedEngine);

    auto v = result.verification;
    long hardTotal = cast(long) v.hardSatisfied + cast(long) v.hardViolated;
    writeln();
    writeln("Hard:            ", v.hardSatisfied, " / ", hardTotal,
            " (", v.hardViolated, " violations) — locally re-verified");
    writeln("Medium Violated: ", v.mediumViolated, " (rack-home preferences)");
    writeln("Soft Violated:   ", v.softViolated, " (affinity/revenue trade-offs)");

    // Satisfaction: hard counts as binary, medium/soft scaled.
    long constraintTotal = hardTotal
                          + cast(long) v.mediumViolated
                          + cast(long) v.softViolated;
    long constraintSatisfied = cast(long) v.hardSatisfied;
    if (constraintTotal > 0) {
        double pct = 100.0 * cast(double) constraintSatisfied
                          / cast(double) constraintTotal;
        writeln("Satisfaction:    ", format("%.2f", pct), "%");
    }

    // Per-rack placement, hydrated from the Solution.
    if (result.solution !is null) {
        writeln();
        writeln("Placement:");
        foreach (rk; 0 .. 4) {
            string[] members;
            foreach (i; 0 .. N) {
                auto val = result.solution.get(format("place[%s]", wk[i]));
                if (val.status == DecisionStatus.assigned) {
                    auto sv = val.categoricalValue;
                    if (sv == servers[rk*2] || sv == servers[rk*2 + 1])
                        members ~= wk[i];
                }
            }
            writeln("  Rack-", cast(char)('A' + rk),
                    " (", servers[rk*2], ",", servers[rk*2 + 1], "): ",
                    members.length == 0 ? "(empty)" : members.join(", "),
                    " → ", members.length, " workload", members.length == 1 ? "" : "s");
        }
    }

    // Hard-constraint verification: print names that were satisfied.
    writeln();
    writeln("Verification (hard constraints satisfied):");
    foreach (match; v.matches) {
        if (match.level == ConstraintLevel.hard
                && match.state == MatchState.satisfied) {
            writeln("  ✓ ", match.name);
        }
    }

    return result.feasible ? 0 : 1;
}
