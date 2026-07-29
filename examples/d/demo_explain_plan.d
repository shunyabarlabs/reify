module demo_explain_plan;

import reify;
import std.conv : to;
import std.format : format, formattedRead;
import std.json : JSONValue;
import std.stdio : writeln, writefln;
import std.range : iota;

int main(string[] args) {
    SolveResult result;

    auto app = decisionApp("surgery_explain_demo", (Model m) {
        enum int numPatients = 24;
        enum int numDoctors  = 4;
        enum int numRooms    = 24;
        enum int numSlots    = 8;

        auto space = m.typedDecisionSpace("surgery")
            .dimension("patient", iota(1, numPatients + 1))
            .dimension("doctor",  iota(1, numDoctors  + 1))
            .dimension("room",    iota(1, numRooms    + 1))
            .dimension("slot",    iota(1, numSlots    + 1))
            .filter((int p, int d, int r, int slot) {
                int expectedDoc  = ((p - 1) % numDoctors) + 1;
                int expectedRoom = p;
                int day          = (p - 1) / 6;
                int dailySlot    = ((p - 1) % 6) + 3;
                int expectedSlot = (day * 8) + dailySlot;
                return (d == expectedDoc) & (r == expectedRoom) & (slot == expectedSlot);
            })
            .build();

        // ── 1. EXPLAIN: Logical Plan ─────────────────────────────────────────
        auto logPlan = space.explainPlan();
        logPlan.print();

        // ── 2. EXPLAIN: Physical Plan ────────────────────────────────────────
        space.groupBy("patient").exactlyOne();
        space.groupBy("doctor", "slot").atMostOne();

        auto physPlan = space.explainPhysical();
        physPlan.print();

    }, (JSONValue input, Solution sol) {
        writeln("\n✅ Solution received. Running execution + decision explain...");
        return JSONValue(["status": JSONValue("ok")]);
    });

    // Run the solve and capture the result for post-solve explain
    int exitCode = app.run(args);

    return exitCode;
}
