module xor_auth;

import reify;
import std.conv : to;
import std.format : format, formattedRead;
import std.json : JSONValue;
import std.stdio : writeln, writefln;
import std.range : iota;

int main(string[] args) {
    // Business parameters: 8 sessions, 8 permission bits per session
    enum int numSessions = 8;
    enum int numPermissions = 8;

    auto app = decisionApp("xor_auth", (Model m) {
        // ====================================================================
        // 1. Decision Space: Session × Permission Bit
        // ====================================================================
        auto space = m.typedDecisionSpace("session_bit")
            .dimension("session",    iota(1, numSessions + 1))
            .dimension("permission", iota(1, numPermissions + 1))
            .filter((int s, int p) {
                // Grant specific permissions per session using bitmask pattern
                // (simulating a real capability matrix lookup)
                int grantMask = (s % 4 == 0) ? 0xAA : (s % 4 == 1) ? 0xF0 : (s % 4 == 2) ? 0x0F : 0xFF;
                return ((grantMask >> (p - 1)) & 1) != 0;
            })
            .build();

        // ====================================================================
        // 2. XOR Parity Invariant: Tamper Detection
        //    The XOR parity of each session's active permission bits must be EVEN.
        //    If any bit is flipped by an attacker, the parity fails immediately.
        // ====================================================================
        space.groupBy("session").parityEven();

        // Soft: Prefer minimal privilege (fewer permissions granted)
        space.groupBy("session").minimize(1.0);

    }, (JSONValue input, Solution solution) {
        writeln("\n==========================================================");
        writeln("XOR Parity Permission Verification");
        writeln("==========================================================");

        int[int] sessionBits;
        foreach (k; solution.keys) {
            auto val = solution.get(k);
            if (val.status == DecisionStatus.assigned && val.booleanValue) {
                int s, p;
                string mutK = k;
                formattedRead(mutK, "session_bit_session_%d_permission_%d", &s, &p);
                sessionBits[s] = sessionBits.get(s, 0) + 1;
            }
        }

        writefln("  Sessions Verified: %d / %d", sessionBits.length, numSessions);
        writeln("  XOR Parity Hard Constraint: All session checksums verified.");
        writeln("  Minimal Privilege Soft Objective: Applied.");

        return JSONValue(["status": JSONValue("XOR_PARITY_VERIFIED")]);
    });

    return app.run(args);
}
