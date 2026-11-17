// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, stdJson} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {RebateHook} from "../src/hook/RebateHook.sol";
import {PoolRegistry} from "../src/registry/PoolRegistry.sol";
import {PayoutLedger} from "../src/rewards/PayoutLedger.sol";
import {ILFund} from "../src/rewards/ILFund.sol";
import {SwapRouter} from "../src/periphery/SwapRouter.sol";
import {OrderBook} from "../src/periphery/OrderBook.sol";
import {SearcherRouter} from "../src/periphery/SearcherRouter.sol";

/// @notice Step 4 — V2 feature showcase on the live deployment:
///         A) conditional order: place a limit order on the dynamic-fee pool,
///            push the price through its trigger, fill it, and show the placer
///            earned a capture rebate on their own fill;
///         B) searcher network: leave divergence behind and let anyone capture
///            it through SearcherRouter for a commission;
///         C) LP yield engine: enable the IL carve-out, capture again, accrue
///            the seeded LP position and claim liquidity compensation.
contract DemoV2 is Script {
    using stdJson for string;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;

    function run() external {
        string memory f = vm.readFile("deployments/deployment.json");
        address base = f.readAddress(".baseToken");
        address quote = f.readAddress(".quoteToken");
        IPoolManager manager = IPoolManager(f.readAddress(".poolManager"));
        RebateHook hook = RebateHook(f.readAddress(".rebateHook"));
        PoolRegistry registry = PoolRegistry(f.readAddress(".registry"));
        PayoutLedger ledger = PayoutLedger(f.readAddress(".payoutLedger"));
        ILFund ilFund = ILFund(f.readAddress(".ilFund"));
        SwapRouter router = SwapRouter(f.readAddress(".swapRouter"));
        OrderBook orderBook = OrderBook(f.readAddress(".orderBook"));
        SearcherRouter searcherRouter = SearcherRouter(f.readAddress(".searcherRouter"));
        bytes32 pairId = f.readBytes32(".pairId");

        Currency baseC = Currency.wrap(base);
        Currency quoteC = Currency.wrap(quote);
        bool baseIsToken0 = base < quote;
        (Currency c0, Currency c1) = baseIsToken0 ? (baseC, quoteC) : (quoteC, baseC);

        // pool1 = static fee 500; pool2 = dynamic fee (as deployed)
        PoolKey memory key1 =
            PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))});
        PoolKey memory key2 =
            PoolKey({currency0: c0, currency1: c1, fee: 0x800000, tickSpacing: 60, hooks: IHooks(address(hook))});

        // swap directions: buying base = quote in; selling base = base in
        bool buyDir = Currency.unwrap(key2.currency0) == quote;
        bool sellDir = !buyDir;

        vm.startBroadcast();
        ERC20(base).approve(address(router), type(uint256).max);
        ERC20(quote).approve(address(router), type(uint256).max);
        ERC20(quote).approve(address(orderBook), type(uint256).max);

        // ================================================================ //
        // A) CONDITIONAL ORDER — limit-buy base ~1% below market on pool2   //
        // ================================================================ //
        (uint160 sqrtBefore,,, uint24 storedFee) = manager.getSlot0(key2.toId());
        console.log("=== A) CONDITIONAL ORDER ===");
        console.log("pool2 stored LP fee (dynamic base):", storedFee);

        // normalized base price (base per quote terms): invert when base is token1
        uint160 normBefore = baseIsToken0 ? sqrtBefore : uint160((1 << 192) / sqrtBefore);
        uint160 normTrigger = uint160(uint256(normBefore) * 99 / 100); // 1% below market
        // OrderBook works on the raw pool price: convert back
        uint160 rawTrigger = baseIsToken0 ? normTrigger : uint160((1 << 192) / normTrigger);
        bool fillAbove = !baseIsToken0; // base=t1: base cheap ⇔ raw price high

        uint256 orderId = orderBook.place(key2, buyDir, fillAbove, 1e18, 0, rawTrigger, 0);
        console.log("order placed:", orderId);
        assertFalse(orderBook.isCrossed(orderId), "order should start uncrossed");

        // push pool2 price DOWN through the trigger (sell base there, paused)
        registry.setSystemPaused(true);
        router.swapExactIn(key2, sellDir, 5e20, 0, type(uint64).max);
        registry.setSystemPaused(false);
        assertTrue(orderBook.isCrossed(orderId), "order should now be crossed");

        uint256 creditsBefore = ledger.traderCredits(msg.sender, quoteC);
        (uint256 amountOut, uint256 fillerReward) = orderBook.fill(orderId);
        console.log("fill output to placer (base):", amountOut - fillerReward);
        console.log("filler bounty (base):", fillerReward);
        require(ledger.traderCredits(msg.sender, quoteC) > creditsBefore, "placer earned no rebate on fill");
        console.log("placer capture rebate accrued:", ledger.traderCredits(msg.sender, quoteC) - creditsBefore);

        // ================================================================ //
        // B) SEARCHER NETWORK — capture leftover divergence for a bounty    //
        // ================================================================ //
        console.log("=== B) SEARCHER NETWORK ===");
        registry.setSystemPaused(true);
        router.swapExactIn(key1, buyDir, 1e20, 0, type(uint64).max); // skew pool1
        registry.setSystemPaused(false);

        uint256 capturedBefore = ledger.capturedTotal(quoteC);
        creditsBefore = ledger.traderCredits(msg.sender, quoteC);
        bytes32[] memory pairs = new bytes32[](1);
        pairs[0] = pairId;
        searcherRouter.submit(pairs);

        uint256 searched = ledger.capturedTotal(quoteC) - capturedBefore;
        uint256 commission = ledger.traderCredits(msg.sender, quoteC) - creditsBefore;
        console.log("searcher-captured profit:", searched);
        console.log("searcher commission (expect 10%):", commission);
        require(searched > 0, "searcher batch captured nothing");
        require(commission == searched * registry.getPair(pairId).params.searcherBps / 10_000, "commission mismatch");

        // ================================================================ //
        // C) LP YIELD ENGINE — IL carve-out funds liquidity compensation    //
        // ================================================================ //
        console.log("=== C) LP YIELD ENGINE (IL FUND) ===");
        PoolRegistry.PairParams memory p = registry.getPair(pairId).params;
        p.ilBps = 500; // 5% of the LP side
        registry.setPairParams(pairId, p);

        registry.setSystemPaused(true);
        router.swapExactIn(key1, buyDir, 1e20, 0, type(uint64).max);
        registry.setSystemPaused(false);

        uint256 ilBefore = ilFund.fundedTotal(quoteC);
        router.swapExactIn(key2, buyDir, 1e18, 0, type(uint64).max); // capture with IL carve
        uint256 ilFunded = ilFund.fundedTotal(quoteC) - ilBefore;
        console.log("IL fund inflow this capture:", ilFunded);
        require(ilFunded > 0, "IL carve-out did not fund");

        // the deployer seeded both pools via the router: accrue pool1's position
        // (owner = SwapRouter, salt = deployer address)
        ilFund.accrue(key1.toId(), address(router), MIN_TICK, MAX_TICK, bytes32(uint256(uint160(msg.sender))));
        console.log("stake registered:", ilFund.stakeTotal(key1.toId()));

        // second funded capture accrues against the stake, then claim
        registry.setSystemPaused(true);
        router.swapExactIn(key1, buyDir, 1e20, 0, type(uint64).max);
        registry.setSystemPaused(false);
        router.swapExactIn(key2, buyDir, 1e18, 0, type(uint64).max);

        uint256 quoteBefore = ERC20(quote).balanceOf(msg.sender);
        ilFund.accrue(key1.toId(), address(router), MIN_TICK, MAX_TICK, bytes32(uint256(uint160(msg.sender))));
        ilFund.claim(quoteC, msg.sender);
        console.log("IL compensation claimed:", ERC20(quote).balanceOf(msg.sender) - quoteBefore);
        assertTrue(ilFund.isSolvent(quoteC), "IL fund insolvent");

        console.log("=== V2 DEMO COMPLETE ===");
        console.log("hook totalCaptures:", hook.totalCaptures());
        vm.stopBroadcast();
    }

    function assertFalse(bool c, string memory m) internal pure {
        require(!c, m);
    }

    function assertTrue(bool c, string memory m) internal pure {
        require(c, m);
    }
}
