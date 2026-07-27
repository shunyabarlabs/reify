// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

/**
 * Reference Navokoj wire client.
 *
 * Submits a `CompiledModel` to the Navokoj HTTP endpoints
 * (`/v1/solve`, `/v1/diagnose`, `/v1/capabilities`) and returns
 * raw response envelopes. Solver execution semantics live in
 * `reify.navokoj.backend` (the `SolverBackend` adapter) and
 * response decoding lives in `reify.navokoj.response_parser`.
 *
 * This module is one of several possible backend adapters. Treat it
 * as a sample for writing your own.
 */

module reify.navokoj.client;

import reify.transport : HttpResponse, HttpTransport, CurlTransport;
import reify.compiler : Backend, CompiledModel;
import reify.backend : Capabilities;
import reify.errors :
    ApiException,
    CapabilityException,
    ProtocolException,
    RequestDeliveryState;
import reify.model : ConstraintLevel;
import reify.result : SolveResult, buildSolveResult;
import reify.router : RoutingRecommendation;

import std.algorithm : any;
import std.conv : to;
import std.datetime : Duration, dur;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : ceil, isFinite;
import std.string : icmp, startsWith, strip, toLower;

enum defaultBaseUrl = "https://api.navokoj.shunyabar.foo";

struct RequestOptions {
    // Keep credentials and transport settings outside the model document. This
    // prevents accidental key leakage when requests are logged or benchmarked.
    string apiKey;
    string baseUrl = defaultBaseUrl;
    Duration connectTimeout = dur!"seconds"(5);
    Duration transportTimeout = dur!"seconds"(60);
    bool allowInsecureHttp = false;
}

final class NavokojClient {
    private HttpTransport transport;

    this(HttpTransport transport = null) {
        this.transport = transport is null
            ? cast(HttpTransport) new CurlTransport()
            : transport;
    }

    SolveResult solve(
        CompiledModel compiled,
        RequestOptions options,
        RoutingRecommendation recommendation = RoutingRecommendation()
    ) {
        auto raw = solveRaw(compiled, options, recommendation);
        return buildSolveResult(compiled, raw);
    }

    /** Execute the Navokoj wire contract without assuming Navokoj's response
     * schema. This is the seam used by SolverBackend adapters.
     *
     * When `recommendation` is supplied (engine or targetEndpoint set), it
     * overrides the corresponding fields on the compiled request payload and
     * selects the URL path. An empty `targetEndpoint` is the refusal sentinel
     * from `recommendRoute` — the request is *not* transmitted and a
     * CapabilityException is raised instead.
     */
    JSONValue solveRaw(
        CompiledModel compiled,
        RequestOptions options,
        RoutingRecommendation recommendation = RoutingRecommendation()
    ) {
        if (compiled is null) {
            throw new ProtocolException("Cannot submit a null compiled model");
        }
        if (options.apiKey.length == 0) {
            throw localApiException(
                "No API key supplied. Set RequestOptions.apiKey or NAVOKOJ_API_KEY."
            );
        }
        if (recommendation.isRefusal()) {
            throw new CapabilityException(
                "Refusing to send solve request: " ~ recommendation.rationale
            );
        }
        validateRequestOptions(options);
        options = ensureSolveTransportTimeout(compiled, options);

        auto payload = compiled.request;
        string path = "/v1/solve";
        applyRecommendation(payload, recommendation, path);
        return post(path, payload, options);
    }

