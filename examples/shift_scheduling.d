// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Reify SDK Example: Nurse Shift Scheduling (Direct .d Input Workflow)
// ============================================================================
//
//  Problem Domain:
//    8 staff members (nurses/engineers) scheduled across 7 days × 3 daily shifts
//    Shifts: 0 (Morning), 1 (Evening), 2 (Night)
//
//  Hard Constraints:
//    - Every nurse works at most 1 shift per day
//    - Each shift requires minimum staffing (2 for Morning, 2 for Evening, 1 for Night)
//    - Rest period: Night shift (2) on Day D forbids Morning shift (0) on Day D+1
//
//  Soft Constraints:
//    - Preferred shifts per nurse (e.g. Senior staff prefer Morning)
//    - Weekend off preferences
//
// ============================================================================

module shift_scheduling;

import reify;
import std.conv : to;
import std.format : format, formattedRead;
import std.json : JSONValue;
import std.range : iota;
import std.stdio : writeln, writefln;

int main(string[] args) {
    writeln("==========================================================================");
    writeln("  Reify SDK Example: Team Shift Scheduling (8 staff × 7 days × 3 shifts)");
    writeln("==========================================================================");

    enum int STAFF = 8;
    enum int DAYS  = 7;
    enum int SHIFTS = 3; // 0: Morning, 1: Evening, 2: Night

    auto app = decisionApp("nurse_roster", (Model model) {

        // 1. TYPED DECISION SPACE
        auto space = model.typedDecisionSpace("roster")
            .dimension("staff", iota(0, STAFF))
            .dimension("day",   iota(0, DAYS))
            .dimension("shift", iota(0, SHIFTS))
            .build();

        // 2. HARD CONSTRAINTS
        // Max 1 shift per staff member per day
        space.groupBy("staff", "day").atMostOne();

        // Daily Shift Staffing Requirements
        // Morning: >= 2 staff, Evening: >= 2 staff, Night: >= 1 staff
        foreach (d; 0 .. DAYS) {
            BoolExpr[] morningLits, eveningLits, nightLits;
            foreach (ref c; space.inner.candidates) {
                int day   = c.tuple["day"].to!int;
                int shift = c.tuple["shift"].to!int;
                if (day != d) continue;
                if (shift == 0) morningLits ~= c.expr;
                if (shift == 1) eveningLits ~= c.expr;
                if (shift == 2) nightLits   ~= c.expr;
            }
            model.require(format("staffing_morn_d%d", d), atLeast(2, morningLits));
            model.require(format("staffing_eve_d%d",  d), atLeast(2, eveningLits));
            model.require(format("staffing_night_d%d", d), atLeast(1, nightLits));
        }

        // Rest Period: Night shift on day D forbids Morning shift on day D+1
        BoolExpr[][int][int] staffDayShift;
        foreach (ref c; space.inner.candidates) {
            int st    = c.tuple["staff"].to!int;
            int dy    = c.tuple["day"].to!int;
            int sh    = c.tuple["shift"].to!int;
            staffDayShift[st][dy * SHIFTS + sh] ~= c.expr;
        }

        int restClauses = 0;
        foreach (st; 0 .. STAFF) {
            foreach (d; 0 .. DAYS - 1) {
                auto nightKey = d * SHIFTS + 2;      // Night shift today
                auto mornKey  = (d + 1) * SHIFTS + 0; // Morning shift tomorrow

                if (nightKey !in staffDayShift[st] || mornKey !in staffDayShift[st]) continue;
                foreach (ref nightExpr; staffDayShift[st][nightKey]) {
                    foreach (ref mornExpr; staffDayShift[st][mornKey]) {
                        model.requireClause(
                            format("rest_s%d_d%d_%d", st, d, restClauses++),
                            [~nightExpr, ~mornExpr]
                        );
                    }
                }
            }
        }

        // 3. SOFT PREFERENCES
        // Senior Staff (0, 1) prefer Morning shifts
        foreach (st; 0 .. 2) {
            BoolExpr[] prefMorn;
            foreach (d; 0 .. DAYS) {
                auto key = d * SHIFTS + 0;
                if (key in staffDayShift[st])
                    prefMorn ~= staffDayShift[st][key];
            }
            if (prefMorn.length > 0)
                model.preferClause(format("senior_morn_s%d", st), prefMorn, 10.0);
        }

        // Weekend off preference for Staff 2, 3 (Days 5, 6)
        foreach (st; 2 .. 4) {
            foreach (d; [5, 6]) {
                foreach (sh; 0 .. SHIFTS) {
                    auto key = d * SHIFTS + sh;
                    if (key in staffDayShift[st]) {
                        foreach (ref e; staffDayShift[st][key])
                            model.preferClause(format("wknd_off_s%d_d%d", st, d), [~e], 5.0);
                    }
                }
            }
        }

        // 4. ON-CALL CREW ROTATION (XOR PARITY)
        // Ensure even parity of night-shift staff across the week
        BoolExpr[] nightLitsAll;
        foreach (st; 0 .. STAFF) {
            foreach (d; 0 .. DAYS) {
                auto key = d * SHIFTS + 2;
                if (key in staffDayShift[st])
                    nightLitsAll ~= staffDayShift[st][key];
            }
        }
        if (nightLitsAll.length >= 2)
            model.parity("night_crew_parity", nightLitsAll, 0);

        writeln("Model definition complete.");

    }, (JSONValue input, Solution solution) {
        writeln("\n=======================================================");
        writeln("  Nurse Shift Roster — Verification & Schedule");
        writeln("=======================================================");

        int totalAssigned = 0;
        string[int][int] schedule; // staff -> day -> shift string

        foreach (key; solution.keys) {
            auto val = solution.get(key);
            if (val.status != DecisionStatus.assigned || !val.booleanValue)
                continue;

            int st, d, sh;
            string mutK = key;
            try {
                formattedRead(mutK, "roster_staff_%d_day_%d_shift_%d", &st, &d, &sh);
            } catch (Exception) { continue; }

            totalAssigned++;
            string shiftName = (sh == 0) ? "Morning" : (sh == 1) ? "Evening" : "Night";
            schedule[st][d] = shiftName;
        }

        writefln("\n📊 Total Shifts Assigned: %d", totalAssigned);
        writeln("\n📅 Weekly Schedule Matrix:");
        writeln("Staff  | Mon     | Tue     | Wed     | Thu     | Fri     | Sat     | Sun     |");
        writeln("--------------------------------------------------------------------------------");

        foreach (st; 0 .. STAFF) {
            string line = format("S%-5d| ", st);
            foreach (d; 0 .. DAYS) {
                string sName = schedule.get(st, null) !is null
                    ? schedule[st].get(d, "OFF    ")
                    : "OFF    ";
                line ~= format("%-8s| ", sName);
            }
            writeln(line);
        }

        return solution.toJson();
    });

    return app.run(args);
}
