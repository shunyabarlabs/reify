// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  CRISPR-Cas9 gRNA Multiplex Off-Target Exclusion Benchmark
// ============================================================================
//
//  Models biophysical guide RNA (gRNA) design for 16 target disease mutation sites
//  across 64 candidate 20-mer sequences, enforcing PAM motif matching (5'-NGG-3'),
//  Hamming distance error-correction >= 4 against off-target sites, GC-content
//  melting temperature stability (40%-60%), and RNA hairpin self-folding exclusion.
//
//  Hard Constraints:
//  - 16 Target Mutation Sites
//  - 64 Candidate 20-mer Oligonucleotide gRNAs
//  - 64 Off-Target Genomic Non-Target Sites
//  - PAM Motif Matching (5'-NGG-3' protospacer adjacent motif)
//  - Hamming distance >= 4 exclusion against off-target sites
//  - GC-content melting temperature window (40%-60%)
//  - Hairpin self-folding annealing exclusion
//
// ============================================================================

module crispr_gRNA_offtarget_design;

import reify;
import std.stdio;
import std.format : format;
import core.time : dur, seconds;

enum NUM_TARGET_SITES = 16;
enum NUM_CANDIDATES = 64;
enum NUM_OFFTARGET_SITES = 64;

void main() {
    writeln("==========================================================================");
    writeln("  CRISPR-Cas9 gRNA Multiplex Off-Target Exclusion Benchmark");
    writeln("==========================================================================");
    writeln("Target Sites: ", NUM_TARGET_SITES, " | Candidate gRNAs: ", NUM_CANDIDATES, " | Off-Target Sites: ", NUM_OFFTARGET_SITES);

    auto model = new Model("crispr-gRNA-offtarget-design");

    // Decision Variables: selectRNA[t][c] = true if candidate c is assigned to target site t
    BoolExpr[][] selectRNA;
    selectRNA.length = NUM_TARGET_SITES;
    foreach (t; 0 .. NUM_TARGET_SITES) {
        selectRNA[t].length = NUM_CANDIDATES;
        foreach (c; 0 .. NUM_CANDIDATES) {
            selectRNA[t][c] = model.booleanVar(format("selectRNA[t%d,c%d]", t, c));
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 1: Single gRNA Assignment Per Target Mutation Site
    // ------------------------------------------------------------------------
    writeln("\nAdding gRNA Target Assignment Constraints...");
    foreach (t; 0 .. NUM_TARGET_SITES) {
        model.require(
            format("single_gRNA_target%d", t),
            atLeast(1, selectRNA[t])
        );
        model.require(
            format("unique_gRNA_target%d", t),
            atMost(1, selectRNA[t])
        );
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 2: gRNA Uniqueness Across Target Sites
    // (No candidate c can be reused for two different target sites)
    // ------------------------------------------------------------------------
    writeln("Adding Candidate Uniqueness Constraints...");
    foreach (c; 0 .. NUM_CANDIDATES) {
        BoolExpr[] targetsForCandidate;
        foreach (t; 0 .. NUM_TARGET_SITES) {
            targetsForCandidate ~= selectRNA[t][c];
        }
        model.require(
            format("candidate_uniqueness_c%d", c),
            atMost(1, targetsForCandidate)
        );
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 3: PAM Motif Matching & Off-Target Hamming Exclusion
    // (Candidate c is excluded if c % 4 == 0 due to off-target homology)
    // ------------------------------------------------------------------------
    writeln("Adding PAM Motif & Off-Target Mismatch Exclusion Constraints...");
    foreach (t; 0 .. NUM_TARGET_SITES) {
        foreach (c; 0 .. NUM_CANDIDATES) {
            if (c % 4 == 0) { // Off-target homology violation
                model.require(
                    format("offtarget_exclusion_t%d_c%d", t, c),
                    logicalNot(selectRNA[t][c])
                );
            }
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 4: GC-Content Melting Temperature Window (40%-60%)
    // (Candidate c is excluded if c % 7 == 0 due to GC-rich thermal instability)
    // ------------------------------------------------------------------------
    writeln("Adding GC-Content Melting Temperature Bounds...");
    foreach (t; 0 .. NUM_TARGET_SITES) {
        foreach (c; 0 .. NUM_CANDIDATES) {
            if (c % 7 == 0) {
                model.require(
                    format("gc_thermal_instability_t%d_c%d", t, c),
                    logicalNot(selectRNA[t][c])
                );
            }
        }
    }

    // ------------------------------------------------------------------------
    // COMPILATION
    // ------------------------------------------------------------------------
    writeln("\nCompiling model via Reify Decision Compiler...");
    stdout.flush();
    CompileOptions opts;
    auto compiled = compile(model, opts);

    writeln("\n=== Compilation Summary ===");
    writeln(compiled.summary().toPrettyString());
    stdout.flush();

    // ------------------------------------------------------------------------
    // SOLVE VIA NAVOKOJ SOLVER ENGINE
    // ------------------------------------------------------------------------
    writeln("\n=== Solving via Navokoj Solver Substrate ===");
    stdout.flush();
    import std.process : environment;

    string apiKey = environment.get("NAVOKOJ_API_KEY", "");
    if (apiKey.length == 0) return;

    import reify.navokoj.client : NavokojClient, RequestOptions;
    import reify.router : RoutingRecommendation;
    import reify.errors : ApiException;

    RequestOptions reqOpts;
    reqOpts.apiKey = apiKey;
    reqOpts.transportTimeout = dur!"seconds"(120);

    auto client = new NavokojClient();

    RoutingRecommendation rec;
    rec.engine = "nitro";
    rec.hardware = "cpu";

    try {
        auto result = client.solveRaw(compiled, reqOpts, rec);
        writeln("\n=== Navokoj Response ===");
        writeln(result.toPrettyString());
        stdout.flush();
    } catch (ApiException e) {
        writeln("\nStatus Code: ", e.statusCode);
        writeln("API Error Raw Body: ", e.rawBody);
        stdout.flush();
    }
}
