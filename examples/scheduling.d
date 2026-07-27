module scheduling;
import reify;
import std.json : JSONValue;

int main(string[] args) {
    auto app = decisionApp("scheduling", (Model m) {
        auto x = m.booleanVars("assign", ["alice_m1", "alice_m2", "bob_m1", "bob_m2"]);
        m.require("alice once", equal(asInteger(x["alice_m1"]) + asInteger(x["alice_m2"]), integer(1)));
        m.require("bob once", equal(asInteger(x["bob_m1"]) + asInteger(x["bob_m2"]), integer(1)));
        foreach (shift; ["m1", "m2"]) m.require("one per " ~ shift,
            lessEqual(asInteger(x["alice_" ~ shift]) + asInteger(x["bob_" ~ shift]), integer(1)));
    }, (JSONValue i, Solution s) { return s.toJson(); });
    return app.run(args);
}