    JSONValue diagnose(
        CompiledModel compiled,
        RequestOptions options
    ) {
        if (compiled is null) {
            throw new ProtocolException("Cannot diagnose a null compiled model");
        }
        if (compiled.backend != Backend.cnf) {
            throw new CapabilityException(
                "The documented DEFEKT endpoint accepts CNF models only; " ~
                "compile with Q-State and native parity preferences disabled"
            );
        }
        if (
            (
                compiled.model.internalObjectives.length != 0 ||
                compiled.model.internalNativeClauses.any!(
                    clause =>
                        clause.level != ConstraintLevel.hard
                ) ||
                compiled.model.internalConstraints.any!(
                    constraint =>
                        constraint.level != ConstraintLevel.hard
                )
            ) &&
            !compiled.diagnosticProjection
        ) {
            throw new CapabilityException(
                "Diagnosing a weighted solve payload would treat preferences " ~
                "as hard CNF. Compile with diagnosticOnly enabled."
            );
        }

        if (compiled.request.type != JSONType.object) {
            throw new ProtocolException(
                "Compiled CNF diagnostic request must be a JSON object"
            );
        }
        auto solveRequest = compiled.request.object;
        if (("weights" in solveRequest) !is null) {
            throw new CapabilityException(
                "DEFEKT does not accept clause weights. Compile with " ~
                "diagnosticOnly enabled so only hard constraints are projected."
            );
        }
        auto numVars = "num_vars" in solveRequest;
        auto clauses = "clauses" in solveRequest;
        if (numVars is null || clauses is null) {
            throw new ProtocolException(
                "Compiled CNF diagnostic request is missing num_vars or clauses"
            );
        }
        JSONValue[string] request;
        request["num_vars"] = *numVars;
        request["clauses"] = *clauses;
        auto engine = "engine" in solveRequest;
        request["engine"] = engine is null
            ? JSONValue("nitro")
            : *engine;
        return post("/v1/diagnose", JSONValue(request), options);
    }

    Capabilities capabilities(RequestOptions options) {
        JSONValue[string] emptyObj;
        JSONValue emptyPayload = JSONValue(emptyObj);
        auto raw = this.post("/v1/capabilities", emptyPayload, options);
        return parseCapabilitiesResponse(raw);
    }

    private JSONValue post(
        string path,
        JSONValue payload,
        RequestOptions options
    ) {
        if (options.apiKey.length == 0) {
            throw localApiException(
                "No API key supplied. Set RequestOptions.apiKey or NAVOKOJ_API_KEY."
            );
        }
        validateRequestOptions(options);

        const endpoint = normalizedBaseUrl(options.baseUrl) ~ path;
        HttpResponse response;
        try {
            response = transport.postJson(
                endpoint,
                options.apiKey,
                payload.toString(),
                options.connectTimeout,
                options.transportTimeout
            );
        } catch (ApiException error) {
            if (error.deliveryState == RequestDeliveryState.unspecified) {
                error.deliveryState =
                    RequestDeliveryState.acceptanceUnknown;
            }
            throw error;
        } catch (Exception error) {
            auto failure = new ApiException(
                "Navokoj transport failed: " ~ error.msg ~
                ". Request acceptance is unknown; do not retry automatically " ~
                "without an idempotency guarantee."
            );
            failure.deliveryState =
                RequestDeliveryState.acceptanceUnknown;
            throw failure;
        }

        JSONValue raw;
        try {
            raw = parseJSON(response.body);
        } catch (Exception error) {
            if (response.statusCode < 200 || response.statusCode >= 300) {
                auto failure = new ApiException(
                    "Navokoj API request failed with non-JSON response: " ~
                        error.msg,
                    response.statusCode,
                    responseHeader(response, "x-request-id"),
                    retryAfterFromHeaders(response),
                    response.body
                );
                failure.deliveryState =
                    RequestDeliveryState.responseReceived;
                throw failure;
            }
            throw new ProtocolException(
                "Navokoj returned non-JSON content with HTTP status " ~
                response.statusCode.to!string ~ ": " ~ error.msg
            );
        }

        if (response.statusCode < 200 || response.statusCode >= 300) {
            throw apiError(response, raw);
        }
        if (raw.type == JSONType.object) {
            auto object = raw.object;
            if (
                "success" in object &&
                (
                    object["success"].type == JSONType.false_ ||
                    (
                        object["success"].type == JSONType.integer &&
                        object["success"].integer == 0
                    ) ||
                    (
                        object["success"].type == JSONType.uinteger &&
                        object["success"].uinteger == 0
                    )
                ) && !isPartialSolveResponse(raw)
            ) {
                throw apiError(response, raw);
            }

            propagateRequestId(raw, response);
        }
        return raw;
    }

