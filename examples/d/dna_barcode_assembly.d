// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  DNA Oligonucleotide Barcode Design Benchmark
// ============================================================================
//
//  Models the selection of multiplexed DNA primer barcodes for Next-Generation
//  Sequencing (NGS) platforms (e.g. Illumina, PacBio).
//
//  Biophysical Constraints:
//  - Pairwise Hamming Distance >= 3 (enables 1-bit error correction against PCR substitution errors)
//  - GC-Content Thermal Stability (40%-60% G/C ratio for 55°C-65°C melting temperature)
//  - Homopolymer Saturation Exclusion (no 3+ consecutive identical nucleotides)
//  - Hairpin Folding Exclusions (no self-complementary palindromic sequences)
//
// ============================================================================

module dna_barcode_assembly;

import reify;
import std.stdio;
import std.array : array;
import std.range : iota;
import std.format : format;
import std.algorithm : count;
import core.time : dur, seconds;

enum BARCODE_LEN = 8;
enum TARGET_COUNT = 10;

int hammingDistance(string seq1, string seq2) {
    int dist = 0;
    foreach (i; 0 .. BARCODE_LEN) {
        if (seq1[i] != seq2[i]) dist++;
    }
    return dist;
}

bool hasHomopolymer(string seq) {
    foreach (i; 0 .. BARCODE_LEN - 2) {
        if (seq[i] == seq[i+1] && seq[i+1] == seq[i+2]) return true;
    }
    return false;
}

bool hasHairpin(string seq) {
    foreach (i; 0 .. 4) {
        char b1 = seq[i];
        char b2 = seq[7 - i];
        if ((b1 == 'A' && b2 == 'T') || (b1 == 'T' && b2 == 'A') ||
            (b1 == 'C' && b2 == 'G') || (b1 == 'G' && b2 == 'C')) {
            if (i == 0) return true;
        }
    }
    return false;
}

bool isValidGc(string seq) {
    size_t gcCount = 0;
    foreach (ch; seq) {
        if (ch == 'G' || ch == 'C') gcCount++;
    }
    return gcCount >= 3 && gcCount <= 5;
}

string[] generateCandidateBarcodes(size_t limit = 64) {
    char[4] bases = ['A', 'C', 'G', 'T'];
    string[] allValid;

    foreach (b0; bases) {
    foreach (b1; bases) {
    foreach (b2; bases) {
    foreach (b3; bases) {
    foreach (b4; bases) {
    foreach (b5; bases) {
    foreach (b6; bases) {
    foreach (b7; bases) {
        string seq = [b0, b1, b2, b3, b4, b5, b6, b7].idup;
        if (isValidGc(seq) && !hasHomopolymer(seq) && !hasHairpin(seq)) {
            allValid ~= seq;
        }
    }}}}}}}}

    // Strided selection to maximize diversity across candidate pool
    string[] candidates;
    size_t step = allValid.length / limit;
    if (step == 0) step = 1;
    for (size_t idx = 0; idx < allValid.length && candidates.length < limit; idx += step) {
        candidates ~= allValid[idx];
    }
    return candidates;
}

void main() {
    writeln("==========================================================================");
    writeln("  DNA Oligonucleotide Barcode Design Benchmark");
    writeln("==========================================================================");
    writeln("Barcode Length: ", BARCODE_LEN, " base pairs");
    writeln("Target Pool Size: ", TARGET_COUNT, " error-correcting DNA multiplex tags");

    string[] candidates = generateCandidateBarcodes(64);
    const numCandidates = candidates.length;
    writeln("Filtered Candidate Pool: ", numCandidates, " biophysically valid 8-mers");
    writeln("Decision Variables: ", numCandidates, " boolean barcode selection flags");

    auto model = new Model("dna-barcode-assembly");

    // Decision Variables: select[i] = true if candidate barcode i is selected in multiplex pool
    BoolExpr[] select;
    select.length = numCandidates;
    foreach (i; 0 .. numCandidates) {
        select[i] = model.booleanVar(format("select[%s]", candidates[i]));
    }

    // HARD CONSTRAINT 1: Select exactly TARGET_COUNT (10) barcodes for multiplex panel
    writeln("\nAdding Pool Size Constraint (Exactly 10 Barcodes)...");
    model.require("target_pool_size", exactly(TARGET_COUNT, select));

    // HARD CONSTRAINT 2: Pairwise Hamming Distance Exclusion (>= 3 base differences)
    writeln("Adding Pairwise Hamming Distance Constraints (>= 3 Base Differences)...");
    size_t conflictPairs = 0;
    foreach (i; 0 .. numCandidates) {
        foreach (j; i + 1 .. numCandidates) {
            int dist = hammingDistance(candidates[i], candidates[j]);
            if (dist < 3) {
                conflictPairs++;
                model.require(
                    format("hamming_dist_%d_%d", i, j),
                    implies(select[i], logicalNot(select[j]))
                );
            }
        }
    }
    writeln("Conflicting Candidate Pairs (Hamming Distance < 3): ", conflictPairs);

    // SOFT PREFERENCE: Maximize high Hamming distance (prefer pairs with dist >= 5)
    foreach (i; 0 .. numCandidates) {
        foreach (j; i + 1 .. numCandidates) {
            int dist = hammingDistance(candidates[i], candidates[j]);
            if (dist >= 5) {
                model.medium(
                    format("prefer_high_dist_%d_%d", i, j),
                    logicalNot(select[i] & select[j]),
                    2.0
                );
            }
        }
    }

    // ------------------------------------------------------------------------
    // COMPILATION
    // ------------------------------------------------------------------------
    writeln("\nCompiling model via Reify Decision Compiler...");
    CompileOptions opts;
    opts.maxBddNodesPerConstraint = 10_000_000;
    auto compiled = compile(model, opts);

    writeln("\n=== Compilation Summary ===");
    writeln(compiled.summary().toPrettyString());

    // ------------------------------------------------------------------------
    // SOLVE VIA NAVOKOJ SOLVER ENGINE
    // ------------------------------------------------------------------------
    writeln("\n=== Solving via Navokoj Solver Substrate ===");
    import std.process : environment;

    string apiKey = environment.get("NAVOKOJ_API_KEY", "");
    if (apiKey.length == 0) {
        writeln("Set NAVOKOJ_API_KEY to execute solver.");
        return;
    }

    import reify.navokoj.client : NavokojClient, RequestOptions;
    import reify.router : RoutingRecommendation;

    RequestOptions reqOpts;
    reqOpts.apiKey = apiKey;
    reqOpts.transportTimeout = dur!"seconds"(120);

    auto client = new NavokojClient();

    RoutingRecommendation rec;
    rec.engine = "nitro";
    rec.hardware = "cpu";

    auto result = client.solveRaw(compiled, reqOpts, rec);

    writeln("\n=== Navokoj Response ===");
    writeln(result.toPrettyString());
}
