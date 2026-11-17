// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {PoolRegistry} from "../src/registry/PoolRegistry.sol";
import {PayoutLedger} from "../src/rewards/PayoutLedger.sol";
import {RebateHook} from "../src/hook/RebateHook.sol";
import {ExternalAMMPool} from "../src/periphery/ExternalAMMPool.sol";
import {SwapRouter} from "../src/periphery/SwapRouter.sol";
import {TestToken} from "../src/tokens/TestToken.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IExternalVenue} from "../src/interfaces/IExternalVenue.sol";

contract RebateHookTest is BaseTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant DIVERGENCE_TRADE = 1e20; // ~1% price move vs sibling pool

    // ---------------------------------------------------------------- //
    // H-1: hook address carries exactly AFTER_INITIALIZE | AFTER_SWAP    //
    // ---------------------------------------------------------------- //
    function test_H1_hookAddressBits() public view {
        assertEq(uint160(address(hook)) & ALL_HOOK_MASK, NEEDED_MASK);
    }

    // ---------------------------------------------------------------- //
    // H-2: auto-pairing filled both slots                               //
    // ---------------------------------------------------------------- //
    function test_H2_autoPairing() public view {
        PoolRegistry.PairConfig memory cfg = registry.getPair(pairId);
        assertEq(PoolId.unwrap(cfg.pool1), PoolId.unwrap(poolId1));
        assertEq(PoolId.unwrap(cfg.pool2), PoolId.unwrap(poolId2));
        assertTrue(registry.isApprovedPool(poolId1));
        assertTrue(registry.isApprovedPool(poolId2));
    }

    // ---------------------------------------------------------------- //
    // H-3: BUY — trader 40%, LP 60% (folded 50/50 without protocol pools)
    // ---------------------------------------------------------------- //
    function test_H3_buyCaptureSplit() public {
        _createDivergence(DIVERGENCE_TRADE);

        uint256 traderBefore = ledger.traderCredits(alice, quoteCurrency());
        uint256 capturedBefore = ledger.capturedTotal(quoteCurrency());

        // alice BUYS base in the still-cheap pool2 (quote in, base out)
        _buyBase(key2, 1e18, alice);

        uint256 profit = ledger.capturedTotal(quoteCurrency()) - capturedBefore;
        assertGt(profit, 0, "no capture happened");

        uint256 traderShare = ledger.traderCredits(alice, quoteCurrency()) - traderBefore;
        assertEq(traderShare, profit * 4000 / 10_000, "BUY trader share != 40%");

        // LP side 60%, no protocol pools configured → folded 50/50 into the pair pools
        uint256 lp = profit - traderShare;
        uint256 pool1Credit = ledger.poolCredits(poolId1);
        uint256 pool2Credit = ledger.poolCredits(poolId2);
        assertEq(pool1Credit + pool2Credit, lp, "LP side != 60%");
        assertApproxEqAbs(pool1Credit, lp * 5000 / 10_000, 1); // +1 wei rounding dust
        assertEq(pool2Credit, lp * 5000 / 10_000);
        assertEq(hook.totalCaptures(), 1);
    }

    // ---------------------------------------------------------------- //
    // H-3b: with protocol pools configured the LP side splits 35/35/15/15
    // ---------------------------------------------------------------- //
    function test_H3b_fourWayLPSplit() public {
        // second mini-pair acts as the protocol's own pools
        TestToken protoBase = new TestToken("Proto Base", "PB", 18);
        TestToken protoQuote = new TestToken("Proto Quote", "PQ", 18);
        protoBase.mint(address(this), 1e24);
        protoQuote.mint(address(this), 1e24);
        registry.registerPair(Currency.wrap(address(protoBase)), Currency.wrap(address(protoQuote)));
        (Currency pc0, Currency pc1) = _sorted(Currency.wrap(address(protoBase)), Currency.wrap(address(protoQuote)));
        PoolKey memory pk1 =
            PoolKey({currency0: pc0, currency1: pc1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))});
        PoolKey memory pk2 =
            PoolKey({currency0: pc0, currency1: pc1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))});
        manager.initialize(pk1, SQRT_1_1);
        manager.initialize(pk2, SQRT_1_1);
        registry.setProtocolPools(pk1, pk2);

        _createDivergence(DIVERGENCE_TRADE);
        uint256 capturedBefore = ledger.capturedTotal(quoteCurrency());
        _buyBase(key2, 1e18, alice);

        uint256 profit = ledger.capturedTotal(quoteCurrency()) - capturedBefore;
        assertGt(profit, 0);
        uint256 traderShare = ledger.traderCredits(alice, quoteCurrency());
        assertEq(traderShare, profit * 4000 / 10_000);

        uint256 lp = profit - traderShare;
        assertApproxEqAbs(ledger.poolCredits(poolId1), lp * 3500 / 10_000, 1, "pair pool 1 != 35%"); // +1 wei rounding dust
        assertEq(ledger.poolCredits(poolId2), lp * 3500 / 10_000, "pair pool 2 != 35%");
        assertEq(ledger.poolCredits(pk1.toId()), lp * 1500 / 10_000, "protocol pool 1 != 15%");
        assertEq(ledger.poolCredits(pk2.toId()), lp * 1500 / 10_000, "protocol pool 2 != 15%");
    }

    // ---------------------------------------------------------------- //
    // H-4: SELL — trader 10%, LP 90%
    // ---------------------------------------------------------------- //
    function test_H4_sellCaptureSplit() public {
        _createDivergence(DIVERGENCE_TRADE);

        uint256 capturedBefore = ledger.capturedTotal(quoteCurrency());
        uint256 traderBefore = ledger.traderCredits(alice, quoteCurrency());

        // alice SELLS base in the cheap pool2 (base in, quote out)
        _sellBase(key2, 1e18, alice);

        uint256 profit = ledger.capturedTotal(quoteCurrency()) - capturedBefore;
        assertGt(profit, 0, "no capture happened");

        uint256 traderShare = ledger.traderCredits(alice, quoteCurrency()) - traderBefore;
        assertEq(traderShare, profit * 1000 / 10_000, "SELL trader share != 10%");
        uint256 lp = profit - traderShare;
        assertEq(ledger.poolCredits(poolId1) + ledger.poolCredits(poolId2), lp);
        assertApproxEqAbs(lp, profit * 9000 / 10_000, 1); // floor rounding on both sides
    }

    // ---------------------------------------------------------------- //
    // H-5: no divergence → no payout
    // ---------------------------------------------------------------- //
    function test_H5_noDivergenceNoPayout() public {
        uint256 capturedBefore = ledger.capturedTotal(quoteCurrency());
        // tiny swap in a balanced pair: divergence far below minProfit
        _buyBase(key2, 1e16, alice);
        assertEq(ledger.capturedTotal(quoteCurrency()), capturedBefore, "unexpected payout");
        assertEq(ledger.traderCredits(alice, quoteCurrency()), 0);
        assertEq(hook.totalCaptures(), 0);
    }

    // ---------------------------------------------------------------- //
    // H-7: exactly one capture per user swap (no recursion)
    // ---------------------------------------------------------------- //
    function test_H7_singleCapturePerSwap() public {
        _createDivergence(DIVERGENCE_TRADE);
        _buyBase(key2, 1e18, alice);
        assertEq(hook.captureCount(pairId), 1, "capture ran more than once");
    }

    // ---------------------------------------------------------------- //
    // H-5b/H-9: fees exceed spread → realized negative → no payout;
    //           with a tight loss guard the breaker trips and pauses
    // ---------------------------------------------------------------- //
    function test_H9_lossGuardTripsAndPauses() public {
        // allow capture at microscopic divergence (minProfit 0, big trade cap)
        PoolRegistry.PairConfig memory cfg = registry.getPair(pairId);
        PoolRegistry.PairParams memory p = cfg.params;
        p.minProfitQuote = 0;
        p.maxTradeSizeQuote = 1e24;
        p.maxSizeBpsOfLiquidity = 10_000; // uncapped by liquidity
        p.maxLossGuardQuote = 1; // any loss trips
        registry.setPairParams(pairId, p);

        // tiny divergence: swap 1e15 while paused → ~1e-7 relative move; the two v4
        // legs pay 0.05%+0.3% fees ⇒ realized profit negative ⇒ guard trips
        registry.setSystemPaused(true);
        _buyBase(key1, 1e15, alice);
        registry.setSystemPaused(false);

        vm.startPrank(alice);
        ERC20(Currency.unwrap(key2.currency0 == quoteCurrency() ? key2.currency0 : key2.currency1))
            .approve(address(router), type(uint256).max);
        vm.expectEmit(true, false, false, false);
        emit RebateHook.LossGuardTripped(pairId, 0); // topic1 match only
        router.swapExactIn(
            key2, Currency.unwrap(key2.currency0) == Currency.unwrap(quoteCurrency()), 1e15, 0, type(uint64).max
        );
        vm.stopPrank();

        assertTrue(registry.systemPaused(), "system should be paused after guard");
    }

    // ---------------------------------------------------------------- //
    // H-10: pauses stop capture but never break swaps
    // ---------------------------------------------------------------- //
    function test_H10_systemPauseStopsCapture() public {
        _createDivergence(DIVERGENCE_TRADE); // while paused inside helper
        registry.setSystemPaused(true);
        uint256 capturedBefore = ledger.capturedTotal(quoteCurrency());
        vm.startPrank(alice);
        ERC20(Currency.unwrap(key2.currency0 == quoteCurrency() ? key2.currency0 : key2.currency1))
            .approve(address(router), type(uint256).max);
        vm.expectEmit(true, false, false, true);
        emit RebateHook.CaptureSkipped(pairId, 1);
        router.swapExactIn(
            key2, Currency.unwrap(key2.currency0) == Currency.unwrap(quoteCurrency()), 1e18, 0, type(uint64).max
        );
        vm.stopPrank(); // succeeds, no capture
        assertEq(ledger.capturedTotal(quoteCurrency()), capturedBefore);
        registry.setSystemPaused(false);
    }

    function test_H10_pairPauseStopsCapture() public {
        registry.setPairCapturePaused(pairId, true);
        _buyBase(key2, 1e18, alice);
        assertEq(hook.captureCount(pairId), 0);
        assertEq(hook.totalCaptures(), 0);
    }

    // ---------------------------------------------------------------- //
    // H-11: searcher backrun captures divergence, searcher earns the bounty
    // ---------------------------------------------------------------- //
    function test_H11_keeperBackrun() public {
        _createDivergence(DIVERGENCE_TRADE);
        uint256 capturedBefore = ledger.capturedTotal(quoteCurrency());

        vm.prank(bob);
        hook.backrun(pairId, bob);

        uint256 profit = ledger.capturedTotal(quoteCurrency()) - capturedBefore;
        assertGt(profit, 0, "searcher capture failed");
        // searcher commission: 10% (searcherBps) to the searcher, 90% LP
        assertEq(ledger.traderCredits(bob, quoteCurrency()), profit * 1000 / 10_000);
    }

    // ---------------------------------------------------------------- //
    // H-12: LP distribution via donate increases pool fee growth
    // ---------------------------------------------------------------- //
    function test_H12_distributePoolRewards() public {
        _createDivergence(DIVERGENCE_TRADE);
        _buyBase(key2, 1e18, alice);

        uint256 credit = ledger.poolCredits(poolId1);
        assertGt(credit, 0);

        bool quoteIsC0 = Currency.unwrap(key1.currency0) == Currency.unwrap(quoteCurrency());
        (uint256 fg0Before, uint256 fg1Before) = manager.getFeeGrowthGlobals(poolId1);
        uint256 fgqBefore = quoteIsC0 ? fg0Before : fg1Before;

        hook.distributePoolRewards(poolId1);

        assertEq(ledger.poolCredits(poolId1), 0, "credit not zeroed");
        (uint256 fg0After, uint256 fg1After) = manager.getFeeGrowthGlobals(poolId1);
        uint256 fgqAfter = quoteIsC0 ? fg0After : fg1After;
        assertGt(fgqAfter, fgqBefore, "quote-side fee growth did not increase");
    }

    // ---------------------------------------------------------------- //
    // H-13: traders claim accrued rebates
    // ---------------------------------------------------------------- //
    function test_H13_claim() public {
        _createDivergence(DIVERGENCE_TRADE);
        _buyBase(key2, 1e18, alice);

        uint256 credit = ledger.traderCredits(alice, quoteCurrency());
        assertGt(credit, 0);

        uint256 before = quoteToken.balanceOf(alice);
        vm.prank(alice);
        ledger.claim(quoteCurrency(), alice);
        assertEq(quoteToken.balanceOf(alice), before + credit);
        assertEq(ledger.traderCredits(alice, quoteCurrency()), 0);

        vm.prank(alice);
        vm.expectRevert(PayoutLedger.NothingToClaim.selector);
        ledger.claim(quoteCurrency(), alice);
    }

    // ---------------------------------------------------------------- //
    // H-14: external venue participates in capture; removal stops routing
    // ---------------------------------------------------------------- //
    function test_H14_externalVenueCapture() public {
        // venue: base cheap there (1 base ≈ 0.952 quote) vs v4 pools at 1.00
        // fee 30 bps = 0.3%; seed(amount0=quote-side, amount1=base-side)
        ExternalAMMPool venue = new ExternalAMMPool(baseCurrency(), quoteCurrency(), 30, address(this));
        baseToken.approve(address(venue), type(uint256).max);
        quoteToken.approve(address(venue), type(uint256).max);
        venue.seed(1.05e22, 1e22);

        registry.registerVenue(pairId, address(venue));
        hook.approveVenue(baseCurrency(), quoteCurrency(), address(venue));

        uint256 capturedBefore = ledger.capturedTotal(quoteCurrency());
        (uint256 r0Before, uint256 r1Before) = venue.getReserves();

        // even a micro swap triggers the venue-arbitrage (5% divergence)
        _buyBase(key2, 1e16, alice);

        uint256 profit = ledger.capturedTotal(quoteCurrency()) - capturedBefore;
        assertGt(profit, 0, "venue capture failed");
        (uint256 r0After, uint256 r1After) = venue.getReserves();
        assertTrue(r0After != r0Before && r1After != r1Before, "venue untouched");

        // removal stops routing through the venue
        registry.removeVenue(pairId, address(venue));
        (uint256 r0AfterRemove,) = venue.getReserves();
        _buyBase(key2, 1e16, alice);
        (uint256 r0Final,) = venue.getReserves();
        assertEq(r0Final, r0AfterRemove, "venue still used after removal");
    }

    // ---------------------------------------------------------------- //
    // H-15: router slippage protection
    // ---------------------------------------------------------------- //
    function test_H15_routerSlippage() public {
        vm.startPrank(alice);
        Currency tokenIn =
            Currency.unwrap(key2.currency0) == Currency.unwrap(quoteCurrency()) ? key2.currency0 : key2.currency1;
        ERC20(Currency.unwrap(tokenIn)).approve(address(router), type(uint256).max);
        bool zeroForOne = Currency.unwrap(key2.currency0) == Currency.unwrap(tokenIn);
        vm.expectRevert(SwapRouter.TooLittleOutput.selector);
        router.swapExactIn(key2, zeroForOne, 1e18, type(uint256).max, type(uint64).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- //
    // H-16: dynamic-fee pool pays baseFee for small swaps
    // H-17: dynamic-fee pool pays surgeFee for swaps above surgeThreshold
    // ---------------------------------------------------------------- //
    function _impliedFeeBps(PoolId poolId_, uint256 amountIn, bool zeroForOne) internal returns (uint24 implied) {
        (uint256 fg0Before, uint256 fg1Before) = manager.getFeeGrowthGlobals(poolId_);
        _doSwap(key2, zeroForOne, amountIn, alice);
        (uint256 fg0After, uint256 fg1After) = manager.getFeeGrowthGlobals(poolId_);

        uint128 L = manager.getLiquidity(poolId_);
        uint256 delta = zeroForOne ? fg0After - fg0Before : fg1After - fg1Before;
        // delta = feeAmount · 2^128 / L  with feeAmount = amountIn · fee / 1e6
        //   ⇒ fee = delta · L · 1e6 / (amountIn · 2^128)
        uint256 denom = Math.mulDiv(amountIn, 1 << 128, 1_000_000);
        implied = uint24(Math.mulDiv(delta, L, denom));
    }

    function test_H16_dynamicFeeBase() public {
        registry.setSystemPaused(true); // measure fees without capture noise
        bool zeroForOne = Currency.unwrap(key2.currency0) == Currency.unwrap(quoteCurrency());
        uint24 implied = _impliedFeeBps(poolId2, 1e18, zeroForOne); // < surgeThreshold 1e21
        registry.setSystemPaused(false);
        assertApproxEqRel(uint256(implied), 3000, 1e15, "small swap fee != baseFee 3000");
    }

    function test_H17_dynamicFeeSurge() public {
        registry.setSystemPaused(true);
        bool zeroForOne = Currency.unwrap(key2.currency0) == Currency.unwrap(quoteCurrency());
        uint24 implied = _impliedFeeBps(poolId2, 2e21, zeroForOne); // > surgeThreshold 1e21
        registry.setSystemPaused(false);
        assertApproxEqRel(uint256(implied), 10_000, 1e15, "large swap fee != surgeFee 10000");
    }

    // ---------------------------------------------------------------- //
    // H-18: IL carve-out routes part of the LP side into the ILFund
    // ---------------------------------------------------------------- //
    function test_H18_ilCarveOut() public {
        // 10% of the LP side into the IL fund
        PoolRegistry.PairParams memory p = registry.getPair(pairId).params;
        p.ilBps = 1000;
        registry.setPairParams(pairId, p);

        _createDivergence(DIVERGENCE_TRADE);
        uint256 capturedBefore = ledger.capturedTotal(quoteCurrency());

        _buyBase(key2, 1e18, alice);

        // realized profit = what the ledger escrowed + what the IL fund received
        uint256 ledgerDelta = ledger.capturedTotal(quoteCurrency()) - capturedBefore;
        uint256 ilTotal = ilFund.fundedTotal(quoteCurrency());
        uint256 realized = ledgerDelta + ilTotal;
        assertGt(realized, 0);

        uint256 traderShare = ledger.traderCredits(alice, quoteCurrency());
        assertEq(traderShare, realized * 4000 / 10_000, "trader share unchanged by IL carve");

        assertEq(ilTotal, (realized - traderShare) * 1000 / 10_000, "IL fund != 10% of LP side");

        // ledger escrows only trader + LP shares (realized − IL carve)
        assertEq(ledgerDelta, realized - ilTotal);
        assertTrue(ilFund.isSolvent(quoteCurrency()));
    }
}
