// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

/**
 * Local command-line solver adapters.
 *
 * The adapters intentionally share one conservative parser for the standard
 * SAT/MaxSAT text protocol (`s`, `v`, and `o` lines). They stage a DIMACS or
 * WCNF artifact only after checking free disk space, and the public fallback
 * helper retries the next configured backend when staging or process startup
 * fails.
 */
module reify.local.backend;

import reify.backend : BackendOptions, BackendResponse, SolverBackend;
import reify.compiler : CompiledModel;
import reify.errors :
    BackendException,
    CapabilityException,
    DiskSpaceException;
import reify.result : SolveResult, buildSolveResult;

import std.algorithm : canFind;
import std.array : appender, join;
import std.conv : to;
import std.file :
    FileException,
    exists,
    getAvailableDiskSpace,
    readText,
    remove,
    tempDir,
    write;
import std.format : format;
import std.json : JSONValue;
import std.math : ceil;
import std.path : buildPath;
import std.process :
    Config,
    environment,
    executeProcess = execute,
    thisProcessID;
import std.string :
    split,
    startsWith,
    strip,
    toLower;
import std.datetime.systime : Clock;

private enum ArtifactKind { dimacs, wcnf }

private string canonicalBackend(string id) {
    const lower = id.toLower;
    switch (lower) {
        case "open-wbo": return "openwbo";
        case "max-hs": return "maxhs";
        case "uwr-maxsat": return "uwrmaxsat";
        case "w-max-cdcl": return "wmaxcdcl";
        case "max-cdcl": return "maxcdcl";
        case "eval-maxsat": return "evalmaxsat";
        case "crypto-minisat":
        case "cryptominisat5":
            return "cryptominisat";
        case "ca-di-caal": return "cadical";
        default: return lower;
    }
}

private bool isWeightedBackend(string id) {
    return id == "openwbo" || id == "loandra" || id == "maxhs" ||
        id == "rc2" || id == "uwrmaxsat" || id == "pacose" ||
        id == "wmaxcdcl" || id == "maxcdcl" || id == "evalmaxsat";
}

private bool isKnownBackend(string id) {
    return isWeightedBackend(id) || id == "kissat" || id == "glucose" ||
        id == "minisat" || id == "cadical" || id == "cryptominisat";
}

private string defaultExecutable(string id) {
    switch (id) {
        case "openwbo": return "open-wbo";
        case "loandra": return "loandra";
        case "maxhs": return "maxhs";
        case "rc2": return "rc2";
        case "uwrmaxsat": return "uwrmaxsat";
        case "pacose": return "pacose";
        case "wmaxcdcl": return "wmaxcdcl";
        case "maxcdcl": return "maxcdcl";
        case "evalmaxsat": return "evalmaxsat";
        case "cryptominisat": return "cryptominisat5";
        default: return id;
    }
}

private string environmentKey(string id) {
    string result = "REIFY_";
    foreach (ch; id) {
        if (ch >= 'a' && ch <= 'z') result ~= cast(char) (ch - 'a' + 'A');
        else result ~= ch;
    }
    return result ~ "_PATH";
}

private ulong safeAdd(ulong left, ulong right, string context) {
    if (ulong.max - left < right) {
        throw new CapabilityException(context ~ " size overflow");
    }
    return left + right;
}

private ulong safeMul(ulong left, ulong right, string context) {
    if (right != 0 && left > ulong.max / right) {
        throw new CapabilityException(context ~ " size overflow");
    }
    return left * right;
}

private ulong clauseWeight(double weight) {
    if (weight <= 0.0 || weight != weight) {
        throw new CapabilityException("WCNF clause weight must be positive");
    }
    return cast(ulong) ceil(weight);
}

private ulong hardWeight(CompiledModel compiled) {
    ulong softTotal;
    foreach (clause; compiled.clauses) {
        if (clause.level.to!string == "hard") continue;
        softTotal = safeAdd(softTotal, clauseWeight(clause.weight), "WCNF weight");
    }
    return safeAdd(softTotal, 1, "WCNF top weight");
}

