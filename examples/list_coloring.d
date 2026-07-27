module list_coloring;

import reify;

import std.algorithm : canFind;
import std.json : JSONValue;
import std.string : format;

/**
 * List coloring in the relational decision schema.
 *
 * A candidate row is (vertex, color), filtered by that vertex's allowed list.
 * The relational constraints are then:
 *
 *   vertex -> exactly one surviving color
 *   edge   -> adjacent vertices cannot share a color
 *
 * This is the same possible-world construction used by SpaceTime; there is
 * simply no temporal dimension because coloring is a static decision problem.
 */
int main(string[] args) {
    auto app = decisionApp("list-coloring", (Model model) {
        string[] vertices = ["a", "b", "c", "d"];
        string[] colors = ["red", "green", "blue"];
        const string[][string] lists = [
            "a": ["red", "green"],
            "b": ["green", "blue"],
            "c": ["red", "blue"],
            "d": ["green", "blue"]
        ];

        auto space = model.decisionSpace("list-coloring")
            .dimension("vertex", vertices)
            .dimension("color", colors)
            .filter((const(string[string]) row) {
                return lists[row["vertex"]].canFind(row["color"]);
            })
            .build();

        space.groupBy("vertex").exactlyOne();

        BoolExpr[string] choice;
        foreach (candidate; space.candidates) {
            choice[candidate.tuple["vertex"] ~ "|" ~ candidate.tuple["color"]] =
                candidate.expr;
        }

        string[2][] edges = [
            ["a", "b"],
            ["b", "c"],
            ["c", "d"],
            ["a", "d"]
        ];
        foreach (edge; edges) {
            foreach (color; colors) {
                auto left = (edge[0] ~ "|" ~ color) in choice;
                auto right = (edge[1] ~ "|" ~ color) in choice;
                if (left !is null && right !is null) {
                    model.requireClause(
                        format("edge_%s_%s_not_%s", edge[0], edge[1], color),
                        [~(*left), ~(*right)]
                    );
                }
            }
        }
    }, (JSONValue, Solution solution) {
        return solution.toJson();
    });

    return app.run(args);
}
