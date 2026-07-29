module examples.spacetime_surgery;

import reify;
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
    evening
}

alias PatientDim = Dimension!("patient", Patient);
alias DoctorDim = Dimension!("doctor", Doctor);
alias ActivityDim = Dimension!("activity", Activity);
alias SlotDim = TimeDimension!("slot", Slot);

int main() {
    auto model = new Model("surgery");
    auto spaceTime =
        model.spaceTime!(PatientDim, DoctorDim, ActivityDim, SlotDim)(
            "surgery"
        )
        .dimension!PatientDim([Patient.alice, Patient.bob])
        .dimension!DoctorDim([Doctor.master, Doctor.resident])
        .dimension!ActivityDim([Activity.preop, Activity.surgery])
        .time!SlotDim([Slot.morning, Slot.noon, Slot.evening])
        .build();

    spaceTime.duration!ActivityDim(Activity.preop, 1);
    spaceTime.duration!ActivityDim(Activity.surgery, 2);
    auto workingHours = timeWindow([Slot.morning, Slot.noon]);
    auto noDoctorCollision =
        nonOverlapping!DoctorDim().within(workingHours);
    auto surgeryPolicy =
        exactlyOnePer!(PatientDim, ActivityDim)()
            .and(noDoctorCollision)
            .and(capacity(DoctorDim.name, 1))
            .and(prefer!DoctorDim(Doctor.master, 20));

    spaceTime.apply(surgeryPolicy);
    spaceTime.before("preop", "surgery", "patient");

    CompileOptions options;
    options.preferQState = false;
    auto artifact = model.emit!WCNF(options);
    writeln(artifact.payload);
    writeln(artifact.verificationManifest.toPrettyString());
    return 0;
}
