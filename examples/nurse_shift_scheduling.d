module nurse_shift_scheduling;

import reify;
import std.conv : to;
import std.format : format, formattedRead;
import std.json : JSONValue;
import std.stdio : writeln, writefln;
import std.datetime.stopwatch : StopWatch, AutoStart;

int main(string[] args) {
    // ------------------------------------------------------------------------
    // Nurse Shift Timetabling — Navokoj Decision Language (NDL) Showcase
    // ------------------------------------------------------------------------
    enum string[] nurses = ["N1", "N2", "N3", "N4", "N5", "N6", "N7", "N8", "N9", "N10"];
    enum string[] days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
    enum string[] shifts = ["Morning", "Evening", "Night"];

    auto swTotal = StopWatch(AutoStart.yes);

    auto app = decisionApp("nurse_shift_scheduling", (Model m) {
        // ====================================================================
        // 1. Declarative Decision Matrix using NDL productVarSet3D
        // Replaces manual 3-deep nested loops with a single NDL builder call!
        // ====================================================================
        auto matrix = m.productVarSet3D("shift", nurses, days, shifts);

        // Group index maps for NDL cardinality constraints
        BoolExpr[][string] nurseDayShifts;
        BoolExpr[][string] dayShiftNurses;
        BoolExpr[][string] nurseWeeklyShifts;

        foreach (n; nurses) {
            foreach (d; days) {
                foreach (s; shifts) {
                    string key = format("shift_%s_%s_%s", n, d, s);
                    auto var = matrix[key];

                    nurseDayShifts[n ~ "_" ~ d] ~= var;
                    dayShiftNurses[d ~ "_" ~ s] ~= var;
                    nurseWeeklyShifts[n] ~= var;
                }
            }
        }

        // ====================================================================
        // 2. High-Level Business Invariants via NDL Primitives
        // ====================================================================

        // A. Max 1 shift per nurse per day
        m.applyGroupConstraint("atMostOne", "nurse_daily", nurseDayShifts);

        // B. Shift Coverage: 1 to 2 nurses required per shift per day
        foreach (dsKey, exprs; dayShiftNurses) {
            m.require(format("coverage_%s", dsKey), between(1, 2, exprs));
        }

        // C. Labor Compliance: 2 to 5 shifts total per nurse per week
        foreach (n, exprs; nurseWeeklyShifts) {
            m.require(format("weekly_workload_%s", n), between(2, 5, exprs));
        }

        // D. Rest Window: A nurse working Night cannot work Morning the next day
        foreach (n; nurses) {
            foreach (i; 0 .. days.length - 1) {
                string nightKey = format("shift_%s_%s_Night", n, days[i]);
                string nextMorningKey = format("shift_%s_%s_Morning", n, days[i + 1]);

                m.require(
                    format("rest_period_%s_%s", n, days[i]),
                    unless(logicalNot(matrix[nextMorningKey]), matrix[nightKey])
                );
            }
        }
    }, (JSONValue input, Solution solution) {
        writeln("\n=======================================================");
        writeln("🏥 Navokoj D SDK: Nurse Shift Scheduling Auditor (NDL)");
        writeln("=======================================================");

        int totalAssignedShifts = 0;
        int[string] nurseWorkloads;
        int[string] shiftCoverage;

        foreach (n; nurses) nurseWorkloads[n] = 0;

        foreach (n; nurses) {
            foreach (d; days) {
                foreach (s; shifts) {
                    string key = format("shift_%s_%s_%s", n, d, s);
                    if (solution.has(key) && solution.get(key).booleanValue) {
                        totalAssignedShifts++;
                        nurseWorkloads[n]++;
                        shiftCoverage[d ~ "_" ~ s] = shiftCoverage.get(d ~ "_" ~ s, 0) + 1;
                    }
                }
            }
        }

        writefln("\n📊 Solution Summary:");
        writefln("  • Total Shifts Assigned: %d", totalAssignedShifts);
        writefln("  • Total Nurses Scheduled: %d / %d", nurseWorkloads.length, nurses.length);

        writeln("\n🧪 Running NDL Audit Assertions:");

        // 1. Shift Coverage Verification (1 to 2 nurses per shift)
        foreach (d; days) {
            foreach (s; shifts) {
                int cov = shiftCoverage.get(d ~ "_" ~ s, 0);
                assert(cov >= 1 && cov <= 2, format("Assertion Failure: Shift %s_%s has coverage %d outside [1..2]!", d, s, cov));
            }
        }
        writeln("  ✅ assert shift_coverage_bounds (All 21 shifts covered by 1-2 nurses)");

        // 2. Workload Compliance Verification (2 to 5 shifts per nurse)
        foreach (n; nurses) {
            int load = nurseWorkloads[n];
            assert(load >= 2 && load <= 5, format("Assertion Failure: Nurse %s workload %d outside [2..5]!", n, load));
        }
        writeln("  ✅ assert nurse_workload_bounds (All 10 nurses within 2-5 weekly shift bounds)");

        swTotal.stop();
        writefln("\n⏱️ Total End-to-End Wall Time: %d ms", swTotal.peek().total!"msecs");
        writeln("\n🎯 ALL NDL AUDIT ASSERTIONS PASSED NATIVELY!");

        return JSONValue([
            "status": JSONValue("VERIFIED_SATISFIABLE"),
            "total_shifts_assigned": JSONValue(cast(long) totalAssignedShifts)
        ]);
    });

    return app.run(args);
}
