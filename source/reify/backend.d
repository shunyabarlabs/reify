// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.backend;

import reify.compiler : CompiledModel;
import reify.result : SolveResult;

import std.datetime : Duration, dur;
import std.json : JSONValue;

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