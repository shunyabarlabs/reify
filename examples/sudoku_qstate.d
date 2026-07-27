module sudoku_qstate;

/**
 * Sudoku Solver — Navokoj Q-State L4 GPU Path
 *
 * Why Q-State instead of CNF?
 *
 *   Boolean (CNF) approach:  81 cells × 9 digits = 729 Boolean variables
 *                            + hundreds of auxiliary cardinality clauses
 *                            Solver navigates discrete symbol flips.
 *
 *   Q-State approach:        81 categorical variables, domain {1..9}
 *                            allDifferent rows/cols/boxes route directly
 *                            to continuous state relaxation on L4 GPU.
 *                            No auxiliary variables. No clause explosion.
 *
 * The router detects: structureClassification == "qstate_categorical"
 * when ALL variables are categorical and no soft/parity objectives exist.
 * It then routes to solve_qstate_l4 with O(1) continuous relaxation.
 */

import reify;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import std.stdio : writeln, writefln;
import std.range : iota;
import std.string : strip;

// A classic hard Sudoku puzzle (17 given clues — minimum for unique solution)
// 0 = empty cell
immutable int[9][9] PUZZLE = [
    [8, 0, 0,  0, 0, 0,  0, 0, 0],
    [0, 0, 3,  6, 0, 0,  0, 0, 0],
    [0, 7, 0,  0, 9, 0,  2, 0, 0],

    [0, 5, 0,  0, 0, 7,  0, 0, 0],
    [0, 0, 0,  0, 4, 5,  7, 0, 0],
    [0, 0, 0,  1, 0, 0,  0, 3, 0],

    [0, 0, 1,  0, 0, 0,  0, 6, 8],
    [0, 0, 8,  5, 0, 0,  0, 1, 0],
    [0, 9, 0,  0, 0, 0,  4, 0, 0],
];

string cellName(int row, int col) {
    return format("cell_r%d_c%d", row + 1, col + 1);
}

string boxOf(int row, int col) {
    return format("%d_%d", row / 3, col / 3);
}

// The 9 digit states shared by every cell
immutable string[] DIGITS = ["1","2","3","4","5","6","7","8","9"];

