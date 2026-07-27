// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.app;

import reify.navokoj.client : NavokojClient, RequestOptions, defaultBaseUrl;
import reify.navokoj.backend : NavokojBackend;
import reify.transport : HttpTransport;
import reify.backend : Capabilities;
import reify.compiler;
import reify.dimacs : dimacsToDocumentJson;
import reify.diagnostics;
import reify.errors;
import reify.model;
import reify.opb : opbToDocumentJson;
import reify.result;
import reify.router;

import std.conv : to;
import std.datetime : dur;
import std.file : readText, write;
import std.json : JSONValue, parseJSON;
import std.process : environment;
import std.stdio : stderr, stdin, stdout;
import std.string : startsWith, strip, toLower;

alias ModelBuilder = void delegate(Model model, JSONValue input);
alias StaticModelBuilder = void delegate(Model model);
alias SolutionPresenter = JSONValue delegate(
    JSONValue input,
    Solution solution
);

struct AppSolveOptions {
    CompileOptions compilation;
    RequestOptions request;
}

/**
 * A directly runnable, domain-neutral Navokoj decision application.
 *
 * Applications receive their domain input as JSON and build a symbolic Model.
 * A presenter may convert the hydrated named decisions into any output shape.
 */
final class NavokojApp {
    string name;
    private ModelBuilder builder;
    private SolutionPresenter presenter;

    this(
        string name,
        ModelBuilder builder,
        SolutionPresenter presenter = null
    ) {
        if (name.length == 0) {
            throw new ModelException("Application name cannot be empty");
        }
        if (builder is null) {
            throw new ModelException("Application model builder cannot be null");
        }
        this.name = name;
        this.builder = builder;
        this.presenter = presenter;
    }

    Model build(JSONValue input) {
        // This is the domain boundary. Builders know about crops, shifts,
        // portfolios, etc.; the compiler below must remain domain-neutral.
        auto model = new Model(name);
        builder(model, input);
        return model;
    }

    CompiledModel compile(
        JSONValue input,
        CompileOptions options = CompileOptions()
    ) {
        // Compilation is deliberately separate from solving so interns can
        // inspect the exact wire request without spending API credits.
        return reify.compiler.compile(build(input), options);
    }

    SolveResult solve(
        JSONValue input,
        AppSolveOptions options = AppSolveOptions(),
        HttpTransport transport = null
    ) {
        // The public programming interface owns the full lifecycle: build,
        // compile, submit, hydrate, and verify. Callers should not have to
        // manually construct CNF or HTTP payloads.
        if (options.compilation.engine == "auto") {
            return solveAuto(input, options, transport);
        }

        auto compiled = compile(input, options.compilation);
        auto request = options.request;
        if (request.apiKey.length == 0) {
            request.apiKey = environment.get("NAVOKOJ_API_KEY", "");
        }
        return new NavokojClient(transport).solve(compiled, request);
    }

    /**
     * Build → compile → fetch capabilities → route → solve. The full auto-
     * routing pipeline: the router decides engine + endpoint using live
     * account limits, then the client transmits the request.
     *
     * Capabilities are fetched fresh per call (no TTL cache) so account
     * upgrades or credit exhaustion are reflected immediately. The fetch is
     * the second network round-trip; if it fails the exception bubbles up
     * and no solve request is sent.
     *
     * If the router refuses (model exceeds account envelope) a
     * CapabilityException is raised with the rationale — the client never
     * transmits a request it knows will be rejected.
     */
    SolveResult solveAuto(
        JSONValue input,
        AppSolveOptions options = AppSolveOptions(),
        HttpTransport transport = null
    ) {
        auto compiled = compile(input, options.compilation);
        auto topology = analyzeCompiled(compiled);

        auto request = options.request;
        if (request.apiKey.length == 0) {
            request.apiKey = environment.get("NAVOKOJ_API_KEY", "");
        }

        // Fresh-per-solve capabilities fetch — no TTL cache.
        auto backend = new NavokojBackend(
            new NavokojClient(transport),
            request.apiKey,
            request.baseUrl
        );
        Capabilities caps = backend.capabilities(request);

        // applyAccountLimits in router.d handles both refusal and downgrade.
        auto recommendation = recommendRoute(topology, options.compilation, caps);

        return new NavokojClient(transport).solve(compiled, request, recommendation);
    }

    /**
     * Probe the backend's live capability envelope and return the parsed
     * JSON. Uses the same transport as `solve` so tests can intercept it
     * via a FakeTransport.
     */
    JSONValue capabilities(
        AppSolveOptions options = AppSolveOptions(),
        HttpTransport transport = null
    ) {
        auto request = options.request;
        if (request.apiKey.length == 0) {
            request.apiKey = environment.get("NAVOKOJ_API_KEY", "");
        }
        auto backend = new NavokojBackend(
            new NavokojClient(transport),
            request.apiKey,
            request.baseUrl
        );
        Capabilities caps = backend.capabilities(request);
        return caps.toJson();
    }