    /**
     * The solve API may return HTTP 200 with success=false when it ran out of
     * budget but still has a best-effort assignment. Preserve that assignment
     * for local hydration and verification; ordinary failure envelopes remain
     * errors.
     */
    private bool isPartialSolveResponse(JSONValue raw) {
        if (raw.type != JSONType.object) return false;
        auto root = raw.object;
        auto solution = "solution" in root;
        if (solution is null || solution.type != JSONType.object) return false;
        auto assignment = "assignment" in solution.object;
        if (assignment is null) return false;

        auto status = "status" in solution.object;
        if (status !is null && status.type == JSONType.string &&
            status.str == "partial") return true;
        auto solved = "solved" in solution.object;
        if (solved !is null && solved.type == JSONType.false_) return true;
        auto termination = "termination_reason" in solution.object;
        return termination !is null && termination.type == JSONType.string &&
            termination.str == "partial";
    }

    /**
     * Apply a routing recommendation to the outgoing solve request. Mutates
     * `payload` in place and updates `path`. No-op when the recommendation
     * has neither engine nor targetEndpoint set (caller passed a default).
     */
    private void applyRecommendation(
        ref JSONValue payload,
        const ref RoutingRecommendation recommendation,
        ref string path
    ) {
        if (payload.type != JSONType.object) return;
        if (recommendation.engine.length > 0) {
            payload.object["engine"] = JSONValue(recommendation.engine);
        }
        if (recommendation.hardware.length > 0) {
            payload.object["hardware"] = JSONValue(recommendation.hardware);
        }
        if (recommendation.targetEndpoint.length > 0) {
            path = recommendation.targetEndpoint;
        }
    }

    private ApiException apiError(HttpResponse response, JSONValue raw) {
        string message = "Navokoj API request failed";
        string requestId;
        long retryAfter;
        bool hasRetryAfter;

        if (raw.type == JSONType.object) {
            auto object = raw.object;
            if (
                "error" in object &&
                object["error"].type == JSONType.string
            ) {
                message ~= ": " ~ object["error"].str;
            }
            if (
                "message" in object &&
                object["message"].type == JSONType.string
            ) {
                message ~= " (" ~ object["message"].str ~ ")";
            }
            if (
                "request_id" in object &&
                object["request_id"].type == JSONType.string
            ) {
                requestId = object["request_id"].str;
            }
            if (
                "retry_after" in object &&
                (
                    object["retry_after"].type == JSONType.integer ||
                    object["retry_after"].type == JSONType.uinteger
                )
            ) {
                if (object["retry_after"].type == JSONType.integer) {
                    if (object["retry_after"].integer >= 0) {
                        retryAfter = object["retry_after"].integer;
                        hasRetryAfter = true;
                    }
                } else if (object["retry_after"].uinteger <= long.max) {
                    retryAfter = cast(long) object["retry_after"].uinteger;
                    hasRetryAfter = true;
                }
            }
        }

        if (requestId.length == 0) {
            requestId = responseHeader(response, "x-request-id");
        }
        if (!hasRetryAfter) {
            retryAfter = retryAfterFromHeaders(response);
        }

        auto failure = new ApiException(
            message,
            response.statusCode,
            requestId,
            retryAfter,
            response.body.length == 0 ? raw.toString() : response.body
        );
        failure.deliveryState = RequestDeliveryState.responseReceived;
        return failure;
    }
}

