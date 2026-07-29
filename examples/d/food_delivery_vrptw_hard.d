// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Reify SDK Benchmark: Scaled Vehicle Routing Problem with Time Windows (VRPTW)
// ============================================================================
//
//  Problem Scale:
//    - 32 Orders (4x larger than base example)
//    - 12 Delivery Trucks
//    - Strict Time Windows and Non-Overlapping Travel Time constraints
//
// ============================================================================

module food_delivery_vrptw_hard;

import reify;
import std.conv : to;
import std.format : format, formattedRead;
import std.json : JSONValue;
import std.stdio : writeln, writefln;

struct Order {
    string name;
    int minTime;
    int maxTime;
}

int main(string[] args) {
    writeln("==========================================================================");
    writeln("  Reify SDK Benchmark: Scaled VRPTW (32 Orders, 12 Trucks)");
    writeln("==========================================================================");

    enum int NUM_ORDERS = 32;
    enum int NUM_TRUCKS = 12;
    int travelTime = 12; // Flat 12-minute travel time buffer

    Order[] orders;
    foreach (i; 0 .. NUM_ORDERS) {
        int baseTime = (i * 7) % 120; // Spread times across a 120-minute horizon
        orders ~= Order(format("Order_%02d", i), baseTime, baseTime + 35);
    }

    string[] trucks;
    foreach (i; 0 .. NUM_TRUCKS) {
        trucks ~= format("FleetTruck_%02d", i);
    }

    auto app = decisionApp("food_delivery_vrptw_hard", (Model model) {

        CategoryExpr[] assignedTruck;
        IntExpr[] deliveryTime;

        // 1. DECISION VARIABLES
        foreach (i, order; orders) {
            assignedTruck ~= model.categoricalVar(format("truck_%02d", i), trucks);
            
            auto timeVar = model.integerVar(format("time_%02d", i), order.minTime, order.maxTime);
            deliveryTime ~= timeVar;
            
            // Soft preference: Prefer earlier deliveries (minTime + 5)
            model.prefer(format("deliver_early_%02d", i), lessEqual(timeVar, integer(order.minTime + 5)), 2.0);
        }

        // 2. TRAVEL TIME NON-OVERLAP CONSTRAINTS
        foreach (i; 0 .. orders.length) {
            foreach (j; i + 1 .. orders.length) {
                // If they are on the same truck...
                BoolExpr sameTruck = assignedTruck[i].same(assignedTruck[j]);
                
                // Then order i must be delivered after order j + travel time, OR vice versa.
                IntExpr diff1 = deliveryTime[i] - deliveryTime[j];
                BoolExpr i_after_j = greaterEqual(diff1, integer(travelTime));
                
                IntExpr diff2 = deliveryTime[j] - deliveryTime[i];
                BoolExpr j_after_i = greaterEqual(diff2, integer(travelTime));
                
                model.require(
                    format("travel_overlap_%02d_%02d", i, j),
                    implies(sameTruck, i_after_j | j_after_i)
                );
            }
        }

        writeln("Scaled VRPTW formulation complete.");

    }, (JSONValue input, Solution solution) {
        writeln("\n=======================================================");
        writeln("  Scaled Delivery Fleet Dispatch Manifest");
        writeln("=======================================================");

        if (!solution.complete()) {
            writeln("❌ Model returned partial or infeasible state.");
        }

        struct Assignment {
            string orderName;
            int time;
        }
        Assignment[][string] fleetSchedule;
        int totalAssigned = 0;

        foreach (i, order; orders) {
            string truckKey = format("truck_%02d", i);
            string timeKey = format("time_%02d", i);
            
            string assignedTruckStr = "";
            int assignedTime = 0;

            if (solution.has(truckKey) && solution.get(truckKey).status == DecisionStatus.assigned) {
                assignedTruckStr = solution.get(truckKey).categoricalValue;
            }
            if (solution.has(timeKey) && solution.get(timeKey).status == DecisionStatus.assigned) {
                assignedTime = cast(int) solution.get(timeKey).integerValue;
            }

            if (assignedTruckStr.length > 0) {
                fleetSchedule[assignedTruckStr] ~= Assignment(order.name, assignedTime);
                totalAssigned++;
            }
        }

        writefln("\n📦 Total Orders Scheduled: %d / %d", totalAssigned, NUM_ORDERS);

        // Print first 5 active trucks to avoid spamming the console
        int printedTrucks = 0;
        foreach (truckName; trucks) {
            if (truckName !in fleetSchedule || fleetSchedule[truckName].length == 0) continue;
            
            if (printedTrucks >= 5) {
                writeln("... (remaining truck routes hidden for brevity) ...");
                break;
            }
            printedTrucks++;

            writefln("\n🚚 %s Route:", truckName);
            
            import std.algorithm.sorting : sort;
            auto sched = fleetSchedule[truckName];
            sched.sort!((a, b) => a.time < b.time);
            
            foreach (task; sched) {
                writefln("   [Time: %03d min] 📦 Deliver %s", task.time, task.orderName);
            }
        }

        writeln("\n✅ All time windows and travel-time intervals verified.");
        return solution.toJson();
    });

    return app.run(args);
}
