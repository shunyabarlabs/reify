module spacetime_exam_timetabling;

import reify;

import std.conv : to;
import std.json : JSONValue;
import std.string : format;

/**
 * A deliberately difficult SpaceTime workload:
 *
 *   exam × room × slot
 *
 * Each exam has a filtered room/slot list, conflict edges force adjacent
 * exams into different slots, room-slot groups have capacity one, and early
 * slots are soft preferences. This is list coloring embedded in temporal
 * resource allocation.
 */
int main(string[] args) {
    enum examCount = 64;

    auto app = decisionApp("spacetime-exam-timetabling", (Model model) {
        string[] exams;
        foreach (i; 0 .. examCount) exams ~= format("exam-%02d", i);

        string[] rooms = [
            "room-0", "room-1", "room-2", "room-3", "room-4", "room-5"
        ];
        int[] capacities = [30, 50, 70, 90, 120, 150];

        string[] slots;
        foreach (i; 0 .. 16) slots ~= format("slot-%02d", i);

        auto schedule = model.spaceTime("exam-timetable")
            .dimension("exam", exams)
            .dimension("room", rooms)
            .time("slot", slots)
            .filter((const(string[string]) row) {
                const size_t exam = cast(size_t) row["exam"][5 .. $].to!size_t;
                const size_t room = cast(size_t) row["room"][5 .. $].to!size_t;
                const size_t slot = cast(size_t) row["slot"][5 .. $].to!size_t;
                const int examSize = 20 + cast(int)((exam * 13) % 71);

                if (examSize > capacities[room]) return false;
                if ((room + slot + exam) % 11 == 0) return false;
                return (exam * 3 + slot) % 13 != 0;
            })
            .build();

        schedule.groupBy("exam").exactlyOne();
        schedule.groupBy("room", "slot").atMostOne();
        schedule.preferValue("slot", "slot-00", 3);
        schedule.preferValue("slot", "slot-01", 2);

        BoolExpr[string] choice;
        foreach (candidate; schedule.candidates) {
            choice[
                candidate.tuple["exam"] ~ "|" ~
                candidate.tuple["room"] ~ "|" ~
                candidate.tuple["slot"]
            ] = candidate.expr;
        }

        // Conflict graph: approximately 1/15 of all exam pairs share students.
        foreach (i; 0 .. examCount) {
            foreach (j; i + 1 .. examCount) {
                if ((i * 37 + j * 17) % 31 >= 2) continue;
                foreach (slot; slots) {
                    foreach (leftRoom; rooms) {
                        auto left = (format("exam-%02d", i) ~ "|" ~ leftRoom ~ "|" ~ slot) in choice;
                        if (left is null) continue;
                        foreach (rightRoom; rooms) {
                            auto right = (format("exam-%02d", j) ~ "|" ~ rightRoom ~ "|" ~ slot) in choice;
                            if (right is null) continue;
                            model.requireClause(
                                format("student_conflict_%02d_%02d_%s", i, j, slot),
                                [~(*left), ~(*right)]
                            );
                        }
                    }
                }
            }
        }
    }, (JSONValue, Solution solution) {
        return solution.toJson();
    });

    return app.run(args);
}
