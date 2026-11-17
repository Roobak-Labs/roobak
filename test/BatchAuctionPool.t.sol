// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BatchAuctionPool} from "../src/periphery/BatchAuctionPool.sol";
import {TestToken} from "../src/tokens/TestToken.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

/// @notice standalone suite — the venue does not depend on the v4 stack
contract BatchAuctionPoolTest is Test {
    using CurrencyLibrary for Currency;

    TestToken internal token0; // lower address
    TestToken internal token1;
    BatchAuctionPool internal pool;

    function setUp() public {
        TestToken a = new TestToken("A", "A", 18);
        TestToken b = new TestToken("B", "B", 18);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        pool = new BatchAuctionPool(c0(), c1(), 30, address(this));

        token0.mint(address(this), 1e24);
        token1.mint(address(this), 1e24);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        pool.seed(1e22, 1e22); // 1:1
    }

    function c0() internal view returns (Currency) {
        return Currency.wrap(address(token0));
    }

    function c1() internal view returns (Currency) {
        return Currency.wrap(address(token1));
    }

    // ---------------------------------------------------------------- //
    // BA-1: immediate venue swap works (IExternalVenue interface)
    // ---------------------------------------------------------------- //
    function test_BA1_immediateSwap() public {
        (uint256 r0b, uint256 r1b) = pool.getReserves();
        pool.swap(true, -int256(1e18), address(this), 0);
        (uint256 r0a, uint256 r1a) = pool.getReserves();
        assertGt(r0a, r0b);
        assertLt(r1a, r1b);
        assertGt(pool.slot0(), 0);
        assertGt(pool.liquidity(), 0);
    }

    // ---------------------------------------------------------------- //
    // BA-2: opposing orders settle at one uniform clearing price
    // ---------------------------------------------------------------- //
    function test_BA2_uniformClearingPrice() public {
        uint256 idA = pool.submitOrder(true, 1e20, 0); // sell token0 for token1
        uint256 idB = pool.submitOrder(false, 1e20, 0); // sell token1 for token0

        vm.warp(block.timestamp + 61);
        pool.settle();

        // both filled; a perfectly matched batch leaves reserves ~unchanged
        // (the internal match trades fee-free at ~spot)
        (,,,, uint8 statusA) = pool.batchOrders(idA);
        (,,,, uint8 statusB) = pool.batchOrders(idB);
        assertEq(uint256(statusA), 1, "order A not filled");
        assertEq(uint256(statusB), 1, "order B not filled");
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertApproxEqRel(r0, 1e22, 1e15);
        assertApproxEqRel(r1, 1e22, 1e15);
    }

    // ---------------------------------------------------------------- //
    // BA-3: one-sided batch trades into the pool at the net clearing price
    // ---------------------------------------------------------------- //
    function test_BA3_oneSidedBatch() public {
        uint256 outBefore = token1.balanceOf(address(this));
        pool.submitOrder(true, 1e20, 0); // only token0 sellers

        vm.warp(block.timestamp + 61);
        pool.settle();

        uint256 out = token1.balanceOf(address(this)) - outBefore;
        assertGt(out, 0, "seller received nothing");
        // uniform price must be at or below spot for a token0-sell batch
        (uint256 r0, uint256 r1) = pool.getReserves();
        assertGt(r0, 1e22);
        assertLt(r1, 1e22);
    }

    // ---------------------------------------------------------------- //
    // BA-4: minOut violators are refunded, fillers are paid
    // ---------------------------------------------------------------- //
    function test_BA4_minOutRefund() public {
        uint256 t0Before = token0.balanceOf(address(this));
        uint256 idFill = pool.submitOrder(true, 1e20, 0);
        uint256 idRefund = pool.submitOrder(true, 1e20, type(uint256).max); // impossible minOut

        vm.warp(block.timestamp + 61);
        pool.settle();

        (,,,, uint8 statusFill) = pool.batchOrders(idFill);
        (,,,, uint8 statusRefund) = pool.batchOrders(idRefund);
        assertEq(uint256(statusFill), 1, "good order not filled");
        assertEq(uint256(statusRefund), 2, "bad order not refunded");
        // the refunded order's tokens came back (minus nothing)
        assertApproxEqRel(token0.balanceOf(address(this)), t0Before - 1e20, 1e15);
    }

    // ---------------------------------------------------------------- //
    // BA-5: settle reverts before the deadline; cancel works while open
    // ---------------------------------------------------------------- //
    function test_BA5_settleAndCancelGuards() public {
        uint256 id = pool.submitOrder(true, 1e20, 0);
        vm.expectRevert(BatchAuctionPool.BatchStillOpen.selector);
        pool.settle();

        pool.cancel(id);
        (,,,, uint8 status) = pool.batchOrders(id);
        assertEq(uint256(status), 3);
    }
}
