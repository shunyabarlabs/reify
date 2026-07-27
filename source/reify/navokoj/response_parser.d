// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

/**
 * Reference response decoder for Navokoj envelopes.
 *
 * Pairs with `NavokojBackend` (or with direct `NavokojClient.solveRaw`
 * usage) to turn the wire JSON into the shared, locally-verified
 * `SolveResult`. Other vendors provide their own `SolverResponseParser`
 * implementation against the interface in `reify.backend`.
 */

module reify.navokoj.response_parser;

import reify.backend :
    BackendResponse,
    SolverResponseParser;
import reify.compiler : CompiledModel;
import reify.errors : ProtocolException;
import reify.result : SolveResult, buildSolveResult;

/** Parser for Navokoj's response envelope. Other solvers provide their own. */
final class NavokojResponseParser : SolverResponseParser {
    override string id() const { return "navokoj"; }

    override SolveResult parse(
        CompiledModel compiled,
        BackendResponse response
    ) {
        if (response.backend != id()) {
            throw new ProtocolException(
                "NavokojResponseParser received backend '" ~
                response.backend ~ "'"
            );
        }
        return buildSolveResult(compiled, response.raw);
    }
}