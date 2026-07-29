module ramsey;
import reify;
import std.json : JSONValue;

int main(string[] args) {
    auto app = decisionApp("ramsey", (Model m) {
        auto e = m.booleanVars("red", ["01", "02", "03", "12", "13", "23"]);
        // R(3,3) on K6: every triangle must contain both colors.
        foreach (triangle; [["01", "02", "12"], ["01", "03", "13"], ["02", "03", "23"]]) {
            BoolExpr[] red; foreach (edge; triangle) red ~= e[edge];
            m.requireClause("red triangle forbidden", [~red[0], ~red[1], ~red[2]]);
            m.requireClause("blue triangle forbidden", [red[0], red[1], red[2]]);
        }
    }, (JSONValue i, Solution s) { return s.toJson(); });
    return app.run(args);
}