    JSONValue diagnose(
        JSONValue input,
        AppSolveOptions options = AppSolveOptions(),
        HttpTransport transport = null
    ) {
        options.compilation.preferQState = false;
        options.compilation.preferNativeParity = false;
        options.compilation.diagnosticOnly = true;
        auto compiled = compile(input, options.compilation);
        auto request = options.request;
        if (request.apiKey.length == 0) {
            request.apiKey = environment.get("NAVOKOJ_API_KEY", "");
        }

        JSONValue[string] output;
        output["compilation"] = compiled.summary();
        output["diagnostic"] =
            new NavokojClient(transport).diagnose(compiled, request);
        return JSONValue(output);
    }

    JSONValue present(JSONValue input, SolveResult result) {
        auto envelope = result.toJson();
        if (
            presenter !is null &&
            result.solution !is null
        ) {
            envelope.object["domain_output"] =
                presenter(input, result.solution);
        }
        return envelope;
    }

    /**
     * Run this application through the standard validate/compile/diagnose/
     * solve lifecycle. This is the programming-interface entry point: the
     * application owns model construction and presentation while the runner
     * owns compilation, request submission, hydration, and verification.
     */
    int run(string[] args, HttpTransport transport = null) {
        return runNavokojApp(this, args, transport);
    }
}

NavokojApp decisionApp(
    string name,
    ModelBuilder builder,
    SolutionPresenter presenter = null
) {
    return new NavokojApp(name, builder, presenter);
}

/**
 * Convenience overload for applications whose model is fully defined in D
 * code and does not need a per-request JSON input document.
 */
NavokojApp decisionApp(
    string name,
    StaticModelBuilder builder,
    SolutionPresenter presenter = null
) {
    if (builder is null) {
        throw new ModelException("Application model builder cannot be null");
    }
    return new NavokojApp(
        name,
        (Model model, JSONValue input) {
            builder(model);
        },
        presenter
    );
}

/**
 * Run an application with the common navokoj-app CLI lifecycle.
 *
 * Supported commands:
 *   validate  Build and validate without producing a wire request.
 *   compile   Compile and print the exact wire request plus diagnostics.
 *   diagnose  Compile to CNF and call the DEFEKT diagnostic endpoint.
 *   solve     Compile, call the API, hydrate, verify, and print the result.
 */