private Capabilities parseCapabilitiesResponse(JSONValue raw) {
    Capabilities caps;
    caps.raw = raw;
    if (raw.type != JSONType.object) {
        return caps;
    }

    auto root = raw.object;

    auto enginesVal = "engines" in root;
    if (enginesVal !is null && enginesVal.type == JSONType.array) {
        foreach (item; enginesVal.array) {
            if (item.type == JSONType.string) {
                caps.engines ~= item.str;
            }
        }
    }

    auto maxVars = "maxVariables" in root;
    if (maxVars is null) maxVars = "max_variables" in root;
    if (maxVars !is null) {
        if (maxVars.type == JSONType.integer && maxVars.integer >= 0) {
            caps.maxVariables = maxVars.integer;
        } else if (maxVars.type == JSONType.uinteger) {
            caps.maxVariables = maxVars.uinteger;
        }
    }

    auto maxClauses = "maxClauses" in root;
    if (maxClauses is null) maxClauses = "max_clauses" in root;
    if (maxClauses !is null) {
        if (maxClauses.type == JSONType.integer && maxClauses.integer >= 0) {
            caps.maxClauses = maxClauses.integer;
        } else if (maxClauses.type == JSONType.uinteger) {
            caps.maxClauses = maxClauses.uinteger;
        }
    }

    auto hardMask = "supportsHardClauseMask" in root;
    if (hardMask is null) hardMask = "supports_hard_clause_mask" in root;
    if (hardMask !is null && (hardMask.type == JSONType.true_ || hardMask.type == JSONType.false_)) {
        caps.supportsHardClauseMask = hardMask.type == JSONType.true_;
    } else {
        caps.supportsHardClauseMask = true;
    }

    auto spaceTime = "supportsSpaceTime" in root;
    if (spaceTime is null) spaceTime = "supports_space_time" in root;
    if (spaceTime !is null && (spaceTime.type == JSONType.true_ || spaceTime.type == JSONType.false_)) {
        caps.supportsSpaceTime = spaceTime.type == JSONType.true_;
    } else {
        caps.supportsSpaceTime = true;
    }

    auto credits = "remainingCredits" in root;
    if (credits is null) credits = "remaining_credits" in root;
    if (credits !is null) {
        if (credits.type == JSONType.float_) {
            caps.remainingCredits = credits.floating;
        } else if (credits.type == JSONType.integer) {
            caps.remainingCredits = cast(double) credits.integer;
        } else if (credits.type == JSONType.uinteger) {
            caps.remainingCredits = cast(double) credits.uinteger;
        }
    }

    auto tier = "tier" in root;
    if (tier !is null && tier.type == JSONType.string) {
        caps.tier = tier.str;
    }

    auto hwAccess = "hardwareAccess" in root;
    if (hwAccess is null) hwAccess = "hardware_access" in root;
    if (hwAccess !is null && hwAccess.type == JSONType.array) {
        foreach (item; hwAccess.array) {
            if (item.type == JSONType.string) {
                caps.hardwareAccess ~= item.str;
            }
        }
    }

    return caps;
}

private string normalizedBaseUrl(string value) {
    if (value.length == 0) {
        return defaultBaseUrl;
    }

    size_t end = value.length;
    while (end > 0 && value[end - 1] == '/') {
        --end;
    }
    return value[0 .. end];
}

private ApiException localApiException(string message) {
    auto failure = new ApiException(message);
    failure.deliveryState = RequestDeliveryState.notSent;
    return failure;
}

private void validateRequestOptions(RequestOptions options) {
    validateBaseUrl(options);
    if (options.connectTimeout.total!"msecs" <= 0) {
        throw localApiException("HTTP connect timeout must be positive");
    }
    if (options.transportTimeout.total!"msecs" <= 0) {
        throw localApiException("HTTP transport timeout must be positive");
    }
}

private void validateBaseUrl(RequestOptions options) {
    const baseUrl = normalizedBaseUrl(options.baseUrl);
    const lowered = baseUrl.toLower();
    if (lowered.startsWith("https://")) {
        return;
    }
    if (
        options.allowInsecureHttp &&
        lowered.startsWith("http://") &&
        isLoopbackHttpUrl(lowered)
    ) {
        return;
    }
    throw localApiException(
        "Refusing to send a Bearer token to a non-HTTPS base URL. " ~
        "Set allowInsecureHttp only for localhost, 127.0.0.1, or [::1]."
    );
}