private string renderArtifact(CompiledModel compiled, ArtifactKind kind) {
    const weighted = kind == ArtifactKind.wcnf;
    if (!weighted) {
        foreach (clause; compiled.clauses) {
            if (clause.level.to!string != "hard") {
                throw new CapabilityException(
                    "Selected SAT backend cannot preserve soft constraints; choose a MaxSAT backend"
                );
            }
        }
    }

    auto output = appender!string();
    const top = weighted ? hardWeight(compiled) : 0;
    output.put(weighted ? "p wcnf " : "p cnf ");
    output.put(compiled.generatedVariableCount.to!string);
    output.put(" ");
    output.put(compiled.clauses.length.to!string);
    if (weighted) {
        output.put(" ");
        output.put(top.to!string);
    }
    output.put("\n");

    foreach (clause; compiled.clauses) {
        if (weighted) {
            const weight = clause.level.to!string == "hard"
                ? top
                : clauseWeight(clause.weight);
            output.put(weight.to!string);
            output.put(" ");
        }
        foreach (literal; clause.literals) {
            output.put(literal.to!string);
            output.put(" ");
        }
        output.put("0\n");
    }
    return output.data;
}

private ulong estimateArtifactBytes(CompiledModel compiled, ArtifactKind kind) {
    // Eleven bytes covers a signed 32-bit literal plus a separator. The
    // estimate deliberately over-allocates so a nearly-full filesystem fails
    // before staging begins.
    ulong bytes = 128;
    foreach (clause; compiled.clauses) {
        bytes = safeAdd(bytes, 16, "solver artifact");
        bytes = safeAdd(
            bytes,
            safeMul(cast(ulong) clause.literals.length, 12, "solver artifact"),
            "solver artifact"
        );
        if (kind == ArtifactKind.wcnf) bytes = safeAdd(bytes, 24, "solver artifact");
    }
    return bytes;
}

private bool parseLiteral(string token, ref bool[] assignment) {
    if (token.length == 0 || token == "0") return false;
    long literal;
    try {
        literal = token.to!long;
    } catch (Exception) {
        return false;
    }
    if (literal == 0) return false;
    const magnitude = literal < 0 ? -literal : literal;
    if (magnitude > assignment.length) {
        throw new BackendException(format(
            "Solver returned literal %s outside the compiled variable range %s",
            literal,
            assignment.length
        ));
    }
    assignment[magnitude - 1] = literal > 0;
    return true;
}

private bool parseBareAssignmentLine(string line, ref bool[] assignment) {
    auto tokens = line.split(" ");
    if (tokens.length < 2) return false;
    bool parsed;
    foreach (token; tokens) {
        if (token.length == 0) continue;
        if (token == "0") return parsed;
        if (!parseLiteral(token, assignment)) return false;
        parsed = true;
    }
    return false;
}

