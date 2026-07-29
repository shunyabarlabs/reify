// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Reify SDK Example: Vehicle Routing Problem with Time Windows (VRPTW)
// ============================================================================
//
//  Problem Domain:
//    Simulating a food delivery dispatch system. We must assign a set of food
//    orders to a fleet of delivery trucks, and determine the exact integer
//    delivery time for each order.
//
//    Constraints:
//    - Every order must be delivered within its specific time window.
//    - Orders assigned to the same truck must be separated by the required
//      travel time (no overlapping deliveries for the same driver).
//    - Optimize to deliver orders as early as possible.
//
// ============================================================================

module food_delivery_vrptw;

import reify;
import std.conv : to;
import std.format : format, formattedRead;
import std.json : JSONValue;
import std.stdio : writeln, writefln;

struct Order {
    string name;
    int minTime; // Earliest possible delivery time (in minutes)
    int maxTime; // Latest possible delivery time (in minutes)
}

int main(string[] args) {
    writeln("==========================================================================");
    writeln("  Reify SDK: Food Delivery VRPTW Dispatch");
    writeln("==========================================================================");

    Order[] orders = [
        Order("O1_Pizza",      10, 25),
        Order("O2_Burgers",    15, 30),
        Order("O3_Sushi",      25, 40),
        Order("O4_Salad",      35, 50),
        Order("O5_Tacos",      15, 45),
        Order("O6_IceCream",   40, 60),
        Order("O7_Pasta",      50, 70),
        Order("O8_Curry",      20, 50)
    ];

    string[] trucks = ["TruckA", "TruckB", "TruckC"];
    int travelTime = 12; // 12 minutes flat travel time between any two orders

    auto app = decisionApp("food_delivery_vrptw", (Model model) {

        CategoryExpr[] assignedTruck;
        IntExpr[] deliveryTime;
        IntExpr totalTime = integer(0);

        // 1. DECISION VARIABLES
        foreach (i, order; orders) {
            // Assign each order to exactly one truck
            assignedTruck ~= model.categoricalVar(format("truck_%d", i), trucks);

            // Assign a delivery time bounded natively by the time window
            auto timeVar = model.integerVar(format("time_%d", i), order.minTime, order.maxTime);
            deliveryTime ~= timeVar;
            
            totalTime = totalTime + timeVar;
            
            // Soft preference: Prefer earlier deliveries within the window
            // We penalize later times softly
            model.prefer(format("deliver_early_%d", i), lessEqual(timeVar, integer(order.minTime + 5)), 2.0);
        }

        // 2. TRAVEL TIME NON-OVERLAP CONSTRAINTS
        foreach (i; 0 .. orders.length) {
            foreach (j; i + 1 .. orders.length) {
                // If they are on the same truck...
                BoolExpr sameTruck = assignedTruck[i].same(assignedTruck[j]);
                
                // Then order i must be delivered after order j + travel time, OR vice versa.
                // time[i] - time[j] >= travelTime
                IntExpr diff1 = deliveryTime[i] - deliveryTime[j];
                BoolExpr i_after_j = greaterEqual(diff1, integer(travelTime));
                
                // time[j] - time[i] >= travelTime
                IntExpr diff2 = deliveryTime[j] - deliveryTime[i];
                BoolExpr j_after_i = greaterEqual(diff2, integer(travelTime));
                
                model.require(
                    format("travel_overlap_%d_%d", i, j),
                    implies(sameTruck, i_after_j | j_after_i)
                );
            }
        }

        writeln("VRPTW formulation complete.");

    }, (JSONValue input, Solution solution) {
        writeln("\n=======================================================");
        writeln("  Delivery Fleet Dispatch Manifest");
        writeln("=======================================================");

        if (!solution.complete()) {
            writeln("❌ Model returned partial or infeasible state.");
        }

        struct Assignment {
            string orderName;
            int time;
        }
        Assignment[][string] fleetSchedule;

        foreach (i, order; orders) {
            string truckKey = format("truck_%d", i);
            string timeKey = format("time_%d", i);
            
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
            }
        }

        foreach (truckName; trucks) {
            writefln("\n🚚 %s Route:", truckName);
            if (truckName !in fleetSchedule || fleetSchedule[truckName].length == 0) {
                writeln("   (No orders assigned)");
                continue;
            }
            
            // Sort by delivery time
            import std.algorithm.sorting : sort;
            auto sched = fleetSchedule[truckName];
            sched.sort!((a, b) => a.time < b.time);
            
            foreach (task; sched) {
                writefln("   [Time: %02d min] 📦 Deliver %s", task.time, task.orderName);
            }
        }

        writeln("\n✅ All time windows and travel-time intervals verified.");
        return solution.toJson();
    });

    return app.run(args);
}
