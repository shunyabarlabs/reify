// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  Autonomous Warehouse Robot Fleet Multi-Agent Pathfinding (MAPF) Benchmark
// ============================================================================
//
//  Models dynamic spatio-temporal pathfinding for 4 Autonomous Mobile Robots (AMRs)
//  navigating a 4x4 grid warehouse floor over a 7-tick operational horizon.
//
//  Hard CNF Constraints:
//  - 4 Autonomous Mobile Robots (AMRs)
//  - 4x4 Grid Workspace (16 spatial cells)
//  - 7 Time Ticks
//  - Single cell occupancy per robot per time tick
//  - Vertex Collision Exclusion (No two robots share the same cell at tick t)
//  - Edge Swapping Collision Exclusion (No two robots swap adjacent cells between t and t+1)
//  - Orthogonal Kinematic Grid Transitions (Move N/S/E/W or Wait in place)
//  - Start Depots at t=0 and Workstation Target Goals at t=6
//
// ============================================================================

module warehouse_mapf_extreme;

import reify;
import std.stdio;
import std.array : array;
import std.range : iota;
import std.format : format;
import std.conv : to;
import core.time : dur, seconds;

enum GRID_DIM = 4;
enum NUM_CELLS = GRID_DIM * GRID_DIM; // 16 cells
enum NUM_ROBOTS = 4;
enum NUM_TICKS = 7;

size_t cellIndex(size_t x, size_t y) {
    return y * GRID_DIM + x;
}

size_t cellX(size_t cell) {
    return cell % GRID_DIM;
}

size_t cellY(size_t cell) {
    return cell / GRID_DIM;
}

size_t[] getNeighbors(size_t cell) {
    size_t x = cellX(cell);
    size_t y = cellY(cell);
    size_t[] neighbors = [cell]; // Wait in place

    if (x > 0) neighbors ~= cellIndex(x - 1, y);            // West
    if (x + 1 < GRID_DIM) neighbors ~= cellIndex(x + 1, y); // East
    if (y > 0) neighbors ~= cellIndex(x, y - 1);            // North
    if (y + 1 < GRID_DIM) neighbors ~= cellIndex(x, y + 1); // South

    return neighbors;
}