private JSONValue parseSolverOutput(
    string backend,
    CompiledModel compiled,
    string output,
    int exitStatus
) {
    bool[] assignment = new bool[](compiled.generatedVariableCount);
    bool hasAssignment;
    bool hasSatisfiable;
    bool satisfiable;
    bool timeout;
    bool optimum;
    bool hasObjective;
    long objectiveCost;

    foreach (rawLine; output.split("\n")) {
        const line = rawLine.strip;
        if (line.length == 0) continue;
        const lower = line.toLower;
        if (
            lower.startsWith("s ") ||
            lower == "sat" ||
            lower == "unsat" ||
            lower == "satisfiable" ||
            lower == "unsatisfiable"
        ) {
            if (lower.canFind("unsat")) {
                hasSatisfiable = true;
                satisfiable = false;
            } else if (lower.canFind("unknown")) {
                timeout = true;
            } else {
                hasSatisfiable = true;
                satisfiable = true;
                if (lower.canFind("optimum")) optimum = true;
            }
            continue;
        }
        if (line.startsWith("v ") || line.startsWith("V ")) {
            foreach (token; line[1 .. $].strip.split(" ")) {
                if (parseLiteral(token, assignment)) hasAssignment = true;
            }
            continue;
        }
        if (parseBareAssignmentLine(line, assignment)) {
            hasAssignment = true;
            continue;
        }
        if (line.startsWith("o ") || line.startsWith("O ")) {
            auto tokens = line[1 .. $].strip.split(" ");
            if (tokens.length > 0) {
                try {
                    objectiveCost = tokens[0].to!long;
                    hasObjective = true;
                } catch (Exception) { }
            }
        }
    }

    if (exitStatus != 0 && !hasSatisfiable && !hasAssignment) {
        throw new BackendException(format(
            "Local backend '%s' exited with status %s",
            backend,
            exitStatus
        ));
    }
    if (!hasSatisfiable && hasAssignment) {
        hasSatisfiable = true;
        satisfiable = true;
    }

    JSONValue[string] response;
    response["backend"] = JSONValue(backend);
    response["success"] = JSONValue(hasAssignment || (hasSatisfiable && satisfiable));
    if (hasSatisfiable) response["satisfiable"] = JSONValue(satisfiable);
    response["timeout_budget_hit"] = JSONValue(timeout);
    response["solved"] = JSONValue(optimum || (hasAssignment && !timeout));
    response["optimal"] = JSONValue(optimum);
    if (hasObjective) response["objective_cost"] = JSONValue(objectiveCost);

    if (hasAssignment) {
        JSONValue[] values;
        foreach (value; assignment) values ~= JSONValue(value);
        response["assignment"] = JSONValue(values);
    }
    return JSONValue(response);
}

/** One command-line solver adapter for DIMACS or WCNF. */
final class CommandSolverBackend : SolverBackend {
    private string backendId;
    private string configuredExecutable;
    private ArtifactKind artifactKind;

    this(string id, string executable = "") {
        backendId = canonicalBackend(id);
        configuredExecutable = executable;
        artifactKind = isWeightedBackend(backendId)
            ? ArtifactKind.wcnf
            : ArtifactKind.dimacs;
    }

    override string id() const { return backendId; }

    override BackendResponse execute(
        CompiledModel compiled,
        BackendOptions options
    ) {
        const root = options.tempDirectory.length != 0 ? options.tempDirectory : tempDir();
        if (!exists(root)) {
            throw new BackendException("Local solver temp directory does not exist: " ~ root);
        }

        const estimate = estimateArtifactBytes(compiled, artifactKind);
        ulong required = safeAdd(estimate, options.diskReserveBytes, "solver staging");
        // MiniSat's conventional CLI writes the assignment to a second
        // result file. Include that file in the preflight as well.
        if (backendId == "minisat") {
            const variables = cast(ulong) compiled.generatedVariableCount;
            if (variables > (ulong.max - 64) / 12) {
                throw new CapabilityException("MiniSat result size overflow");
            }
            required = safeAdd(
                required,
                64 + variables * 12,
                "solver result staging"
            );
        }
        const freeBytes = options.availableDiskSpaceOverride != 0
            ? options.availableDiskSpaceOverride
            : getAvailableDiskSpace(root);
        if (freeBytes < required) {
            throw new DiskSpaceException(format(
                "Insufficient disk space for '%s' staging (free=%s, required=%s)",
                backendId,
                freeBytes,
                required
            ));
        }

        // Perform the filesystem preflight before materializing the complete
        // expanded DIMACS/WCNF string. Large encodings should fail over
        // without first consuming another large in-memory buffer.
        const payload = renderArtifact(compiled, artifactKind);

        const extension = artifactKind == ArtifactKind.wcnf ? "wcnf" : "cnf";
        const path = buildPath(root, format(
            "reify-%s-%s-%s.%s",
            backendId,
            thisProcessID,
            Clock.currStdTime,
            extension
        ));
        const outputPath = buildPath(root, format(
            "reify-%s-%s-%s.out",
            backendId,
            thisProcessID,
            Clock.currStdTime
        ));
        scope(exit) if (exists(path)) remove(path);
        scope(exit) if (exists(outputPath)) remove(outputPath);

        try {
            write(path, payload);
        } catch (FileException error) {
            throw new DiskSpaceException(
                "Could not stage local solver artifact: " ~ error.msg
            );
        }

        const program = configuredExecutable.length != 0
            ? configuredExecutable
            : (environment.get(environmentKey(backendId)).length != 0
                ? environment.get(environmentKey(backendId))
                : defaultExecutable(backendId));
        string[] args = [program];
        bool substituted;
        bool outputSubstituted;
        foreach (argument; options.arguments) {
            if (argument == "{input}" || argument == "%INPUT%") {
                args ~= path;
                substituted = true;
            } else if (argument == "{output}" || argument == "%OUTPUT%") {
                args ~= outputPath;
                outputSubstituted = true;
            } else {
                args ~= argument;
            }
        }
        if (!substituted) args ~= path;
        if (backendId == "minisat" && !outputSubstituted) args ~= outputPath;

        string processOutput;
        int processStatus;
        try {
            auto process = executeProcess(
                args,
                null,
                Config.none,
                16 * 1024 * 1024,
                root
            );
            processOutput = process.output;
            processStatus = process.status;
        } catch (Exception error) {
            throw new BackendException(format(
                "Local backend '%s' could not start: %s",
                backendId,
                error.msg
            ));
        }
        if (exists(outputPath)) {
            try {
                const resultOutput = readText(outputPath);
                if (resultOutput.length != 0) {
                    processOutput ~= "\n" ~ resultOutput;
                }
            } catch (FileException error) {
                throw new BackendException(format(
                    "Local backend '%s' produced an unreadable result file: %s",
                    backendId,
                    error.msg
                ));
            }
        }
        auto raw = parseSolverOutput(
            backendId,
            compiled,
            processOutput,
            processStatus
        );
        return BackendResponse(backendId, raw);
    }
}

