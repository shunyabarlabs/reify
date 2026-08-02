// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.backend;

import reify.compiler : CompiledModel;
import reify.result : SolveResult;

import std.datetime : Duration, dur;
import std.json : JSONType, JSONValue;

/** Account capability discovery envelope */
struct Capabilities {
    string[] engines;
    ulong maxVariables;
    ulong maxClauses;
    bool supportsHardClauseMask;
    bool supportsSpaceTime;
    double remainingCredits;

    ulong maxQsatNodes;
    ulong maxQsatStates;
    ulong maxScheduleResources;
    uint concurrentRequests;
    string[] hardwareAccess;
    string tier;
    JSONValue raw;

    /// True when the envelope carries any server-side limits that the router
    /// can act on. Zero means "unknown / no constraint" (not "unlimited").
    /// `hardwareAccess` qualifies: it constrains the hardware choice even
    /// when no explicit size limits are set.
    bool hasAccountLimits() const {
        return maxVariables > 0 || maxClauses > 0 ||
            hardwareAccess.length > 0 || engines.length > 0 ||
            concurrentRequests > 0;
    }

    /// Serialize to JSON for the `reify capabilities` CLI command and for
    /// diagnostic logging. `raw` is merged in last so server-added fields
    /// surface verbatim.
    JSONValue toJson() const {
        JSONValue[string] val;
        val["tier"] = JSONValue(tier);

        JSONValue[] enginesArr;
        foreach (e; engines) enginesArr ~= JSONValue(e);
        val["engines"] = JSONValue(enginesArr);

        JSONValue[] hwArr;
        foreach (h; hardwareAccess) hwArr ~= JSONValue(h);
        val["hardware_access"] = JSONValue(hwArr);

        val["max_variables"] = JSONValue(cast(long) maxVariables);
        val["max_clauses"] = JSONValue(cast(long) maxClauses);
        val["supports_hard_clause_mask"] = JSONValue(supportsHardClauseMask);
        val["supports_space_time"] = JSONValue(supportsSpaceTime);
        val["remaining_credits"] = JSONValue(remainingCredits);
        val["max_qsat_nodes"] = JSONValue(cast(long) maxQsatNodes);
        val["max_qsat_states"] = JSONValue(cast(long) maxQsatStates);
        val["max_schedule_resources"] = JSONValue(cast(long) maxScheduleResources);
        val["concurrent_requests"] = JSONValue(cast(long) concurrentRequests);
        val["has_account_limits"] = JSONValue(hasAccountLimits());

        if (raw.type == JSONType.object) {
            foreach (string k, v; raw.object) {
                if (k !in val) val[k] = v;
            }
        }
        return JSONValue(val);
    }
}

/** Backend-neutral execution settings.
 *
 * `credential` is deliberately opaque: an OR-Tools adapter may ignore it,
 * while a hosted adapter may interpret it as an API key or token.
 */
struct BackendOptions {
    string credential;
    string engine;
    string hardware;
    string backend = "auto";
    string executable;
    string[] arguments;
    string tempDirectory;
    ulong diskReserveBytes = 1_048_576;
    /// Test/diagnostic hook. Zero means query the filesystem normally.
    ulong availableDiskSpaceOverride;
    double timeoutBudgetSeconds;
    Duration transportTimeout = dur!"seconds"(60);
}

/** Raw evidence returned by a solver adapter, before shared hydration and
 * verification. Backends may use completely different wire protocols.
 */
struct BackendResponse {
    string backend;
    JSONValue raw;
}

/** Implement this interface to execute a CompiledModel on another solver. */
interface SolverBackend {
    string id() const;
    BackendResponse execute(
        CompiledModel compiled,
        BackendOptions options
    );
}

/** Convert backend-specific evidence into the shared verified result model. */
interface SolverResponseParser {
    string id() const;
    SolveResult parse(
        CompiledModel compiled,
        BackendResponse response
    );
}
