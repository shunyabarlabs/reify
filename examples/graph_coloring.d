module graph_coloring;
import reify;
import std.json : JSONValue;

int main(string[] args) {
    auto app = decisionApp("graph-coloring", (Model m) {
        auto v = m.booleanVars("color", ["a1", "a2", "b1", "b2", "c1", "c2"]);
        foreach (vertex; ["a", "b", "c"]) m.require("one color " ~ vertex,
            equal(asInteger(v[vertex ~ "1"]) + asInteger(v[vertex ~ "2"]), integer(1)));
        foreach (edge; [["a", "b"], ["b", "c"], ["a", "c"]])
            foreach (color; ["1", "2"]) m.requireClause("edge " ~ edge[0] ~ edge[1],
                [~v[edge[0] ~ color], ~v[edge[1] ~ color]]);
    }, (JSONValue i, Solution s) { return s.toJson(); });
    return app.run(args);
}
