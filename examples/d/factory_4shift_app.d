module factory_4shift_app;

import reify;
import std.stdio;

void main() {
    auto model = new Model("factory-4shift");

    // 4 shifts, 32 workers each
    auto shiftA = model.integerVar("shift_a_workers", 0, 32);
    auto shiftB = model.integerVar("shift_b_workers", 0, 32);
    auto shiftC = model.integerVar("shift_c_workers", 0, 32);
    auto shiftD = model.integerVar("shift_d_workers", 0, 32);

    // Exact staffing: 32 total
    model.require("exact_staffing", equal(shiftA + shiftB + shiftC + shiftD, integer(32)));

    // Each shift min 4
    model.require("shift_a_min", greaterEqual(shiftA, integer(4)));
    model.require("shift_b_min", greaterEqual(shiftB, integer(4)));
    model.require("shift_c_min", greaterEqual(shiftC, integer(4)));
    model.require("shift_d_min", greaterEqual(shiftD, integer(4)));

    model.minimize("minimize_headcount", shiftA + shiftB + shiftC + shiftD);

    CompileOptions opts;
    auto compiled = compile(model, opts);

    writeln("=== Factory Shift Scheduling (4 shifts, 32 workers) ===");
    writeln(compiled.summary().toPrettyString());
}
