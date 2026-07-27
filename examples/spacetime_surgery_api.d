module examples.spacetime_surgery_api;

import reify;

import std.json : JSONValue;
import std.stdio : writeln;

enum Patient {
    alice,
    bob
}

enum Doctor {
    master,
    resident
}

enum Activity {
    preop,
    surgery
}

enum Slot {
    morning,
    noon,
    evening,
    night
}

alias PatientDim = Dimension!("patient", Patient);
alias DoctorDim = Dimension!("doctor", Doctor);
alias ActivityDim = Dimension!("activity", Activity);
alias SlotDim = TimeDimension!("slot", Slot);

int main(string[] args) {
    auto app = decisionApp("spacetime-surgery-api", (Model model) {
        auto schedule =
            model.spaceTime!(PatientDim, DoctorDim, ActivityDim, SlotDim)(
                "surgery"
            )
            .dimension!PatientDim([Patient.alice, Patient.bob])
            .dimension!DoctorDim([Doctor.master, Doctor.resident])
            .dimension!ActivityDim([Activity.preop, Activity.surgery])
            .time!SlotDim([
                Slot.morning,
                Slot.noon,
                Slot.evening,
                Slot.night
            ])
            .build();

        schedule.duration!ActivityDim(Activity.preop, 1);
        schedule.duration!ActivityDim(Activity.surgery, 2);
        schedule.groupBy!(PatientDim, ActivityDim)().exactlyOne();
        schedule.groupBy!(DoctorDim, SlotDim)().atMostOne();
        schedule.within!DoctorDim(
            timeWindow([
                Slot.morning,
                Slot.noon,
                Slot.evening,
                Slot.night
            ])
        );
        schedule.before("preop", "surgery", "patient");
        schedule.apply(
            prefer!DoctorDim(Doctor.master, 5)
        );
    }, (JSONValue input, Solution solution) {
        size_t assigned;
        foreach (name; solution.keys) {
            auto value = solution.get(name);
            if (value.status == DecisionStatus.assigned) ++assigned;
        }
        return JSONValue([
            // The presenter only sees the assignment projection.  The API
            // envelope carries feasibility and verification truth.
            "status": JSONValue("SPACETIME_PRESENTED"),
            "assigned_decisions": JSONValue(cast(long) assigned)
        ]);
    });

    return app.run(args);
}
