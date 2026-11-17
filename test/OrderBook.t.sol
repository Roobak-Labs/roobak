// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {OrderBook} from "../src/periphery/OrderBook.sol";
import {RebateHook} from "../src/hook/RebateHook.sol";
import {PayoutLedger} from "../src/rewards/PayoutLedger.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract OrderBookTest is BaseTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    OrderBook internal book;
    /// @notice a trigger just below the pools' 1.0 price (2^96)
    uint160 internal constant SQRT_1_1_LO = 791_000_000_000_000_000_000_000_000_00;

    function setUp() public override {
        super.setUp();
        book = new OrderBook(manager, registry, address(this));
    }

    // ---------------------------------------------------------------- //
    // OB-1: place escrows input; cancel refunds
    // ---------------------------------------------------------------- //
    function test_OB1_placeAndCancel() public {
        vm.startPrank(alice);
        quoteToken.approve(address(book), type(uint256).max);
        uint256 before = quoteToken.balanceOf(alice);
        uint256 id = book.place(key2, false, false, 1e18, 0, SQRT_1_1_LO, 0);
        assertEq(quoteToken.balanceOf(alice), before - 1e18, "input not escrowed");

        book.cancel(id);
        assertEq(quoteToken.balanceOf(alice), before, "escrow not refunded");
        vm.stopPrank();
        (,,,,,,,, uint8 st) = book.orders(id);
        assertEq(st, book.STATUS_CANCELLED());
    }

    // ---------------------------------------------------------------- //
    // OB-2: unknown pools are rejected
    // ---------------------------------------------------------------- //
    function test_OB2_unapprovedPoolRejected() public {
        // a third fee tier the registry never approved (pair slots are full)
        (Currency c0, Currency c1) = _sorted(baseCurrency(), quoteCurrency());
        PoolKey memory key3 =
            PoolKey({currency0: c0, currency1: c1, fee: 10_000, tickSpacing: 200, hooks: IHooks(address(hook))});
        manager.initialize(key3, SQRT_1_1); // attachPool ignores it (slots full)
        assertFalse(registry.isApprovedPool(key3.toId()));

        vm.startPrank(alice);
        quoteToken.approve(address(book), type(uint256).max);
        vm.expectRevert(OrderBook.BadPool.selector);
        book.place(key3, false, false, 1e18, 0, SQRT_1_1_LO, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- //
    // OB-3: not-crossed orders cannot be filled
    // ---------------------------------------------------------------- //
    function test_OB3_notCrossedReverts() public {
        vm.startPrank(alice);
        quoteToken.approve(address(book), type(uint256).max);
        // limit-buy with trigger far below market: not crossed yet
        uint256 id = book.place(key2, false, false, 1e18, 0, uint160(1 << 90), 0);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(OrderBook.NotCrossed.selector);
        book.fill(id);
    }

    // ---------------------------------------------------------------- //
    // OB-4: crossed limit order fills: placer gets output, filler gets bounty,
    //       and the placer earns a trader rebate when the fill creates a capture
    // ---------------------------------------------------------------- //
    function test_OB4_fillAndRebate() public {
        // make pool2 cheap vs pool1 and leave divergence in place
        registry.setSystemPaused(true);
        _sellBase(key2, 5e20, alice);
        registry.setSystemPaused(false);

        (uint160 sqrt,,,) = manager.getSlot0(poolId2);
        uint160 trigger = uint160(uint256(sqrt) * 1001 / 1000); // just above current price

        bool quoteIsToken0 = Currency.unwrap(key2.currency0) == Currency.unwrap(quoteCurrency());
        bool zeroForOne = quoteIsToken0; // quote in = zeroForOne iff quote is token0

        vm.startPrank(alice);
        quoteToken.approve(address(book), type(uint256).max);
        uint256 id = book.place(key2, zeroForOne, false, 1e18, 0, trigger, 0);
        vm.stopPrank();

        // trigger is above current price with fillBelow → crossed
        assertTrue(book.isCrossed(id), "order should be crossed");

        uint256 baseBefore = baseToken.balanceOf(alice);
        uint256 fillerBaseBefore = baseToken.balanceOf(bob);
        uint256 creditsBefore = ledger.traderCredits(alice, quoteCurrency());

        vm.prank(bob);
        (uint256 amountOut,) = book.fill(id);

        uint256 reward = amountOut * book.fillRewardBps() / 10_000;
        assertEq(baseToken.balanceOf(alice), baseBefore + amountOut - reward, "placer output wrong");
        assertEq(baseToken.balanceOf(bob), fillerBaseBefore + reward, "filler bounty wrong");
        (,,,,,,,, uint8 st2) = book.orders(id);
        assertEq(st2, book.STATUS_FILLED());

        // the fill swap itself created divergence between pool2 and pool1
        // (buying base in the cheap pool pushes it up) → capture credited alice
        assertGt(ledger.traderCredits(alice, quoteCurrency()), creditsBefore, "placer earned no rebate");
    }

    // ---------------------------------------------------------------- //
    // OB-5: expired orders cannot be filled, only cancelled
    // ---------------------------------------------------------------- //
    function test_OB5_expiredCannotFill() public {
        vm.warp(1000); // deterministic timestamps (default test time is 1)
        (uint160 sqrt,,,) = manager.getSlot0(poolId2);
        uint160 trigger = uint160(uint256(sqrt) * 999 / 1000);

        vm.startPrank(alice);
        quoteToken.approve(address(book), type(uint256).max);
        uint256 id = book.place(
            key2,
            Currency.unwrap(key2.currency0) == Currency.unwrap(quoteCurrency()),
            false,
            1e18,
            0,
            trigger,
            uint64(block.timestamp)
        );
        vm.stopPrank();

        vm.warp(block.timestamp + 1); // now past the deadline
        vm.prank(bob);
        vm.expectRevert(OrderBook.Expired.selector);
        book.fill(id);

        vm.prank(alice);
        book.cancel(id); // refund still possible
    }

    // ---------------------------------------------------------------- //
    // OB-6: minAmountOut is enforced on the placer's share
    // ---------------------------------------------------------------- //
    function test_OB6_minAmountOutGuard() public {
        registry.setSystemPaused(true);
        _sellBase(key2, 5e20, alice);
        registry.setSystemPaused(false);
        (uint160 sqrt,,,) = manager.getSlot0(poolId2);
        uint160 trigger = uint160(uint256(sqrt) * 1001 / 1000);

        vm.startPrank(alice);
        quoteToken.approve(address(book), type(uint256).max);
        uint256 id = book.place(
            key2,
            Currency.unwrap(key2.currency0) == Currency.unwrap(quoteCurrency()),
            false,
            1e18,
            type(uint256).max, // impossible minimum
            trigger,
            0
        );
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(OrderBook.TooLittleOutput.selector);
        book.fill(id);
    }
}
