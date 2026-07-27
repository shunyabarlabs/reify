module crop_app;

import reify;

import std.json : JSONValue;

int main(string[] args) {
    auto app = decisionApp(
        "crop-allocation-d",
        (Model model) {
            const crops = ["wheat", "chickpea", "rice"];
            auto acres = model.integerVars("acres", 0, 100, crops);

            IntExpr[] planted;
            foreach (crop; crops) {
                planted ~= acres[crop];
            }

            model.require(
                "field capacity",
                lessEqual(sumExpr(planted), integer(100))
            );
            model.require(
                "minimum chickpea contract",
                greaterEqual(acres["chickpea"], integer(10))
            );
            model.prefer(
                "crop diversity",
                greaterEqual(acres["rice"], integer(10)),
                5
            );
            model.maximize(
                "expected profit",
                30 * acres["wheat"] +
                22 * acres["chickpea"] +
                18 * acres["rice"]
            );
        },
        (JSONValue input, Solution solution) {
            JSONValue[string] allocation;
            foreach (crop; ["wheat", "chickpea", "rice"]) {
                allocation[crop] =
                    solution.get("acres[" ~ crop ~ "]").toJson();
            }

            JSONValue[string] output;
            output["acreage_by_crop"] = JSONValue(allocation);
            return JSONValue(output);
        }
    );

    return app.run(args);
}
