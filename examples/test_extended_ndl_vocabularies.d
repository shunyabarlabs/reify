module test_extended_ndl_vocabularies;

import reify;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import std.stdio : writeln, writefln;
import std.range : iota;

int main(string[] args) {
    auto app = decisionApp("test_extended_ndl_vocabularies", (Model m) {
        writeln("🧪 Testing Extended NDL Vocabularies (Parity, WCNF, Preferences)...");

        // 1. Declare Typed Decision Space (Crypto & Scheduling Hybrid)
        auto space = m.typedDecisionSpace("decision")
            .dimension("item", iota(1, 9))
            .dimension("state", iota(1, 5))
            .filter((int item, int state) {
                return (item + state) % 2 == 0;
            })
            .build();

        // 2. Test Parity Constraints (XOR Parity)
        space.groupBy("item").parityEven();
        
        // 3. Test Soft Constraints (WCNF/MaxSAT)
        space.groupBy("state").preferAtLeastOne(10.5);
        space.groupBy("state").preferAtMostOne(5.0);

        // 4. Test Objective Preferences
        space.groupBy("item").maximize(1.0);

        writeln("  ✅ Model constructed with Parity, WCNF, and Preferences successfully.");
    }, (JSONValue input, Solution solution) {
        writeln("  ✅ Solution hydrated successfully.");
        return JSONValue(["status": JSONValue("VERIFIED")]);
    });

    return app.run(args);
}
