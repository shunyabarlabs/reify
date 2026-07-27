module vehicle_routing;

import reify;
import std.json : JSONValue;

/** A small Hamiltonian-tour example showing the domain-neutral routing API. */
int main(string[] args) {
    auto app = decisionApp("vehicle-routing-d", (Model model) {
        const stops = ["depot", "customer_a", "customer_b", "customer_c"];
        const keys = [
            "depot->customer_a", "depot->customer_b", "depot->customer_c",
            "customer_a->depot", "customer_a->customer_b", "customer_a->customer_c",
            "customer_b->depot", "customer_b->customer_a", "customer_b->customer_c",
            "customer_c->depot", "customer_c->customer_a", "customer_c->customer_b"
        ];
        auto arcs = model.booleanVars("route", keys);

        // Each customer is visited exactly once and departed exactly once.
        foreach (stop; stops[1 .. $]) {
            IntExpr[] incoming;
            IntExpr[] outgoing;
            foreach (from; stops) {
                if (from != stop) {
                    incoming ~= asInteger(arcs[from ~ "->" ~ stop]);
                    outgoing ~= asInteger(arcs[stop ~ "->" ~ from]);
                }
            }
            model.require("one arrival at " ~ stop,
                equal(sumExpr(incoming), integer(1)));
            model.require("one departure from " ~ stop,
                equal(sumExpr(outgoing), integer(1)));
        }

        // The vehicle leaves and returns to the depot exactly once.
        model.require("leave depot once", equal(sumExpr([
            asInteger(arcs["depot->customer_a"]),
            asInteger(arcs["depot->customer_b"]),
            asInteger(arcs["depot->customer_c"])
        ]), integer(1)));
        model.require("return to depot once", equal(sumExpr([
            asInteger(arcs["customer_a->depot"]),
            asInteger(arcs["customer_b->depot"]),
            asInteger(arcs["customer_c->depot"])
        ]), integer(1)));

        // Distances are scaled integer costs, making verification exact.
        int[] distance = [10, 14, 12, 10, 8, 9, 14, 8, 7, 12, 9, 7];
        IntExpr[] cost;
        foreach (i, key; keys) cost ~= distance[i] * asInteger(arcs[key]);
        model.minimize("total route distance", sumExpr(cost));
    }, (JSONValue input, Solution solution) {
        JSONValue[] selected;
        foreach (key; [
            "depot->customer_a", "depot->customer_b", "depot->customer_c",
            "customer_a->depot", "customer_a->customer_b", "customer_a->customer_c",
            "customer_b->depot", "customer_b->customer_a", "customer_b->customer_c",
            "customer_c->depot", "customer_c->customer_a", "customer_c->customer_b"
        ]) if (solution.get("route[" ~ key ~ "]").booleanValue) selected ~= JSONValue(key);
        JSONValue[string] output;
        output["selected_arcs"] = JSONValue(selected);
        return JSONValue(output);
    });
    return app.run(args);
}
