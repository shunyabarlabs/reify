// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify.errors;

/**
 * Base exception for errors raised by navokoj-app.
 */
class NavokojException : Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super(message, file, line);
    }
}

/**
 * The declared decision model is invalid.
 */
class ModelException : NavokojException {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super(message, file, line);
    }
}

/**
 * The model is valid, but cannot be represented by an available API backend.
 */
class CapabilityException : NavokojException {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super(message, file, line);
    }
}

/**
 * A transport-level or API-level request failed.
 */
enum RequestDeliveryState {
    /**
     * The exception predates delivery tracking or came from a custom transport
     * which did not report whether it attempted the request.
     */
    unspecified,

    /**
     * The client rejected the request before invoking the HTTP transport.
     */
    notSent,

    /**
     * The transport failed after it was invoked. The server may have accepted
     * and billed the request, so retrying without idempotency can duplicate work.
     */
    acceptanceUnknown,

    /**
     * An HTTP response was received from the remote endpoint.
     */
    responseReceived
}

class ApiException : NavokojException {
    int statusCode;
    string requestId;
    long retryAfterSeconds;
    string rawBody;
    RequestDeliveryState deliveryState;

    this(
        string message,
        int statusCode = 0,
        string requestId = "",
        long retryAfterSeconds = 0,
        string rawBody = "",
        string file = __FILE__,
        size_t line = __LINE__
    ) {
        super(message, file, line);
        this.statusCode = statusCode;
        this.requestId = requestId;
        this.retryAfterSeconds = retryAfterSeconds;
        this.rawBody = rawBody;
    }

    /**
     * True when the transport failed without proving whether the server
     * accepted the request. Such failures must not be retried automatically.
     */
    bool deliveryIsUncertain() const nothrow @safe {
        return deliveryState == RequestDeliveryState.acceptanceUnknown;
    }
}

/**
 * The API returned a response which cannot be reconciled with the compiled model.
 */
class ProtocolException : NavokojException {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super(message, file, line);
    }
}