// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, stdJson} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {RebateHook} from "../src/hook/RebateHook.sol";
import {PoolRegistry} from "../src/registry/PoolRegistry.sol";
import {PayoutLedger} from "../src/rewards/PayoutLedger.sol";
import {SwapRouter} from "../src/periphery/SwapRouter.sol";

/// @notice Step 3 — end-to-end demo trade on the live deployment:
///         create divergence, BUY base in the cheap pool, verify the same-tx
///         capture (40% trader rebate, 60% LP side), distribute LP rewards,
///         and claim the trader rebate.
contract DemoTrade is Script {
    using stdJson for string;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    function run() external {
        string memory f = vm.readFile("deployments/deployment.json");
        address base = f.readAddress(".baseToken");
        address quote = f.readAddress(".quoteToken");
        RebateHook hook = RebateHook(f.readAddress(".rebateHook"));
        PoolRegistry registry = PoolRegistry(f.readAddress(".registry"));
        PayoutLedger ledger = PayoutLedger(f.readAddress(".payoutLedger"));
        SwapRouter router = SwapRouter(f.readAddress(".swapRouter"));
        bytes32 pairId = f.readBytes32(".pairId");

        (Currency c0, Currency c1) = Currency.unwrap(Currency.wrap(base)) < Currency.unwrap(Currency.wrap(quote))
            ? (Currency.wrap(base), Currency.wrap(quote))
            : (Currency.wrap(quote), Currency.wrap(base));
        // pool1 = static fee 500, pool2 = dynamic fee (as deployed in SetupDemoPair)
        PoolKey memory key1 =
            PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))});
        PoolKey memory key2 = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 0x800000, // DYNAMIC_FEE_FLAG — hook returns 3000/10000 per size
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        Currency quoteC = Currency.wrap(quote);
        Currency baseC = Currency.wrap(base);

        vm.startBroadcast();

        // ---- 1) skew pool1 vs pool2 while paused so no capture eats the gap ---- //
        registry.setSystemPaused(true);
        ERC20(quote).approve(address(router), type(uint256).max);
        bool buyDir = Currency.unwrap(key1.currency0) == quote; // quote in = buy base
        router.swapExactIn(key1, buyDir, 1e20, 0, type(uint64).max);
        registry.setSystemPaused(false);

        // ---- 2) the demo BUY in pool2: capture fires in the same transaction ---- //
        uint256 capturedBefore = ledger.capturedTotal(quoteC);
        uint256 out = router.swapExactIn(key2, buyDir, 1e18, 0, type(uint64).max);
        uint256 captured = ledger.capturedTotal(quoteC) - capturedBefore;

        uint256 traderCredit = ledger.traderCredits(msg.sender, quoteC);
        uint256 pool1Credit = ledger.poolCredits(key1.toId());
        uint256 pool2Credit = ledger.poolCredits(key2.toId());

        console.log("=== DEMO TRADE RESULT ===");
        console.log("base bought by trader:", out);
        console.log("captured profit:", captured);
        console.log("trader rebate accrued (expect 40%):", traderCredit);
        console.log("LP side pool1:", pool1Credit);
        console.log("LP side pool2:", pool2Credit);
        require(captured > 0, "no capture - check capture conditions");
        require(traderCredit == captured * 4000 / 10_000, "trader split mismatch");

        // ---- 3) distribute LP rewards of pool1 into the pool (donate) ---- //
        hook.distributePoolRewards(key1.toId());
        console.log("pool1 credit after distribution:", ledger.poolCredits(key1.toId()));

        // ---- 4) claim the trader rebate ---- //
        uint256 balBefore = ERC20(quote).balanceOf(msg.sender);
        ledger.claim(quoteC, msg.sender);
        console.log("rebate claimed:", ERC20(quote).balanceOf(msg.sender) - balBefore);

        // ---- 5) diagnostics ---- //
        console.log("hook totalCaptures:", hook.totalCaptures());
        console.log("lastCaptureProfit (int, quote units):", uint256(hook.lastCaptureProfit(pairId)));

        vm.stopBroadcast();
    }
}
