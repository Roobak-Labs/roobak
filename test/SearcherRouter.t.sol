// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {PoolRegistry} from "../src/registry/PoolRegistry.sol";
import {SearcherRouter} from "../src/periphery/SearcherRouter.sol";

contract SearcherRouterTest is BaseTest {
    SearcherRouter internal sr;

    function setUp() public override {
        super.setUp();
        sr = new SearcherRouter(hook);
    }

    // ---------------------------------------------------------------- //
    // SR-1: batch submit captures divergence; the searcher earns the bounty
    // ---------------------------------------------------------------- //
    function test_SR1_submitEarnsCommission() public {
        _createDivergence(1e20);
        uint256 capturedBefore = ledger.capturedTotal(quoteCurrency());

        bytes32[] memory pairs = new bytes32[](1);
        pairs[0] = pairId;
        vm.prank(bob);
        sr.submit(pairs);

        uint256 profit = ledger.capturedTotal(quoteCurrency()) - capturedBefore;
        assertGt(profit, 0, "searcher batch captured nothing");
        // searcher commission = searcherBps (10%) — credited through the ledger
        assertEq(ledger.traderCredits(bob, quoteCurrency()), profit * 1000 / 10_000);
    }

    // ---------------------------------------------------------------- //
    // SR-2: empty and oversized batches revert
    // ---------------------------------------------------------------- //
    function test_SR2_batchBounds() public {
        bytes32[] memory empty = new bytes32[](0);
        vm.expectRevert(SearcherRouter.TooManyPairs.selector);
        sr.submit(empty);

        bytes32[] memory big = new bytes32[](9);
        for (uint256 i = 0; i < 9; i++) {
            big[i] = pairId;
        }
        vm.expectRevert(SearcherRouter.TooManyPairs.selector);
        sr.submit(big);
    }

    // ---------------------------------------------------------------- //
    // SR-3: an unprofitable pair is skipped without aborting the batch
    // ---------------------------------------------------------------- //
    function test_SR3_unprofitablePairSkipsGracefully() public {
        bytes32[] memory pairs = new bytes32[](2);
        pairs[0] = pairId;
        pairs[1] = bytes32("unknown-pair");

        // no divergence: both captures skip; the batch itself succeeds
        vm.prank(bob);
        sr.submit(pairs);
        assertEq(hook.totalCaptures(), 0);
    }

    // ---------------------------------------------------------------- //
    // SR-4: the searcher commission is registry-configurable per pair
    // ---------------------------------------------------------------- //
    function test_SR4_commissionConfigurable() public {
        PoolRegistry.PairParams memory p = registry.getPair(pairId).params;
        p.searcherBps = 2500;
        registry.setPairParams(pairId, p);

        _createDivergence(1e20);
        bytes32[] memory pairs = new bytes32[](1);
        pairs[0] = pairId;
        vm.prank(bob);
        sr.submit(pairs);

        uint256 profit = ledger.pairCapturedTotal(pairId);
        assertApproxEqRel(ledger.traderCredits(bob, quoteCurrency()), profit * 2500 / 10_000, 1e15);
    }
}