CommandSolverBackend createLocalBackend(string id, string executable = "") {
    id = canonicalBackend(id);
    if (id.length == 0 || id == "auto" || id == "navokoj") {
        throw new BackendException("A local solver backend must be selected explicitly");
    }
    if (!isKnownBackend(id)) {
        throw new BackendException("Unknown local solver backend '" ~ id ~ "'");
    }
    return new CommandSolverBackend(id, executable);
}

private string[] defaultFallbacks(string backend) {
    if (isWeightedBackend(backend)) return ["openwbo", "maxhs", "rc2"];
    if (backend == "cryptominisat") return ["cryptominisat", "kissat", "cadical"];
    return ["kissat", "cadical", "minisat"];
}

/** Execute a selected local backend, retrying only the declared fallbacks. */
BackendResponse executeLocalWithFallback(
    CompiledModel compiled,
    BackendOptions options,
    string requestedBackend,
    string[] fallbacks = null
) {
    requestedBackend = canonicalBackend(requestedBackend);
    string[] candidates = [requestedBackend];
    candidates ~= fallbacks is null ? defaultFallbacks(requestedBackend) : fallbacks;
    string[] failures;
    string[] attempted;
    bool sawDiskFailure;
    foreach (candidate; candidates) {
        candidate = canonicalBackend(candidate);
        if (candidate.length == 0 || canFind(attempted, candidate)) continue;
        attempted ~= candidate;
        auto attemptOptions = options;
        attemptOptions.backend = candidate;
        try {
            return createLocalBackend(candidate, candidate == requestedBackend ? options.executable : "")
                .execute(compiled, attemptOptions);
        } catch (DiskSpaceException error) {
            sawDiskFailure = true;
            failures ~= candidate ~ ": " ~ error.msg;
        } catch (BackendException error) {
            failures ~= candidate ~ ": " ~ error.msg;
        }
    }
    if (sawDiskFailure) {
        throw new DiskSpaceException(
            "All local solver backends failed during staging: " ~ failures.join("; ")
        );
    }
    throw new BackendException(
        "All local solver backends failed: " ~ failures.join("; ")
    );
}

SolveResult solveLocal(
    CompiledModel compiled,
    BackendOptions options,
    string requestedBackend,
    string[] fallbacks = null
) {
    auto response = executeLocalWithFallback(
        compiled,
        options,
        requestedBackend,
        fallbacks
    );
    return buildSolveResult(compiled, response.raw);
}
