// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

/**
 * First-party `SolverBackend` adapter for Navokoj.
 *
 * Other solver vendors (OR-Tools, Z3, in-process) provide their own
 * `SolverBackend` implementation against the interface in `reify.backend`.
 * Reify ships this one as a reference and an example.
 */

module reify.navokoj.backend;

import reify.backend :
    BackendOptions,
    BackendResponse,
    Capabilities,
    SolverBackend;
import reify.compiler : CompiledModel;
import reify.navokoj.client :
    NavokojClient,
    RequestOptions,
    defaultBaseUrl;

import std.json : JSONValue;

/** First-party adapter. Other solvers implement SolverBackend independently. */
final class NavokojBackend : SolverBackend {
    private NavokojClient client;
    private string apiKey;
    private string baseUrl = defaultBaseUrl;

    this(NavokojClient client = null, string apiKey = "", string baseUrl = defaultBaseUrl) {
        this.client = client is null ? new NavokojClient() : client;
        this.apiKey = apiKey;
        this.baseUrl = baseUrl;
    }

    override string id() const { return "navokoj"; }

    override BackendResponse execute(
        CompiledModel compiled,
        BackendOptions options
    ) {
        RequestOptions request;
        request.apiKey = options.credential.length != 0 ? options.credential : apiKey;
        request.baseUrl = baseUrl;
        request.transportTimeout = options.transportTimeout;
        auto raw = client.solveRaw(compiled, request);
        return BackendResponse(id(), raw);
    }

    Capabilities capabilities(RequestOptions options = RequestOptions()) {
        if (options.apiKey.length == 0) {
            options.apiKey = apiKey;
        }
        if (options.baseUrl == defaultBaseUrl && baseUrl.length != 0) {
            options.baseUrl = baseUrl;
        }
        return client.capabilities(options);
    }
}