private bool isLoopbackHttpUrl(string loweredUrl) {
    enum prefix = "http://";
    if (!loweredUrl.startsWith(prefix)) {
        return false;
    }

    auto remainder = loweredUrl[prefix.length .. $];
    size_t authorityEnd = remainder.length;
    foreach (index, character; remainder) {
        if (character == '/' || character == '?' || character == '#') {
            authorityEnd = index;
            break;
        }
    }

    const authority = remainder[0 .. authorityEnd];
    if (authority.length == 0) {
        return false;
    }
    foreach (character; authority) {
        if (character == '@') {
            return false;
        }
    }

    string host;
    if (authority[0] == '[') {
        size_t closingBracket = authority.length;
        foreach (index, character; authority) {
            if (character == ']') {
                closingBracket = index;
                break;
            }
        }
        if (closingBracket == authority.length) {
            return false;
        }
        host = authority[0 .. closingBracket + 1];
        const suffix = authority[closingBracket + 1 .. $];
        if (suffix.length != 0 && suffix[0] != ':') {
            return false;
        }
    } else {
        size_t colon = authority.length;
        foreach (index, character; authority) {
            if (character == ':') {
                colon = index;
                break;
            }
        }
        host = authority[0 .. colon];
    }

    return host == "localhost" ||
        host == "127.0.0.1" ||
        host == "[::1]";
}

private RequestOptions ensureSolveTransportTimeout(
    CompiledModel compiled,
    RequestOptions options
) {
    if (
        compiled.request.type != JSONType.object ||
        ("timeout_budget_seconds" in compiled.request.object) is null
    ) {
        return options;
    }

    auto value = compiled.request.object["timeout_budget_seconds"];
    double budget;
    if (value.type == JSONType.float_) {
        budget = value.floating;
    } else if (value.type == JSONType.integer) {
        budget = cast(double) value.integer;
    } else if (value.type == JSONType.uinteger) {
        budget = cast(double) value.uinteger;
    } else {
        throw new ProtocolException(
            "Compiled timeout_budget_seconds must be numeric"
        );
    }

    if (!budget.isFinite || budget < 0.0) {
        throw new ProtocolException(
            "Compiled timeout_budget_seconds must be finite and non-negative"
        );
    }

    const connectMillis = options.connectTimeout.total!"msecs";
    enum responseGraceSeconds = 5.0;
    const requiredSeconds =
        budget +
        cast(double) connectMillis / 1000.0 +
        responseGraceSeconds;
    const maximumSafeSeconds = cast(double) (long.max / 1000);
    if (
        !requiredSeconds.isFinite ||
        requiredSeconds > maximumSafeSeconds
    ) {
        throw localApiException(
            "Solver timeout budget is too large for the HTTP transport"
        );
    }

    const required = dur!"seconds"(cast(long) ceil(requiredSeconds));
    if (options.transportTimeout < required) {
        options.transportTimeout = required;
    }
    return options;
}

private string responseHeader(HttpResponse response, string requestedName) {
    foreach (name, value; response.headers) {
        if (icmp(name, requestedName) == 0) {
            return value.strip;
        }
    }
    return "";
}

private long retryAfterFromHeaders(HttpResponse response) {
    const value = responseHeader(response, "retry-after");
    if (value.length == 0) {
        return 0;
    }

    long seconds;
    foreach (character; value) {
        if (character < '0' || character > '9') {
            // HTTP-date Retry-After values are deliberately not guessed. The
            // integer form is the one documented by Navokoj.
            return 0;
        }
        const digit = cast(long) character - cast(long) '0';
        if (seconds > (long.max - digit) / 10) {
            return 0;
        }
        seconds = seconds * 10 + digit;
    }
    return seconds;
}

private void propagateRequestId(ref JSONValue raw, HttpResponse response) {
    if (raw.type != JSONType.object) {
        return;
    }

    auto root = raw.object;
    auto topLevel = "request_id" in root;
    if (topLevel !is null) {
        if (
            topLevel.type != JSONType.string ||
            topLevel.str.length != 0
        ) {
            return;
        }
    }

    string nestedRequestId;
    auto solution = "solution" in root;
    if (solution !is null && solution.type == JSONType.object) {
        auto nested = "request_id" in solution.object;
        if (
            nested !is null &&
            nested.type == JSONType.string &&
            nested.str.length != 0
        ) {
            nestedRequestId = nested.str;
        }
    }

    const requestId = nestedRequestId.length != 0
        ? nestedRequestId
        : responseHeader(response, "x-request-id");
    if (requestId.length != 0) {
        raw.object["request_id"] = JSONValue(requestId);
    }
}