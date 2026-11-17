// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, stdJson} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TestToken} from "../src/tokens/TestToken.sol";

import {RebateHook} from "../src/hook/RebateHook.sol";
import {PoolRegistry} from "../src/registry/PoolRegistry.sol";
import {PayoutLedger} from "../src/rewards/PayoutLedger.sol";
import {SwapRouter} from "../src/periphery/SwapRouter.sol";
import {ExternalAMMPool} from "../src/periphery/ExternalAMMPool.sol";

/// @notice Step 2 — demo pair setup: register pair, initialize the two hook pools
///         (auto-pairing), seed liquidity, register the external venue, fund the
///         hook working capital.
contract SetupDemoPair is Script {
    using stdJson for string;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint160 constant SQRT_1_1 = 79228162514264337593543950336; // 2^96
    int24 constant MIN_TICK = -887220;
    int24 constant MAX_TICK = 887220;
    uint256 constant SEED = 1e22;
    uint256 constant CAPITAL = 5e20;
    /// @notice v4 dynamic-fee flag — pool2 runs the hook's base/surge schedule
    uint24 constant DYNAMIC_FEE_FLAG = 0x800000;

    function run() external {
        string memory f = vm.readFile("deployments/deployment.json");
        IPoolManager manager = IPoolManager(f.readAddress(".poolManager"));
        address base = f.readAddress(".baseToken");
        address quote = f.readAddress(".quoteToken");
        RebateHook hook = RebateHook(f.readAddress(".rebateHook"));
        PoolRegistry registry = PoolRegistry(f.readAddress(".registry"));
        SwapRouter router = SwapRouter(f.readAddress(".swapRouter"));

        vm.startBroadcast();

        // 0) mint demo tokens to the deployer (idempotent fixture)
        TestToken(base).mint(msg.sender, 1e30);
        TestToken(quote).mint(msg.sender, 1e30);

        // 1) register the pair (idempotent)
        bytes32 pairId = registry.pairId(Currency.wrap(base), Currency.wrap(quote));
        if (!registry.isPair(pairId)) {
            registry.registerPair(Currency.wrap(base), Currency.wrap(quote));
        }

        // 2) initialize the paired pools (auto-paired by the hook; idempotent)
        (Currency c0, Currency c1) = Currency.unwrap(Currency.wrap(base)) < Currency.unwrap(Currency.wrap(quote))
            ? (Currency.wrap(base), Currency.wrap(quote))
            : (Currency.wrap(quote), Currency.wrap(base));
        PoolKey memory key1 =
            PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))});
        // dynamic-fee pool: base 3000 / surge 10000 (registry defaults)
        PoolKey memory key2 = PoolKey({
            currency0: c0, currency1: c1, fee: DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        try manager.initialize(key1, SQRT_1_1) {} catch (bytes memory) {}
        try manager.initialize(key2, SQRT_1_1) {} catch (bytes memory) {}

        // 3) seed liquidity (full range) via the router
        ERC20(base).approve(address(router), type(uint256).max);
        ERC20(quote).approve(address(router), type(uint256).max);
        router.addLiquidity(key1, MIN_TICK, MAX_TICK, SEED, SEED, 0, type(uint64).max);
        router.addLiquidity(key2, MIN_TICK, MAX_TICK, SEED, SEED, 0, type(uint64).max);

        // 4) external venue: base cheap there (~0.952 quote per base) vs pools at 1.0
        ExternalAMMPool venue = new ExternalAMMPool(Currency.wrap(base), Currency.wrap(quote), 30, msg.sender);
        ERC20(base).approve(address(venue), type(uint256).max);
        ERC20(quote).approve(address(venue), type(uint256).max);
        venue.seed(1.05e22, 1e22); // token0-side (quote) , token1-side (base)
        registry.registerVenue(pairId, address(venue));
        hook.approveVenue(Currency.wrap(base), Currency.wrap(quote), address(venue));

        // 5) fund hook working capital
        ERC20(quote).approve(address(hook), type(uint256).max);
        hook.fundWorkingCapital(Currency.wrap(quote), CAPITAL);

        vm.stopBroadcast();

        // record
        string memory json = "all";
        vm.serializeAddress(json, "deployer", f.readAddress(".deployer"));
        vm.serializeAddress(json, "wrappedNative", f.readAddress(".wrappedNative"));
        vm.serializeAddress(json, "baseToken", base);
        vm.serializeAddress(json, "quoteToken", quote);
        vm.serializeAddress(json, "poolManager", address(manager));
        vm.serializeAddress(json, "permit2", f.readAddress(".permit2"));
        vm.serializeAddress(json, "stateView", f.readAddress(".stateView"));
        vm.serializeAddress(json, "quoter", f.readAddress(".quoter"));
        vm.serializeAddress(json, "positionDescriptor", f.readAddress(".positionDescriptor"));
        vm.serializeAddress(json, "positionManager", f.readAddress(".positionManager"));
        vm.serializeAddress(json, "registry", address(registry));
        vm.serializeAddress(json, "create2Factory", f.readAddress(".create2Factory"));
        vm.serializeAddress(json, "payoutLedger", f.readAddress(".payoutLedger"));
        vm.serializeAddress(json, "ilFund", f.readAddress(".ilFund"));
        vm.serializeAddress(json, "rebateHook", address(hook));
        vm.serializeBytes32(json, "hookSalt", f.readBytes32(".hookSalt"));
        vm.serializeAddress(json, "swapRouter", address(router));
        vm.serializeAddress(json, "orderBook", f.readAddress(".orderBook"));
        vm.serializeAddress(json, "searcherRouter", f.readAddress(".searcherRouter"));
        vm.serializeAddress(json, "batchAuctionPool", f.readAddress(".batchAuctionPool"));
        vm.serializeAddress(json, "externalVenue", address(venue));
        vm.serializeBytes32(json, "pairId", pairId);
        vm.serializeBytes32(json, "poolId1", PoolId.unwrap(key1.toId()));
        string memory out = vm.serializeBytes32(json, "poolId2", PoolId.unwrap(key2.toId()));
        vm.writeJson(out, "deployments/deployment.json");

        console.log("PairId:", uint256(pairId));
        console.log("Pool1 (fee 500):", uint256(PoolId.unwrap(key1.toId())));
        console.log("Pool2 (dynamic fee):", uint256(PoolId.unwrap(key2.toId())));
        console.log("ExternalVenue:", address(venue));
    }
}
