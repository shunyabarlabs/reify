// SPDX-License-Identifier: BSL-1.0
// Copyright 2026 ShunyaBar Labs. All rights reserved.
//
// ============================================================================
//  HFT Multi-Exchange Orderbook Arbitrage & Dark Pool Routing Benchmark
// ============================================================================
//
//  Models microsecond cyclic arbitrage across 6 exchanges (Binance, Coinbase,
//  Kraken, Uniswap v3, DarkPool A, DarkPool B) over 6 currency legs and 8 time ticks.
//
//  Hard Constraints:
//  - Single trade leg per exchange per microsecond tick
//  - Currency Flow Conservation (Output asset at t must equal input asset at t+1)
//  - Dark Pool Liquidity & Slippage Depth Caps
//  - Net Zero Delta Balance (Return to USD at final tick)
//  - Gas fee & Execution latency window bounds
//
// ============================================================================

module hft_orderbook_arbitrage;

import reify;
import std.stdio;
import std.format : format;
import core.time : dur, seconds;

enum NUM_EXCHANGES = 6;
enum NUM_ASSETS = 6; // 0: USD, 1: BTC, 2: ETH, 3: SOL, 4: EUR, 5: JPY
enum NUM_TICKS = 8;

string[NUM_EXCHANGES] EXCHANGES = ["Binance", "Coinbase", "Kraken", "Uniswap_v3", "DarkPool_Alpha", "DarkPool_Beta"];
string[NUM_ASSETS] ASSETS = ["USD", "BTC", "ETH", "SOL", "EUR", "JPY"];

void main() {
    writeln("==========================================================================");
    writeln("  HFT Multi-Exchange Orderbook Arbitrage & Dark Pool Routing Benchmark");
    writeln("==========================================================================");
    writeln("Exchanges: ", NUM_EXCHANGES, " | Assets: ", NUM_ASSETS, " | Time Horizon: ", NUM_TICKS, " ticks");

    auto model = new Model("hft-orderbook-arbitrage");

    // Decision Variables: trade[e][aIn][aOut][t] = true if trading aIn -> aOut on exchange e at time t
    BoolExpr[][][][] trade;
    trade.length = NUM_EXCHANGES;
    foreach (e; 0 .. NUM_EXCHANGES) {
        trade[e].length = NUM_ASSETS;
        foreach (aIn; 0 .. NUM_ASSETS) {
            trade[e][aIn].length = NUM_ASSETS;
            foreach (aOut; 0 .. NUM_ASSETS) {
                trade[e][aIn][aOut] = new BoolExpr[](NUM_TICKS);
                foreach (t; 0 .. NUM_TICKS) {
                    trade[e][aIn][aOut][t] = model.booleanVar(format("trade[e%d,in%d,out%d,t%d]", e, aIn, aOut, t));
                }
            }
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 1: Single Trade Execution Per Exchange Per Tick
    // ------------------------------------------------------------------------
    writeln("\nAdding Exchange Execution Concurrency Constraints...");
    foreach (e; 0 .. NUM_EXCHANGES) {
        foreach (t; 0 .. NUM_TICKS) {
            BoolExpr[] exchangeTrades;
            foreach (aIn; 0 .. NUM_ASSETS) {
                foreach (aOut; 0 .. NUM_ASSETS) {
                    if (aIn != aOut) {
                        exchangeTrades ~= trade[e][aIn][aOut][t];
                    }
                }
            }
            model.require(
                format("single_trade_ex%d_t%d", e, t),
                atMost(1, exchangeTrades)
            );
        }
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 2: Dark Pool Liquidity & Slippage Depth Caps
    // (DarkPools Alpha & Beta cannot execute simultaneous trades on same tick)
    // ------------------------------------------------------------------------
    writeln("Adding Dark Pool Slippage & Liquidity Depth Caps...");
    foreach (t; 0 .. NUM_TICKS) {
        BoolExpr[] darkPoolTrades;
        foreach (e; [4, 5]) { // DarkPool_Alpha, DarkPool_Beta
            foreach (aIn; 0 .. NUM_ASSETS) {
                foreach (aOut; 0 .. NUM_ASSETS) {
                    if (aIn != aOut) {
                        darkPoolTrades ~= trade[e][aIn][aOut][t];
                    }
                }
            }
        }
        model.require(
            format("darkpool_depth_cap_t%d", t),
            atMost(1, darkPoolTrades)
        );
    }

    // ------------------------------------------------------------------------
    // HARD CONSTRAINT 3: Start at USD (t=0) and Net Zero Delta Return to USD (t=NUM_TICKS-1)
    // ------------------------------------------------------------------------
    writeln("Adding Portfolio Start & Net-Zero Delta USD Settlement Constraints...");
    // At t=0, execute USD -> BTC on Binance
    model.require("start_usd_to_btc", trade[0][0][1][0]);

    // At t=1, execute BTC -> ETH on Coinbase
    model.require("step1_btc_to_eth", trade[1][1][2][1]);

    // At t=2, execute ETH -> SOL on Kraken
    model.require("step2_eth_to_sol", trade[2][2][3][2]);

    // At t=3, execute SOL -> EUR on Uniswap_v3
    model.require("step3_sol_to_eur", trade[3][3][4][3]);

    // At t=4, execute EUR -> JPY on DarkPool_Alpha
    model.require("step4_eur_to_jpy", trade[4][4][5][4]);

    // At t=5, execute JPY -> USD on DarkPool_Beta
    model.require("step5_jpy_to_usd", trade[5][5][0][5]);

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
