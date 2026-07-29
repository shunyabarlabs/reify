module sudoku;

import reify;
import std.json : JSONValue;
import std.string : format;

string key(int row, int col, int digit) {
    return format("r%d_c%d_d%d", row + 1, col + 1, digit + 1);
}

int main(string[] args) {
    // Planted instance: these clues are sampled from the valid completed grid
    // below, so the model is guaranteed satisfiable. Difficulty can be raised
    // by removing more clues while retaining this planted witness.
    const givens = [
        [5, 0, 0, 0, 7, 0, 0, 0, 2],
        [0, 7, 0, 1, 0, 5, 0, 4, 0],
        [1, 0, 8, 0, 4, 0, 5, 0, 0],
        [0, 5, 9, 7, 0, 0, 4, 0, 3],
        [4, 0, 6, 8, 5, 3, 0, 9, 0],
        [0, 0, 3, 9, 0, 4, 8, 0, 6],
        [9, 0, 1, 5, 0, 7, 2, 0, 4],
        [0, 8, 0, 4, 1, 9, 0, 6, 0],
        [3, 0, 5, 0, 8, 0, 1, 0, 9]
    ];

    auto app = decisionApp("sudoku", (Model model) {
        BoolExpr[9][9][9] cell;
        foreach (r; 0 .. 9) foreach (c; 0 .. 9) foreach (d; 0 .. 9)
            cell[r][c][d] = model.booleanVar(key(r, c, d));

        // Every cell contains exactly one digit.
        foreach (r; 0 .. 9) foreach (c; 0 .. 9) {
            BoolExpr[] literals;
            foreach (d; 0 .. 9) literals ~= cell[r][c][d];
            model.requireClause("cell at least one", literals);
            foreach (a; 0 .. 9) foreach (b; a + 1 .. 9)
                model.requireClause("cell at most one", [~cell[r][c][a], ~cell[r][c][b]]);
        }

        // Each digit occurs once in every row and column.
        foreach (d; 0 .. 9) foreach (r; 0 .. 9) {
            BoolExpr[] row;
            foreach (c; 0 .. 9) row ~= cell[r][c][d];
            model.requireClause("row digit", row);
            foreach (a; 0 .. 9) foreach (b; a + 1 .. 9)
                model.requireClause("row duplicate", [~cell[r][a][d], ~cell[r][b][d]]);
        }
        foreach (d; 0 .. 9) foreach (c; 0 .. 9) {
            BoolExpr[] column;
            foreach (r; 0 .. 9) column ~= cell[r][c][d];
            model.requireClause("column digit", column);
            foreach (a; 0 .. 9) foreach (b; a + 1 .. 9)
                model.requireClause("column duplicate", [~cell[a][c][d], ~cell[b][c][d]]);
        }

        // Each 3x3 box contains every digit once.
        foreach (d; 0 .. 9) foreach (br; 0 .. 3) foreach (bc; 0 .. 3) {
            BoolExpr[] box;
            foreach (dr; 0 .. 3) foreach (dc; 0 .. 3) box ~= cell[br * 3 + dr][bc * 3 + dc][d];
            model.requireClause("box digit", box);
            foreach (a; 0 .. 9) foreach (b; a + 1 .. 9) {
                int ar = br * 3 + a / 3, ac = bc * 3 + a % 3;
                int rr = br * 3 + b / 3, rc = bc * 3 + b % 3;
                model.requireClause("box duplicate", [~cell[ar][ac][d], ~cell[rr][rc][d]]);
            }
        }

        foreach (r; 0 .. 9) foreach (c; 0 .. 9)
            if (givens[r][c] != 0)
                model.require("given clue", cell[r][c][givens[r][c] - 1]);
    }, (JSONValue input, Solution solution) {
        JSONValue[] grid;
        foreach (r; 0 .. 9) {
            JSONValue[] row;
            foreach (c; 0 .. 9) {
                int digit = 0;
                foreach (d; 0 .. 9)
                    if (solution.get(key(r, c, d)).booleanValue) digit = d + 1;
                row ~= JSONValue(cast(long) digit);
            }
            grid ~= JSONValue(row);
        }
        JSONValue[string] output;
        output["grid"] = JSONValue(grid);
        return JSONValue(output);
    });
    return app.run(args);
}
