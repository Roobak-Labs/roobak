// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {PayoutLedger} from "../src/rewards/PayoutLedger.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract PayoutLedgerTest is BaseTest {
    using CurrencyLibrary for Currency;

    PoolId[4] pools;
    uint256[4] shares;

    function setUp() public virtual override {
        super.setUp();
        pools = [poolId1, poolId2, poolId1, poolId2];
    }

    function _capture(uint256 traderShare, uint256[4] memory poolShares) internal {
        uint256 total = traderShare;
        for (uint256 i = 0; i < 4; i++) {
            total += poolShares[i];
        }
        quoteToken.transfer(address(hook), total);
        vm.startPrank(address(hook));
        quoteToken.approve(address(ledger), total);
        ledger.onCapture(pairId, quoteCurrency(), alice, traderShare, pools, poolShares);
        vm.stopPrank();
    }

    function test_L1_onCaptureAccrual() public {
        uint256[4] memory sh = [uint256(100), 200, 300, 400];
        _capture(500, sh);

        assertEq(ledger.traderCredits(alice, quoteCurrency()), 500);
        assertEq(ledger.poolCredits(poolId1), 400); // 100 + 300 (duplicate pool ids merge)
        assertEq(ledger.poolCredits(poolId2), 600); // 200 + 400
        assertEq(ledger.capturedTotal(quoteCurrency()), 1500);
        assertEq(ledger.pairCapturedTotal(pairId), 1500);
        assertTrue(ledger.isSolvent(quoteCurrency()));
    }

    function test_L2_overdraftImpossible() public {
        // hook-side: trying to accrue without escrowing reverts at transferFrom
        uint256[4] memory sh = [uint256(1), 1, 1, 1];
        vm.startPrank(address(hook));
        vm.expectRevert();
        ledger.onCapture(pairId, quoteCurrency(), alice, 1, pools, sh);
        vm.stopPrank();
    }

    function test_L2b_badSplitRejected() public {
        uint256[4] memory sh = [uint256(1), 1, 1, 0];
        PoolId[4] memory bad = [PoolId.wrap(0), poolId2, poolId1, poolId2];
        quoteToken.transfer(address(hook), 10);
        vm.startPrank(address(hook));
        quoteToken.approve(address(ledger), 10);
        vm.expectRevert(PayoutLedger.BadSplit.selector);
        ledger.onCapture(pairId, quoteCurrency(), alice, 4, bad, sh);
        vm.stopPrank();
    }

    function test_L3_claimPaysExact() public {
        uint256[4] memory sh = [uint256(100), 100, 100, 100];
        _capture(400, sh);

        uint256 before = quoteToken.balanceOf(alice);
        vm.prank(alice);
        ledger.claim(quoteCurrency(), alice);
        assertEq(quoteToken.balanceOf(alice), before + 400);
        assertTrue(ledger.isSolvent(quoteCurrency()));
    }

    function test_L4_doubleClaimZero() public {
        uint256[4] memory sh = [uint256(100), 100, 100, 100];
        _capture(400, sh);
        vm.startPrank(alice);
        ledger.claim(quoteCurrency(), alice);
        vm.expectRevert(PayoutLedger.NothingToClaim.selector);
        ledger.claim(quoteCurrency(), alice);
        vm.stopPrank();
    }

    function test_L5_releaseToHook() public {
        uint256[4] memory sh = [uint256(1000), 0, 0, 0];
        _capture(0, sh);

        uint256 hookBalanceBefore = quoteToken.balanceOf(address(hook));
        vm.prank(address(hook));
        ledger.releaseToHook(poolId1, 600);

        assertEq(ledger.poolCredits(poolId1), 400);
        assertEq(ledger.poolDistributedTotal(poolId1), 600);
        assertEq(quoteToken.balanceOf(address(hook)), hookBalanceBefore + 600);
        assertTrue(ledger.isSolvent(quoteCurrency()));

        vm.prank(address(hook));
        vm.expectRevert(PayoutLedger.LedgerOverdraft.selector);
        ledger.releaseToHook(poolId1, 401);
    }

    function test_L6_accessControl() public {
        vm.startPrank(alice);
        uint256[4] memory sh = [uint256(1), 1, 1, 1];
        PoolId[4] memory p = [poolId1, poolId2, poolId1, poolId2];
        vm.expectRevert(PayoutLedger.OnlyHook.selector);
        ledger.onCapture(pairId, quoteCurrency(), alice, 0, p, sh);
        vm.expectRevert(PayoutLedger.OnlyHook.selector);
        ledger.releaseToHook(poolId1, 1);
        vm.stopPrank();
    }

    function test_L7_bindHookOnce() public {
        vm.expectRevert(PayoutLedger.HookAlreadyBound.selector);
        ledger.bindHook(address(1)); // already bound in setUp
    }
}
