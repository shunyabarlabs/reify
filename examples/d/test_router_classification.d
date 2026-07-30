import reify;
import std.stdio;
import std.format;

enum PIPELINE_DEPTH = 100;
enum DATAPATH_WIDTH = 2500; // 2500 * 100 * 6 = ~1.5 million native clauses

void main(string[] args) {
    writeln("==========================================================================");
    writeln("  Router Structural Classification Test (Scale: ", PIPELINE_DEPTH, "x", DATAPATH_WIDTH, ")");
    writeln("==========================================================================");
    
    auto model = new Model("hardware-bmc-test");
    BoolExpr[][] state = new BoolExpr[][](PIPELINE_DEPTH + 1, DATAPATH_WIDTH);
    
    writeln("Initializing logical variables...");
    foreach (t; 0 .. PIPELINE_DEPTH + 1) {
        foreach (i; 0 .. DATAPATH_WIDTH) {
            state[t][i] = model.booleanVar(format("s_t%d_i%d", t, i));
        }
    }

    writeln("Unrolling pipeline transitions (Building ~1.5M native clauses instantly)...");
    foreach (t; 1 .. PIPELINE_DEPTH + 1) {
        foreach (i; 0 .. DATAPATH_WIDTH) {
            auto C = state[t][i];
            auto A = state[t-1][i];
            auto B = state[t-1][(i + 1) % DATAPATH_WIDTH];
            auto D = state[t-1][(i + 2) % DATAPATH_WIDTH];
            
            auto notA = logicalNot(A);
            auto notB = logicalNot(B);
            auto notC = logicalNot(C);
            auto notD = logicalNot(D);

            model.requireClause("maj", [notC, A, B]);
            model.requireClause("maj", [notC, A, D]);
            model.requireClause("maj", [notC, B, D]);
            model.requireClause("maj", [C, notA, notB]);
            model.requireClause("maj", [C, notA, notD]);
            model.requireClause("maj", [C, notB, notD]);
        }
    }

    foreach (i; 0 .. 100) {
        model.requireClause("property", [state[PIPELINE_DEPTH][i]]);
    }

    writeln("\nCompiling model via Reify Decision Compiler...");
    CompileOptions opts;
    opts.maxEncodedVariables = 1_000_000;
    opts.maxEncodedClauses = 2_000_000;
    auto compiled = compile(model, opts);

    import reify.diagnostics : analyzeCompiled;
    auto topology = analyzeCompiled(compiled);
    
    import reify.router : recommendRouteByTopology;
    import reify.errors : UnsupportedDomainException;

    writeln("\nTesting Router Ingest Classifier...");
    try {
        auto rec = recommendRouteByTopology(topology, opts);
        writeln("FAIL: Router accepted the Hardware BMC instance. Expected UnsupportedDomainException.");
        import core.stdc.stdlib : exit;
        exit(1);
    } catch (UnsupportedDomainException e) {
        writeln("SUCCESS: Router correctly identified Hardware BMC logic and enforced lane discipline.");
        writeln("Exception message: ", e.msg);
    }
}
