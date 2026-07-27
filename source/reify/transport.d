// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

/**
 * Vendor-neutral HTTP transport boundary.
 *
 * Anything that talks JSON-over-HTTPS with a bearer token plugs in here.
 * The SDK ships `CurlTransport` (Phobos `std.net.curl`) as the default
 * implementation; tests and alternate solvers can supply their own.
 *
 * This module is intentionally neutral with respect to any specific
 * solver vendor. The reference Navokoj wire lives one layer up
 * (see `reify.navokoj.client`).
 */

module reify.transport;

import reify.errors : ApiException, RequestDeliveryState;

import std.datetime : Duration;
import std.net.curl : HTTP;

struct HttpResponse {
    int statusCode;
    string body;
    string[string] headers;
}

/**
 * Injectable transport boundary. Tests and applications may supply their own
 * implementation without changing the modeling or compilation layers.
 */
interface HttpTransport {
    HttpResponse postJson(
        string url,
        string bearerToken,
        string body,
        Duration connectTimeout,
        Duration operationTimeout
    );
}

/**
 * Production HTTPS transport implemented with Phobos' libcurl adapter.
 */
final class CurlTransport : HttpTransport {
    override HttpResponse postJson(
        string url,
        string bearerToken,
        string body,
        Duration connectTimeout,
        Duration operationTimeout
    ) {
        auto http = HTTP(url);
        http.connectTimeout = connectTimeout;
        http.operationTimeout = operationTimeout;
        http.addRequestHeader("Accept", "application/json");
        http.addRequestHeader("Authorization", "Bearer " ~ bearerToken);

        // Phobos does not copy this payload. `body` remains live until the
        // synchronous perform() call below returns.
        http.setPostData(body, "application/json");

        ubyte[] received;
        http.onReceive = (ubyte[] chunk) {
            received ~= chunk;
            return chunk.length;
        };

        try {
            http.perform();
        } catch (Exception error) {
            auto failure = new ApiException(
                "HTTP transport failed: " ~ error.msg ~
                ". Request acceptance is unknown; do not retry automatically " ~
                "without an idempotency guarantee."
            );
            failure.deliveryState = RequestDeliveryState.acceptanceUnknown;
            throw failure;
        }

        HttpResponse response;
        response.statusCode = cast(int) http.statusLine.code;
        response.body = cast(string) received;
        foreach (key, value; http.responseHeaders) {
            response.headers[key] = value;
        }
        return response;
    }
}