int runNavokojApp(
    NavokojApp app,
    string[] args,
    HttpTransport transport = null
) {
    try {
        auto cli = parseCli(args);
        if (cli.help) {
            stdout.write(navokojAppUsage());
            return 0;
        }

        const inputText = cli.inputPath.length == 0
            ? readAllStdin()
            : readText(cli.inputPath);
        const input = parseAppInput(
            inputText,
            cli.inputFormat
        );

        CompileOptions compileOptions;
        compileOptions.engine = cli.engine;
        compileOptions.hardware = cli.hardware;
        compileOptions.timeoutBudgetSeconds = cli.timeoutSeconds;
        compileOptions.minSatisfaction = cli.minSatisfaction;
        compileOptions.minWeightedSatisfaction =
            cli.minWeightedSatisfaction;
        compileOptions.maxBddNodesPerConstraint = cli.maxBddNodes;

        JSONValue output;
        switch (cli.command) {
            case "validate":
                auto model = app.build(input);
                validateModel(model, compileOptions);
                JSONValue[string] validation;
                validation["valid"] = JSONValue(true);
                validation["application"] = JSONValue(app.name);
                validation["variables"] =
                    JSONValue(cast(long) model.variables.length);
                const symbolicCount = model.constraints.length;
                const clauseCount = model.nativeClauses.length;
                const parityCount = model.parityConstraints.length;
                validation["symbolic_constraints"] =
                    JSONValue(cast(long) symbolicCount);
                validation["clauses"] =
                    JSONValue(cast(long) clauseCount);
                validation["parity_constraints"] =
                    JSONValue(cast(long) parityCount);
                validation["constraints"] = JSONValue(cast(long) (
                    symbolicCount + clauseCount + parityCount
                ));
                validation["objectives"] =
                    JSONValue(cast(long) model.objectives.length);
                output = JSONValue(validation);
                break;

            case "compile":
                auto compiled = app.compile(input, compileOptions);
                JSONValue[string] compilation;
                compilation["summary"] = compiled.summary();
                compilation["request"] = compiled.request;
                output = JSONValue(compilation);
                break;

            case "analyze":
                auto model = app.build(input);
                validateModel(model, compileOptions);
                auto topology = analyzeModel(model);
                auto recommendation = recommendRoute(topology, compileOptions);
                JSONValue[string] analysis;
                analysis["valid"] = JSONValue(true);
                analysis["application"] = JSONValue(app.name);
                analysis["topology"] = topology.toJson();
                analysis["recommendation"] = recommendation.toJson();
                output = JSONValue(analysis);
                break;

            case "solve":
                AppSolveOptions solveOptions;
                solveOptions.compilation = compileOptions;
                solveOptions.request.apiKey = cli.apiKey;
                solveOptions.request.baseUrl = cli.baseUrl;
                solveOptions.request.transportTimeout =
                    dur!"seconds"(cli.transportTimeoutSeconds);
                auto solved = app.solve(input, solveOptions, transport);
                output = app.present(input, solved);
                break;

            case "diagnose":
                AppSolveOptions diagnoseOptions;
                diagnoseOptions.compilation = compileOptions;
                diagnoseOptions.compilation.preferQState = false;
                diagnoseOptions.compilation.preferNativeParity = false;
                diagnoseOptions.compilation.diagnosticOnly = true;
                diagnoseOptions.request.apiKey = cli.apiKey;
                diagnoseOptions.request.baseUrl = cli.baseUrl;
                diagnoseOptions.request.transportTimeout =
                    dur!"seconds"(cli.transportTimeoutSeconds);
                output = app.diagnose(input, diagnoseOptions, transport);
                break;

            case "capabilities":
                AppSolveOptions capabilitiesOptions;
                capabilitiesOptions.request.apiKey = cli.apiKey;
                capabilitiesOptions.request.baseUrl = cli.baseUrl;
                capabilitiesOptions.request.transportTimeout =
                    dur!"seconds"(cli.transportTimeoutSeconds);
                output = app.capabilities(capabilitiesOptions, transport);
                break;

            default:
                throw new ModelException(
                    "Unknown command '" ~ cli.command ~ "'"
                );
        }

        writeOutput(cli.outputPath, output.toPrettyString());
        return 0;
    } catch (NavokojException error) {
        JSONValue[string] failure;
        failure["success"] = JSONValue(false);
        failure["error"] = JSONValue(error.classinfo.name);
        failure["message"] = JSONValue(error.msg);

        auto apiError = cast(ApiException) error;
        if (apiError !is null) {
            failure["status_code"] =
                JSONValue(cast(long) apiError.statusCode);
            failure["request_id"] = JSONValue(apiError.requestId);
            failure["retry_after"] =
                JSONValue(apiError.retryAfterSeconds);
            failure["delivery_state"] =
                JSONValue(apiError.deliveryState.to!string);
            if (apiError.rawBody.length != 0) {
                failure["raw_body"] = JSONValue(apiError.rawBody);
            }
        }

        stderr.writeln(JSONValue(failure).toPrettyString());
        return 1;
    } catch (Exception error) {
        JSONValue[string] failure;
        failure["success"] = JSONValue(false);
        failure["error"] = JSONValue(error.classinfo.name);
        failure["message"] = JSONValue(error.msg);
        stderr.writeln(JSONValue(failure).toPrettyString());
        return 1;
    }
}

string navokojAppUsage() {
    return
        "reify <validate|compile|analyze|diagnose|solve|capabilities> [options]\n\n" ~
        "Options:\n" ~
        "  --input <file>             Read JSON, DIMACS, or OPB (default: stdin)\n" ~
        "  --format <auto|json|dimacs|opb> Input format (default: auto)\n" ~
        "  --output <file>            Write output JSON to a file (default: stdout)\n" ~
        "  --api-key <token>          API key (default: NAVOKOJ_API_KEY)\n" ~
        "  --base-url <url>           API base URL\n" ~
        "  --engine <name>            Solver engine (default: auto — router picks)\n" ~
        "  --hardware <name>          Optional hardware target\n" ~
        "  --timeout <seconds>        Solver timeout budget\n" ~
        "  --min-satisfaction <0..1>  Stop after this clause satisfaction\n" ~
        "  --min-weighted-satisfaction <0..1> Weighted stop threshold\n" ~
        "  --transport-timeout <sec>  HTTP operation timeout (default: 60)\n" ~
        "  --max-bdd-nodes <count>     Linear-constraint compiler limit\n" ~
        "  --pretty                   Render formatted human-readable summary output\n" ~
        "  --help                     Show this help\n";
}

