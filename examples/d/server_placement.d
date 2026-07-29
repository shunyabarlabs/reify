module server_placement;

import reify;
import std.conv : to;
import std.format : format, formattedRead;
import std.json : JSONValue;
import std.stdio : writeln, writefln;
import std.range : iota;
import std.datetime.stopwatch : StopWatch, AutoStart;

int main(string[] args) {
    // Business Parameters
    enum int numServers = 10;
    enum int numVMs = 30;
    enum int numVMsPerServer = 4;        // Capacity: max 4 VMs per server
    enum int numGpuServers = 3;          // First 3 servers are GPU-enabled
    enum int numGpuVMs = 8;              // First 8 VMs require GPU

    auto app = decisionApp("server_placement", (Model m) {
        // ====================================================================
        // 1. Decision Space: VM × Server Placement
        // ====================================================================
        auto space = m.typedDecisionSpace("placement")
            .dimension("vm",     iota(1, numVMs + 1))
            .dimension("server", iota(1, numServers + 1))
            .filter((int vm, int server) {
                // GPU workloads MUST land on GPU servers
                if (vm <= numGpuVMs && server > numGpuServers) return false;

                // Non-GPU workloads MUST NOT consume GPU servers
                if (vm > numGpuVMs && server <= numGpuServers) return false;

                return true;
            })
            .build();

        // ====================================================================
        // 2. Business Invariants & SLA Policy
        // ====================================================================

        // Hard: Every VM placed on exactly one server
        space.groupBy("vm").exactlyOne();

        // Hard: Server capacity cap (max 4 VMs per server)
        space.groupBy("server").atMost(numVMsPerServer);

        // Soft MaxSAT: Prefer spreading VMs across servers (avoid hot-spots)
        space.groupBy("server").preferAtMostOne(50.0);

        // Soft Objective: Minimize fragmentation by preferring fewer servers
        space.groupBy("server").maximize(1.0);

    }, (JSONValue input, Solution solution) {
        writeln("\n==========================================================");
        writeln("Server Placement — Verified");
        writeln("==========================================================");

        int placed = 0;
        int[int] serverLoad;

        foreach (k; solution.keys) {
            auto val = solution.get(k);
            if (val.status == DecisionStatus.assigned && val.booleanValue) {
                int vm, server;
                string mutK = k;
                formattedRead(mutK, "placement_vm_%d_server_%d", &vm, &server);
                placed++;
                serverLoad[server] = serverLoad.get(server, 0) + 1;
            }
        }

        writefln("  VMs Placed:          %d / %d", placed, numVMs);
        writefln("  Servers Utilized:    %d / %d", serverLoad.length, numServers);

        foreach (s, load; serverLoad) {
            assert(load <= numVMsPerServer, format("Server %d overloaded: %d VMs!", s, load));
        }

        assert(placed == numVMs, "Not all VMs placed!");
        writeln("  Hard SLA: All VMs placed within server capacity limits.");
        writeln("  Hard Policy: GPU workloads landed on GPU-enabled servers.");
        writeln("  Soft Objective: Server consolidation preference applied.");

        return JSONValue([
            "status": JSONValue("PLACEMENT_VERIFIED"),
            "vms_placed": JSONValue(cast(long) placed),
            "servers_used": JSONValue(cast(long) serverLoad.length)
        ]);
    });

    return app.run(args);
}
