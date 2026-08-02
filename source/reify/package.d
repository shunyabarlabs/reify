// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.

module reify;

public import reify.app;
public import reify.backend;
public import reify.navokoj.backend : NavokojBackend;
public import reify.local.backend :
    CommandSolverBackend,
    createLocalBackend,
    executeLocalWithFallback,
    solveLocal;
public import reify.navokoj.client :
    NavokojClient,
    RequestOptions,
    defaultBaseUrl;
public import reify.transport :
    CurlTransport,
    HttpResponse,
    HttpTransport;
public import reify.compiler :
    Backend,
    CompileOptions,
    CompiledModel,
    backendName,
    compile,
    validateModel;
public import reify.document : documentApp;
public import reify.dimacs;
public import reify.errors;
public import reify.formula;
public import reify.model;
public import reify.builders;
public import reify.spacetime;
public import reify.exports;
public import reify.explain;
public import reify.diagnostics;
public import reify.router;
public import reify.opb;
public import reify.result :
    ConstraintMatch,
    DecisionStatus,
    DecisionValue,
    MatchState,
    NormalizedResponse,
    ObjectiveResult,
    RunStatus,
    Score,
    Solution,
    SolveResult,
    VerificationReport;