private struct CliOptions {
    string command;
    string inputPath;
    string inputFormat = "auto";
    string outputPath;
    string apiKey;
    string baseUrl = defaultBaseUrl;
    string engine = "auto";
    string hardware;
    double timeoutSeconds = 0.0;
    double minSatisfaction = -1.0;
    double minWeightedSatisfaction = -1.0;
    long transportTimeoutSeconds = 60;
    size_t maxBddNodes = 500_000;
    bool pretty;
    bool help;
}

private CliOptions parseCli(string[] args) {
    CliOptions options;
    if (args.length < 2) {
        options.help = true;
        return options;
    }

    options.command = args[1];
    if (options.command == "--help" || options.command == "-h") {
        options.help = true;
        return options;
    }

    size_t index = 2;
    while (index < args.length) {
        const argument = args[index];
        if (argument == "--help" || argument == "-h") {
            options.help = true;
            ++index;
            continue;
        }
        if (argument == "--pretty") {
            options.pretty = true;
            ++index;
            continue;
        }
        if (index + 1 >= args.length) {
            throw new ModelException(
                "Missing value after CLI option '" ~ argument ~ "'"
            );
        }
        const value = args[index + 1];
        switch (argument) {
            case "--input":
                options.inputPath = value;
                break;
            case "--format":
                options.inputFormat = value.toLower();
                if (
                    options.inputFormat != "auto" &&
                    options.inputFormat != "json" &&
                    options.inputFormat != "dimacs" &&
                    options.inputFormat != "opb"
                ) {
                    throw new ModelException(
                        "--format must be auto, json, dimacs, or opb"
                    );
                }
                break;
            case "--output":
                options.outputPath = value;
                break;
            case "--api-key":
                options.apiKey = value;
                break;
            case "--base-url":
                options.baseUrl = value;
                break;
            case "--engine":
                options.engine = value;
                break;
            case "--hardware":
                options.hardware = value;
                break;
            case "--timeout":
                options.timeoutSeconds = value.to!double;
                break;
            case "--min-satisfaction":
                options.minSatisfaction = value.to!double;
                break;
            case "--min-weighted-satisfaction":
                options.minWeightedSatisfaction = value.to!double;
                break;
            case "--transport-timeout":
                options.transportTimeoutSeconds = value.to!long;
                if (options.transportTimeoutSeconds <= 0) {
                    throw new ModelException(
                        "--transport-timeout must be a positive number of seconds"
                    );
                }
                break;
            case "--max-bdd-nodes":
                options.maxBddNodes = value.to!size_t;
                break;
            default:
                throw new ModelException(
                    "Unknown CLI option '" ~ argument ~ "'"
                );
        }
        index += 2;
    }

    if (!options.help) {
        switch (options.command) {
            case "validate":
            case "compile":
            case "analyze":
            case "diagnose":
            case "solve":
            case "capabilities":
                break;
            default:
                throw new ModelException(
                    "Unknown command '" ~ options.command ~ "'"
                );
        }
    }
    return options;
}

private JSONValue parseAppInput(string content, string requestedFormat) {
    auto format = requestedFormat;
    if (format == "auto") {
        const trimmed = content.strip;
        if (
            trimmed.length != 0 &&
            (trimmed[0] == '{' || trimmed[0] == '[')
        ) {
            format = "json";
        } else if (looksLikeOpb(trimmed)) {
            format = "opb";
        } else {
            format = "dimacs";
        }
    }

    if (format == "json") {
        return parseJSON(content);
    }
    if (format == "dimacs") {
        return dimacsToDocumentJson(content);
    }
    if (format == "opb") {
        return opbToDocumentJson(content);
    }
    throw new ModelException("Unknown input format '" ~ format ~ "'");
}

private bool looksLikeOpb(string trimmed) {
    if (trimmed.length == 0) {
        return false;
    }
    if (
        trimmed[0] == '*' ||
        trimmed[0] == '+' ||
        trimmed[0] == '-' ||
        (trimmed[0] >= '0' && trimmed[0] <= '9')
    ) {
        return true;
    }
    return trimmed.startsWith("min:") ||
        trimmed.startsWith("max:") ||
        trimmed.startsWith("soft:") ||
        trimmed.startsWith("models:") ||
        trimmed.startsWith("count:") ||
        trimmed.startsWith("enum:");
}

private string readAllStdin() {
    import std.array : appender;

    auto content = appender!string();
    foreach (line; stdin.byLineCopy()) {
        content.put(line);
        // `byLineCopy` removes line terminators by default. Preserve record
        // boundaries so DIMACS/OPB headers, comments, and clauses do not get
        // concatenated when navokoj-app is used in a generator pipeline.
        content.put('\n');
    }
    return content.data;
}

private void writeOutput(string path, string content) {
    if (path.length == 0) {
        stdout.writeln(content);
    } else {
        write(path, content);
    }
}