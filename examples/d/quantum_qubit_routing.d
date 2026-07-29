// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Reify SDK Example: Quantum Circuit Qubit Routing & SWAP Minimization
// ============================================================================
//
//  Problem Domain:
//    Mapping a 5-qubit logical quantum circuit onto a 9-qubit (3x3 grid)
//    superconducting quantum processor across 6 execution timesteps.
//
//  Hardware Topology (3x3 Grid of Physical Qubits P0..P8):
//    P0 - P1 - P2
//    |    |    |
//    P3 - P4 - P5
//    |    |    |
//    P6 - P7 - P8
//
//  Hard Constraints:
//    1. Bijective Mapping: Each logical qubit L is assigned to exactly 1 physical qubit P at step T.
//    2. Physical Exclusion: No 2 logical qubits occupy the same physical qubit at step T.
//    3. Gate Adjacency: Every 2-qubit gate CNOT(Li, Lj) at step T requires physical qubits
//       pi(Li, T) and pi(Lj, T) to be connected by a physical coupler edge in the hardware graph.
//
//  Soft Constraints:
//    1. SWAP Minimization: Prefer keeping qubit mapping stable across adjacent timesteps (t -> t+1).
//    2. Crosstalk Avoidance: Avoid placing active 2-qubit gates on high-crosstalk physical couplers (e.g. P4-P7).
//
// ============================================================================

module quantum_qubit_routing;

import reify;
import std.algorithm : canFind;
import std.conv : to;
import std.format : format, formattedRead;
import std.json : JSONValue;
import std.range : iota;
import std.stdio : writeln, writefln;

struct Gate {
    int control;
    int target;
    int timestep;
}

struct Coupler {
    int p1;
    int p2;
    double errorRate;
}