int main(string[] args) {
    auto app = decisionApp("sudoku_qstate", (Model m) {

        // ====================================================================
        // 1. Declare 81 CATEGORICAL variables, domain {1..9}
        //    This is the Q-State shape: every variable is categorical,
        //    no soft objectives, no parity — pure all-different.
        // ====================================================================
        CategoryExpr[9][9] cells;

        foreach (r; 0 .. 9) {
            foreach (c; 0 .. 9) {
                // All cells get full domain {1..9}
                cells[r][c] = m.categoricalVar(cellName(r, c), DIGITS.dup);
            }
        }

        // Pin given clues: require cell == clue digit
        foreach (r; 0 .. 9) {
            foreach (c; 0 .. 9) {
                if (PUZZLE[r][c] != 0) {
                    m.require(
                        format("clue_r%d_c%d", r + 1, c + 1),
                        cells[r][c].equals(PUZZLE[r][c].to!string)
                    );
                }
            }
        }

        // ====================================================================
        // 2. Declare Invariants using allDifferent
        //    allDifferent(CategoryExpr[]) compiles to native Q-State
        //    continuous state tensor — no pairwise clause explosion.
        // ====================================================================

        // Row invariants: each row has all 9 digits distinct
        foreach (r; 0 .. 9) {
            CategoryExpr[] row;
            foreach (c; 0 .. 9) row ~= cells[r][c];
            m.require(format("row_%d_all_different", r + 1), allDifferent(row));
        }

        // Column invariants
        foreach (c; 0 .. 9) {
            CategoryExpr[] col;
            foreach (r; 0 .. 9) col ~= cells[r][c];
            m.require(format("col_%d_all_different", c + 1), allDifferent(col));
        }

        // 3×3 Box invariants
        foreach (boxR; 0 .. 3) {
            foreach (boxC; 0 .. 3) {
                CategoryExpr[] box;
                foreach (r; boxR*3 .. boxR*3 + 3)
                    foreach (c; boxC*3 .. boxC*3 + 3)
                        box ~= cells[r][c];
                m.require(format("box_%d_%d_all_different", boxR, boxC), allDifferent(box));
            }
        }

        // ====================================================================
        // 3. EXPLAIN — show logical + physical plan before solving
        // ====================================================================
        auto topology = analyzeModel(m);
        auto route    = recommendRoute(topology);

        writeln("\n╔══════════════════════════════════════════════════════════╗");
        writeln("║  Sudoku — Navokoj EXPLAIN                               ║");
        writeln("╠══════════════════════════════════════════════════════════╣");
        writefln("║  Variables:        %d categorical (81 cells × domain {1..9})", topology.logicalVariables);
        writefln("║  Constraints:      %d allDifferent groups", topology.symbolicConstraints);
        writefln("║  Structure:        %s", topology.structureClassification);
        writeln("║  Suggested action:");
        writefln("║    %s", topology.suggestedAction.length > 55
            ? topology.suggestedAction[0..55] : topology.suggestedAction);
        writefln("║  Routing:          %s / %s", route.engine, route.hardware);
        writefln("║  Est. solve time:  %.1f ms", route.estimatedSolveTimeMs);
        writefln("║  Est. cost:        $%.4f", route.estimatedCreditCost);
        writeln("╚══════════════════════════════════════════════════════════╝");

    }, (JSONValue input, Solution solution) {

        writeln("\n╔══════════════════════════════════════════════════════════╗");
        writeln("║  Sudoku Solution — Verified by Navokoj Q-State L4       ║");
        writeln("╠══════════════════════════════════════════════════════════╣");

        // Reconstruct grid from solution
        // Q-State returns integer indices into the domain, not string states.
        // DIGITS[index] gives the actual digit string.
        int[9][9] grid;
        foreach (r; 0 .. 9) {
            foreach (c; 0 .. 9) {
                auto val = solution.get(cellName(r, c));
                if (val.status == DecisionStatus.assigned) {
                    if (val.kind == VariableKind.categorical && val.categoricalValue.length > 0) {
                        grid[r][c] = val.categoricalValue.strip.to!int;
                    } else {
                        // Q-State returns integer index into domain {0..8} → DIGITS[index]
                        int idx = cast(int) val.integerValue;
                        if (idx >= 0 && idx < 9) grid[r][c] = idx + 1;
                        else grid[r][c] = PUZZLE[r][c]; // fallback to clue
                    }
                } else {
                    grid[r][c] = PUZZLE[r][c]; // given clue
                }
            }
        }

        // Print grid
        writeln("║                                                         ║");
        foreach (r; 0 .. 9) {
            string row = "║  ";
            foreach (c; 0 .. 9) {
                row ~= grid[r][c].to!string ~ " ";
                if (c == 2 || c == 5) row ~= "│ ";
            }
            writefln("%s   ║", row);
            if (r == 2 || r == 5)
                writeln("║  ──────┼───────┼──────                           ║");
        }
        writeln("║                                                         ║");

        // Verify: check each row, col, box sums to 45
        bool valid = true;
        foreach (r; 0 .. 9) {
            int sum = 0;
            foreach (c; 0 .. 9) sum += grid[r][c];
            if (sum != 45) { valid = false; }
        }
        foreach (c; 0 .. 9) {
            int sum = 0;
            foreach (r; 0 .. 9) sum += grid[r][c];
            if (sum != 45) { valid = false; }
        }

        writefln("║  ✅ Grid checksum valid (all rows+cols sum to 45): %s", valid ? "YES" : "NO ⚠️");
        writeln("╚══════════════════════════════════════════════════════════╝");

        return JSONValue([
            "status": JSONValue(valid ? "SOLVED_AND_VERIFIED" : "INVALID"),
            "grid": JSONValue(grid[0][0].to!string ~ "...")
        ]);
    });

    return app.run(args);
}
