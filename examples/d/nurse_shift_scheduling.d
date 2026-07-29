module nurse_shift_scheduling;

import reify;
import std.conv : to;
import std.format : format, formattedRead;
import std.json : JSONValue;
import std.stdio : writeln, writefln;
import std.datetime.stopwatch : StopWatch, AutoStart;

int main(string[] args) {
    // ------------------------------------------------------------------------
    // Nurse Shift Timetabling — Reify DecisionSpace Showcase
    //
    // 10 nurses × 7 days × 3 shifts (Morning / Evening / Night) = 210
    // propositional atoms. Every atom is one Boolean variable that may be
    // assigned true ("nurse N works shift S on day D") or false. We use
    // reify.builders.DecisionSpace as the relational substrate, then layer
    // three declarative groupBy constraints and one pairwise rest-window
    // rule on top. The presenter audits the resulting assignment against the
    // business invariants in pure D — no network calls.
    // ------------------------------------------------------------------------
    enum string[] nurses = ["N1", "N2", "N3", "N4", "N5", "N6", "N7", "N8", "N9", "N10"];
    enum string[] days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    enum string[] shifts = ["Morning", "Evening", "Night"];

    auto swTotal = StopWatch(AutoStart.yes);

    // Captured by both lambdas so the presenter can enumerate atoms by
    // (nurse, day, shift) tuple without re-deriving the space.
    DecisionSpace space;
    DecisionCandidate[] candidates;
    BoolExpr[string] shiftAtoms;

    auto app = decisionApp("nurse_shift_scheduling", (Model m) {
        // 1. Build the 3-D decision space. DecisionSpace.generateTuples emits
        //    one Boolean variable per surviving (nurse, day, shift) tuple.
        space = m.decisionSpace("shift")
            .dimension("nurse", nurses)
            .dimension("day", days)
            .dimension("shift", shifts)
            .build();
        candidates = space.candidates;

        foreach (c; candidates) {
            string key = format("shift_%s_%s_%s",
                c.tuple["nurse"], c.tuple["day"], c.tuple["shift"]);
            shiftAtoms[key] = c.expr;
        }

        // 2. Relational invariants via groupBy cardinality.
        //    A. Max one shift per nurse per day.
        space.groupBy("nurse", "day").atMostOne();
        //    B. Shift coverage: 1 to 2 nurses required per shift per day.
        space.groupBy("day", "shift").between(1, 2);
        //    C. Labor compliance: 2 to 5 shifts per nurse per week.
        space.groupBy("nurse").between(2, 5);

        // 3. Rest window: a nurse working Night cannot work Morning the next
        //    day. This is a pairwise rule between two specific atoms, so it
        //    sits above the groupBy cardinality layer as an explicit
        //    implication:  night => ¬nextMorning.
        foreach (n; nurses) {
            foreach (i; 0 .. days.length - 1) {
                auto night = shiftAtoms[format("shift_%s_%s_Night", n, days[i])];
                auto nextMorning = shiftAtoms[
                    format("shift_%s_%s_Morning", n, days[i + 1])
                ];
                m.require(
                    format("rest_period_%s_%s", n, days[i]),
                    implies(night, logicalNot(nextMorning))
                );
            }
        }
    }, (JSONValue input, Solution solution) {
        writeln("\n=======================================================");
        writeln("🏥 Reify SDK: Nurse Shift Scheduling Showcase");
        writeln("=======================================================");

        int totalAssignedShifts = 0;
        int[string] nurseWorkloads;
        int[string] shiftCoverage;

        foreach (n; nurses) nurseWorkloads[n] = 0;

        // Walk the captured candidate list. solution.has/lookup uses the
        // generated varName (e.g. "shift_nurse_N1_day_Mon_shift_Morning");
        // we render audit summaries using the human-readable tuple.
        foreach (c; candidates) {
            if (solution.has(c.varName) && solution.get(c.varName).booleanValue) {
                totalAssignedShifts++;
                nurseWorkloads[c.tuple["nurse"]]++;
                string dsKey = c.tuple["day"] ~ "_" ~ c.tuple["shift"];
                shiftCoverage[dsKey] = shiftCoverage.get(dsKey, 0) + 1;
            }
        }

        writefln("\n📊 Solution Summary:");
        writefln("  • Total Shifts Assigned: %d", totalAssignedShifts);
        writefln("  • Total Nurses Scheduled: %d / %d",
            nurseWorkloads.length, nurses.length);

        writeln("\n🧪 Running Audit Assertions:");

        // 1. Shift Coverage Verification (1 to 2 nurses per shift)
        foreach (d; days) {
            foreach (s; shifts) {
                int cov = shiftCoverage.get(d ~ "_" ~ s, 0);
                assert(cov >= 1 && cov <= 2, format(
                    "Assertion Failure: Shift %s_%s has coverage %d outside [1..2]!",
                    d, s, cov));
            }
        }
        writeln("  ✅ assert shift_coverage_bounds (All 21 shifts covered by 1-2 nurses)");

        // 2. Workload Compliance Verification (2 to 5 shifts per nurse)
        foreach (n; nurses) {
            int load = nurseWorkloads[n];
            assert(load >= 2 && load <= 5, format(
                "Assertion Failure: Nurse %s workload %d outside [2..5]!",
                n, load));
        }
        writeln("  ✅ assert nurse_workload_bounds (All 10 nurses within 2-5 weekly shift bounds)");

        swTotal.stop();
        writefln("\n⏱️ Total End-to-End Wall Time: %d ms",
            swTotal.peek().total!"msecs");
        writeln("\n🎯 ALL AUDIT ASSERTIONS PASSED");

        return JSONValue([
            "status": JSONValue("VERIFIED_SATISFIABLE"),
            "total_shifts_assigned": JSONValue(cast(long) totalAssignedShifts)
        ]);
    });

    return app.run(args);
}