void main() {
    writeln("==========================================================================");
    writeln("  Autonomous Warehouse Robot Fleet Multi-Agent Pathfinding (MAPF) Benchmark");
    writeln("==========================================================================");
    writeln("Workspace Grid: ", GRID_DIM, "x", GRID_DIM, " (", NUM_CELLS, " spatial cells)");
    writeln("Autonomous Mobile Robots (AMRs): ", NUM_ROBOTS);
    writeln("Time Horizon: ", NUM_TICKS, " time ticks");

    writeln("Logical Decision Variables: ", NUM_ROBOTS * NUM_CELLS * NUM_TICKS, " boolean spatial-temporal position flags");
    stdout.flush();

    auto model = new Model("warehouse-mapf-extreme");

    // Decision Variables: pos[r][c][t] = true if robot r is at cell c at time t
    BoolExpr[][][] pos;
    pos.length = NUM_ROBOTS;
    foreach (r; 0 .. NUM_ROBOTS) {
        pos[r].length = NUM_CELLS;
        foreach (c; 0 .. NUM_CELLS) {
            pos[r][c] = new BoolExpr[](NUM_TICKS);
            foreach (t; 0 .. NUM_TICKS) {
                pos[r][c][t] = model.booleanVar(format("pos[r%d,c%d,t%d]", r, c, t));
            }
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 1: Single Cell Occupancy Per Robot Per Tick
    // ------------------------------------------------------------------------
    writeln("\nAdding Single Cell Occupancy Constraints...");
    foreach (r; 0 .. NUM_ROBOTS) {
        foreach (t; 0 .. NUM_TICKS) {
            BoolExpr[] allCells;
            foreach (c; 0 .. NUM_CELLS) {
                allCells ~= pos[r][c][t];
            }
            model.require(
                format("single_cell_r%d_t%d", r, t),
                atMost(1, allCells)
            );
            model.require(
                format("active_cell_r%d_t%d", r, t),
                atLeast(1, allCells)
            );
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 2: Vertex Collision Avoidance
    // (No two robots share the same spatial cell c at time t)
    // ------------------------------------------------------------------------
    writeln("Adding Vertex Collision Exclusion Constraints...");
    foreach (c; 0 .. NUM_CELLS) {
        foreach (t; 0 .. NUM_TICKS) {
            BoolExpr[] robotsAtCell;
            foreach (r; 0 .. NUM_ROBOTS) {
                robotsAtCell ~= pos[r][c][t];
            }
            model.require(
                format("vertex_collision_c%d_t%d", c, t),
                atMost(1, robotsAtCell)
            );
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 3: Kinematic Orthogonal Movement & Waiting
    // (If robot r is at cell c at time t, it must be at a neighbor of c at t+1)
    // ------------------------------------------------------------------------
    writeln("Adding Orthogonal Kinematic Transition Constraints...");
    foreach (r; 0 .. NUM_ROBOTS) {
        foreach (c; 0 .. NUM_CELLS) {
            auto neighbors = getNeighbors(c);
            foreach (t; 0 .. NUM_TICKS - 1) {
                BoolExpr[] nextPossibleCells;
                foreach (nc; neighbors) {
                    nextPossibleCells ~= pos[r][nc][t+1];
                }
                model.require(
                    format("kinematic_trans_r%d_c%d_t%d", r, c, t),
                    implies(pos[r][c][t], atLeast(1, nextPossibleCells))
                );
            }
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 4: Edge Swapping Collision Avoidance
    // (~pos[r1][c1][t] | ~pos[r2][c2][t] | ~pos[r1][c2][t+1] | ~pos[r2][c1][t+1])
    // ------------------------------------------------------------------------
    writeln("Adding Edge Swapping Collision Exclusion Constraints...");
    foreach (c1; 0 .. NUM_CELLS) {
        auto neighbors = getNeighbors(c1);
        foreach (c2; neighbors) {
            if (c1 != c2) { // Adjacent cell
                foreach (r1; 0 .. NUM_ROBOTS) {
                    foreach (r2; r1 + 1 .. NUM_ROBOTS) {
                        foreach (t; 0 .. NUM_TICKS - 1) {
                            model.require(
                                format("edge_swap_r%d_r%d_c%d_c%d_t%d", r1, r2, c1, c2, t),
                                logicalNot(pos[r1][c1][t]) | logicalNot(pos[r2][c2][t]) |
                                logicalNot(pos[r1][c2][t+1]) | logicalNot(pos[r2][c1][t+1])
                            );
                        }
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 5: Start Depots at t=0 and Workstation Goals at t=NUM_TICKS-1
    // ------------------------------------------------------------------------
    writeln("Adding Start Depot & Workstation Goal Location Constraints...");
    foreach (r; 0 .. NUM_ROBOTS) {
        // Start: Robot r starts at row 0, column r
        size_t startCell = cellIndex(r, 0);
        model.require(
            format("start_depot_r%d", r),
            pos[r][startCell][0]
        );

        // Goal: Robot r must end at row 3, column (3 - r)
        size_t goalCell = cellIndex(GRID_DIM - 1 - r, GRID_DIM - 1);
        model.require(
            format("workstation_goal_r%d", r),
            pos[r][goalCell][NUM_TICKS - 1]
        );
    }

    // ------------------------------------------------------------------------
    // COMPILATION
    // ------------------------------------------------------------------------
    writeln("\nCompiling model via Reify Decision Compiler...");
    stdout.flush();
    CompileOptions opts;
    opts.maxBddNodesPerConstraint = 10_000_000;
    auto compiled = compile(model, opts);

    writeln("\n=== Compilation Summary ===");
    writeln(compiled.summary().toPrettyString());
    stdout.flush();

    // ------------------------------------------------------------------------
    // SOLVE VIA NAVOKOJ SOLVER ENGINE
    // ------------------------------------------------------------------------
    writeln("\n=== Solving via Navokoj Solver Substrate ===");
    stdout.flush();
    import std.process : environment;

    string apiKey = environment.get("NAVOKOJ_API_KEY", "");
    if (apiKey.length == 0) return;

    import reify.navokoj.client : NavokojClient, RequestOptions;
    import reify.router : RoutingRecommendation;
    import reify.errors : ApiException;

    RequestOptions reqOpts;
    reqOpts.apiKey = apiKey;
    reqOpts.transportTimeout = dur!"seconds"(120);

    auto client = new NavokojClient();

    RoutingRecommendation rec;
    rec.engine = "nitro";
    rec.hardware = "cpu";

    try {
        auto result = client.solveRaw(compiled, reqOpts, rec);
        writeln("\n=== Navokoj Response ===");
        writeln(result.toPrettyString());
        stdout.flush();
    } catch (ApiException e) {
        writeln("\nStatus Code: ", e.statusCode);
        writeln("API Error Raw Body: ", e.rawBody);
        stdout.flush();
    }
}
