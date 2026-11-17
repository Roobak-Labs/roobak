// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {StateView} from "v4-periphery/lens/StateView.sol";

import {WrappedNative} from "../src/tokens/WrappedNative.sol";
import {TestToken} from "../src/tokens/TestToken.sol";

/// @notice Step 0 — deploy a local Uniswap v4 stack + support tokens on
///         the target chain and record all addresses to
///         deployments/deployment.json.
contract DeployInfrastructure is Script {
    function run() external returns (address manager, address wnt) {
        vm.startBroadcast();

        // ---- support tokens ---- //
        wnt = address(new WrappedNative());
        address baseToken = address(new TestToken("Demo Base Token", "DBASE", 18));
        address quoteToken = address(new TestToken("Demo Quote Token", "DQUOTE", 18));

        // ---- v4 core ---- //
        manager = address(new PoolManager(msg.sender));

        // ---- v4 periphery: StateView (lens). V4Quoter/PositionManager track a newer
        //      v4-core than the audited v4.0.0 used here; deploy them separately if
        //      needed — the protocol system does not depend on them. ---- //
        address stateView = address(new StateView(PoolManager(manager)));

        vm.stopBroadcast();

        // ---- record ---- //
        string memory json = "infrastructure";
        vm.serializeAddress(json, "deployer", msg.sender);
        vm.serializeAddress(json, "wrappedNative", wnt);
        vm.serializeAddress(json, "baseToken", baseToken);
        vm.serializeAddress(json, "quoteToken", quoteToken);
        vm.serializeAddress(json, "poolManager", manager);
        vm.serializeAddress(json, "permit2", address(0));
        vm.serializeAddress(json, "stateView", stateView);
        vm.serializeAddress(json, "quoter", address(0));
        vm.serializeAddress(json, "positionDescriptor", address(0));
        string memory out = vm.serializeAddress(json, "positionManager", address(0));
        vm.writeJson(out, "deployments/deployment.json");

        console.log("WrappedNative:", wnt);
        console.log("BaseToken:", baseToken);
        console.log("QuoteToken:", quoteToken);
        console.log("PoolManager:", manager);
        console.log("StateView:", stateView);
    }
}
