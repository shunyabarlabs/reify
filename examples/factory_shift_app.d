module factory_shift_app;

import reify;
import std.stdio;

void main() {
    // 1. Build the model directly
    auto model = new Model("factory-shift-scheduling");

    auto shiftA = model.integerVar("shift_a_workers", 0, 10);
    auto shiftB = model.integerVar("shift_b_workers", 0, 10);
    auto shiftC = model.integerVar("shift_c_workers", 0, 10);

    model.require("min_staffing", greaterEqual(shiftA + shiftB + shiftC, integer(15)));
    model.require("shift_a_min", greaterEqual(shiftA, integer(3)));
    model.require("shift_a_cap", lessEqual(shiftA, integer(8)));
    model.require("shift_b_cap", lessEqual(shiftB, integer(8)));
    model.require("shift_c_cap", lessEqual(shiftC, integer(8)));

    model.minimize("minimize_headcount", shiftA + shiftB + shiftC);

    // 2. Compile to CNF via Tseitin Compiler
    CompileOptions opts;
    auto compiled = compile(model, opts);

    // 3. Print summary
    writeln("Model compiled successfully!");
    writeln(compiled.summary().toPrettyString());
}