int main(string[] args) {
    writeln("==========================================================================");
    writeln("  Reify SDK: Quantum Qubit Routing & Topology Mapping Benchmark");
    writeln("==========================================================================");

    enum int LOGICAL_QUBITS  = 5;
    enum int PHYSICAL_QUBITS = 9;
    enum int TIMESTEPS       = 6;

    // Hardware Topology (3x3 Grid)
    Coupler[] couplers = [
        // Horizontal couplers
        Coupler(0, 1, 0.001), Coupler(1, 2, 0.001),
        Coupler(3, 4, 0.001), Coupler(4, 5, 0.001),
        Coupler(6, 7, 0.001), Coupler(7, 8, 0.001),
        // Vertical couplers (P4-P7 has high crosstalk/error)
        Coupler(0, 3, 0.001), Coupler(3, 6, 0.001),
        Coupler(1, 4, 0.001), Coupler(4, 7, 0.045), // High Crosstalk Edge!
        Coupler(2, 5, 0.001), Coupler(5, 8, 0.001)
    ];

    bool isConnected(int p1, int p2) {
        foreach (ref c; couplers) {
            if ((c.p1 == p1 && c.p2 == p2) || (c.p1 == p2 && c.p2 == p1))
                return true;
        }
        return false;
    }

    // 2-Qubit Gates to schedule
    Gate[] circuitGates = [
        Gate(0, 3, 0), // CNOT(L0, L3) at T0
        Gate(1, 4, 1), // CNOT(L1, L4) at T1
        Gate(2, 0, 2), // CNOT(L2, L0) at T2
        Gate(3, 1, 3), // CNOT(L3, L1) at T3
        Gate(4, 2, 4), // CNOT(L4, L2) at T4
        Gate(0, 4, 5)  // CNOT(L0, L4) at T5
    ];

    auto app = decisionApp("quantum_routing", (Model model) {

        // 1. TYPED DECISION SPACE
        auto space = model.typedDecisionSpace("map")
            .dimension("l", iota(0, LOGICAL_QUBITS))
            .dimension("p", iota(0, PHYSICAL_QUBITS))
            .dimension("t", iota(0, TIMESTEPS))
            .build();

        // 2. BIJECTIVE MAPPING CONSTRAINTS
        // Each logical qubit L is at exactly 1 physical qubit P at timestep T
        space.groupBy("l", "t").exactlyOne();

        // Each physical qubit P holds at most 1 logical qubit L at timestep T
        space.groupBy("p", "t").atMostOne();

        // Fast lookup table: mapExpr[l][p][t]
        BoolExpr[][int][int] mapExpr;
        foreach (ref c; space.inner.candidates) {
            int l = c.tuple["l"].to!int;
            int p = c.tuple["p"].to!int;
            int t = c.tuple["t"].to!int;
            mapExpr[l][p * TIMESTEPS + t] ~= c.expr;
        }

        // 3. 2-QUBIT GATE ADJACENCY CONSTRAINTS
        // For every 2-qubit gate CNOT(ctrl, tgt) at timestep T:
        // If ctrl is at P_ctrl and tgt is at P_tgt, (P_ctrl, P_tgt) MUST be connected.
        int nonAdjClauses = 0;
        foreach (ref g; circuitGates) {
            int t = g.timestep;
            foreach (p1; 0 .. PHYSICAL_QUBITS) {
                foreach (p2; 0 .. PHYSICAL_QUBITS) {
                    if (p1 == p2 || isConnected(p1, p2)) continue;

                    auto key1 = p1 * TIMESTEPS + t;
                    auto key2 = p2 * TIMESTEPS + t;
                    if (key1 !in mapExpr[g.control] || key2 !in mapExpr[g.target]) continue;

                    foreach (ref e1; mapExpr[g.control][key1]) {
                        foreach (ref e2; mapExpr[g.target][key2]) {
                            // ~e1 | ~e2 (Cannot place non-adjacent qubits)
                            model.requireClause(
                                format("gate_adj_%d_g%d", nonAdjClauses++, g.timestep),
                                [~e1, ~e2]
                            );
                        }
                    }
                }
            }
        }

        // 4. SOFT SWAP MINIMIZATION
        // Prefer keeping logical qubit L on the same physical qubit P between timestep T and T+1
        int prefIdx = 0;
        foreach (l; 0 .. LOGICAL_QUBITS) {
            foreach (p; 0 .. PHYSICAL_QUBITS) {
                foreach (t; 0 .. TIMESTEPS - 1) {
                    auto k1 = p * TIMESTEPS + t;
                    auto k2 = p * TIMESTEPS + (t + 1);
                    if (k1 !in mapExpr[l] || k2 !in mapExpr[l]) continue;
                    foreach (ref e1; mapExpr[l][k1]) {
                        foreach (ref e2; mapExpr[l][k2]) {
                            // Reward stability (~e1 | e2)
                            model.preferClause(
                                format("swap_min_%d", prefIdx++),
                                [~e1, e2],
                                8.0
                            );
                        }
                    }
                }
            }
        }

        // 5. CROSSTALK AVOIDANCE (Penalize using P4-P7 coupler for active 2-qubit gates)
        foreach (ref g; circuitGates) {
            int t = g.timestep;
            // P4-P7 or P7-P4 placement for gate g at timestep t
            auto k4_ctrl = 4 * TIMESTEPS + t;
            auto k7_tgt  = 7 * TIMESTEPS + t;
            auto k7_ctrl = 7 * TIMESTEPS + t;
            auto k4_tgt  = 4 * TIMESTEPS + t;

            if (k4_ctrl in mapExpr[g.control] && k7_tgt in mapExpr[g.target]) {
                foreach (ref e1; mapExpr[g.control][k4_ctrl]) {
                    foreach (ref e2; mapExpr[g.target][k7_tgt]) {
                        model.preferClause(
                            format("crosstalk_pen_%d_a", g.timestep),
                            [~e1, ~e2],
                            15.0 // Strong penalty against high crosstalk
                        );
                    }
                }
            }
        }

        writeln("Quantum topology model compilation complete.");

    }, (JSONValue input, Solution solution) {
        writeln("\n=======================================================");
        writeln("  Quantum Circuit Mapping & Routing Verification");
        writeln("=======================================================");

        int[int][int] layout; // t -> l -> p
        int assignedCount = 0;

        foreach (key; solution.keys) {
            auto val = solution.get(key);
            if (val.status != DecisionStatus.assigned || !val.booleanValue)
                continue;

            int l, p, t;
            string mutK = key;
            try {
                formattedRead(mutK, "map_l_%d_p_%d_t_%d", &l, &p, &t);
            } catch (Exception) { continue; }

            assignedCount++;
            layout[t][l] = p;
        }

        writefln("\n📊 Total Qubit-Timestep Placements: %d", assignedCount);
        writeln("\n⚛️  Logical-to-Physical Qubit Mapping Schedule:");
        writeln("Step | Gate Scheduled | L0   | L1   | L2   | L3   | L4   | SWAPs ");
        writeln("------------------------------------------------------------------");

        int totalSwaps = 0;
        foreach (t; 0 .. TIMESTEPS) {
            string gateStr = "None        ";
            foreach (ref g; circuitGates) {
                if (g.timestep == t) {
                    gateStr = format("CNOT(L%d,L%d) ", g.control, g.target);
                    break;
                }
            }

            int swapsInStep = 0;
            if (t > 0) {
                foreach (l; 0 .. LOGICAL_QUBITS) {
                    if (layout[t][l] != layout[t - 1][l]) swapsInStep++;
                }
                totalSwaps += swapsInStep;
            }

            string line = format("T%d   | %-13s| ", t, gateStr);
            foreach (l; 0 .. LOGICAL_QUBITS) {
                int phys = layout.get(t, null) !is null ? layout[t].get(l, -1) : -1;
                line ~= format("P%-3d| ", phys);
            }
            line ~= format("%d", swapsInStep);
            writeln(line);
        }

        writefln("\n✅ Total Physical SWAP Moves Inserted: %d", totalSwaps);
        return solution.toJson();
    });

    return app.run(args);
}
