// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {PoolRegistry} from "../src/registry/PoolRegistry.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

contract PoolRegistryTest is BaseTest {
    using CurrencyLibrary for Currency;

    function test_R1_registerPair() public view {
        PoolRegistry.PairConfig memory cfg = registry.getPair(pairId);
        assertEq(Currency.unwrap(cfg.base), address(baseToken));
        assertEq(Currency.unwrap(cfg.quote), address(quoteToken));
        assertEq(cfg.params.traderShareBuyBps, 4000);
        assertEq(cfg.params.traderShareSellBps, 1000);
        assertEq(cfg.params.searcherBps, 1000);
        assertEq(cfg.params.ilBps, 0);
        assertEq(cfg.params.lpPool1Bps, 3500);
        assertEq(cfg.params.lpProtocol2Bps, 1500);
        assertEq(cfg.params.baseFee, 3000);
        assertEq(cfg.params.surgeFee, 10_000);
        assertEq(cfg.params.surgeThreshold, 1e21);
        assertTrue(registry.isPair(pairId));
    }

    function test_R2_duplicatePairReverts() public {
        vm.expectRevert(PoolRegistry.PairExists.selector);
        registry.registerPair(baseCurrency(), quoteCurrency());
    }

    function test_R3_badPairsRevert() public {
        vm.expectRevert(PoolRegistry.BadPair.selector);
        registry.registerPair(baseCurrency(), baseCurrency());
        vm.expectRevert(PoolRegistry.BadPair.selector);
        registry.registerPair(baseCurrency(), Currency.wrap(address(0x1)));
    }

    function test_R4_paramsValidation() public {
        PoolRegistry.PairConfig memory cfg = registry.getPair(pairId);
        PoolRegistry.PairParams memory p = cfg.params;
        p.lpPool1Bps = 3000; // sum 9500 != 10000
        vm.expectRevert(PoolRegistry.BadParams.selector);
        registry.setPairParams(pairId, p);

        p = registry.getPair(pairId).params; // fresh copy (expectRevert snapshots memory)
        p.traderShareBuyBps = 10_001;
        vm.expectRevert(PoolRegistry.BadParams.selector);
        registry.setPairParams(pairId, p);

        p = registry.getPair(pairId).params;
        p.maxRouteChecks = 0;
        vm.expectRevert(PoolRegistry.TooManyRouteChecks.selector);
        registry.setPairParams(pairId, p);

        // V2 fields: searcher commission, IL carve-out, dynamic-fee schedule
        p = registry.getPair(pairId).params;
        p.searcherBps = 10_001;
        vm.expectRevert(PoolRegistry.BadParams.selector);
        registry.setPairParams(pairId, p);

        p = registry.getPair(pairId).params;
        p.ilBps = 10_001;
        vm.expectRevert(PoolRegistry.BadParams.selector);
        registry.setPairParams(pairId, p);

        p = registry.getPair(pairId).params;
        p.surgeFee = 2999; // < baseFee 3000
        vm.expectRevert(PoolRegistry.BadParams.selector);
        registry.setPairParams(pairId, p);

        p = registry.getPair(pairId).params;
        p.baseFee = registry.MAX_LP_FEE() + 1;
        vm.expectRevert(PoolRegistry.BadParams.selector);
        registry.setPairParams(pairId, p);

        p = registry.getPair(pairId).params;
        p.surgeThreshold = 0;
        vm.expectRevert(PoolRegistry.BadParams.selector);
        registry.setPairParams(pairId, p);

        // valid update
        p = registry.getPair(pairId).params;
        p.minProfitQuote = 1e15;
        p.searcherBps = 500;
        p.ilBps = 500;
        registry.setPairParams(pairId, p);
        assertEq(registry.getPair(pairId).params.minProfitQuote, 1e15);
        assertEq(registry.getPair(pairId).params.searcherBps, 500);
        assertEq(registry.getPair(pairId).params.ilBps, 500);
    }

    function test_R6_attachAccessControl() public {
        vm.expectRevert(PoolRegistry.NotHook.selector);
        registry.attachPool(key1);
    }

    function test_R7_venueLifecycle() public {
        ExternalAMMPoolShim venue = new ExternalAMMPoolShim(baseCurrency(), quoteCurrency());
        registry.registerVenue(pairId, address(venue));
        assertEq(registry.venueCount(pairId), 1);
        assertEq(registry.venueAt(pairId, 0), address(venue));

        vm.expectRevert(PoolRegistry.BadVenue.selector); // duplicate
        registry.registerVenue(pairId, address(venue));

        ExternalAMMPoolShim other = new ExternalAMMPoolShim(Currency.wrap(address(0x99)), Currency.wrap(address(0x98)));
        vm.expectRevert(PoolRegistry.BadVenue.selector); // wrong pair
        registry.registerVenue(pairId, address(other));

        registry.removeVenue(pairId, address(venue));
        assertEq(registry.venueCount(pairId), 0);
        vm.expectRevert(PoolRegistry.VenueNotFound.selector);
        registry.removeVenue(pairId, address(venue));
    }

    function test_R7b_venueCap() public {
        for (uint256 i = 0; i < 4; i++) {
            ExternalAMMPoolShim venue = new ExternalAMMPoolShim(baseCurrency(), quoteCurrency());
            registry.registerVenue(pairId, address(venue));
        }
        ExternalAMMPoolShim fifth = new ExternalAMMPoolShim(baseCurrency(), quoteCurrency());
        vm.expectRevert(PoolRegistry.TooManyVenues.selector);
        registry.registerVenue(pairId, address(fifth));
    }

    function test_R8_pauses() public {
        registry.setSystemPaused(true);
        assertTrue(registry.systemPaused());
        registry.setSystemPaused(false);

        registry.setPairCapturePaused(pairId, true);
        assertTrue(registry.getPair(pairId).capturePaused);
        registry.setPairCapturePaused(pairId, false);

        registry.setDistributionPaused(true);
        assertTrue(registry.distributionPaused());
    }

    function test_R8b_hookEmergencyPause() public {
        vm.prank(address(hook));
        registry.emergencyPause();
        assertTrue(registry.systemPaused());
        vm.startPrank(alice);
        vm.expectRevert(PoolRegistry.NotHook.selector);
        registry.emergencyPause();
        vm.stopPrank();
    }

    function test_R5_thirdPoolIgnored() public {
        (Currency c0, Currency c1) = _sorted(baseCurrency(), quoteCurrency());
        PoolKey memory key3 =
            PoolKey({currency0: c0, currency1: c1, fee: 10_000, tickSpacing: 200, hooks: IHooks(address(hook))});
        manager.initialize(key3, SQRT_1_1); // slots full → ignored, no revert
        assertFalse(registry.isApprovedPool(key3.toId()));
    }
}

/// @notice minimal venue fixture exposing the right lens for registry validation
contract ExternalAMMPoolShim {
    Currency public immutable t0;
    Currency public immutable t1;

    constructor(Currency a, Currency b) {
        t0 = a;
        t1 = b;
    }

    function token0() external view returns (Currency) {
        return t0;
    }

    function token1() external view returns (Currency) {
        return t1;
    }

    function slot0() external pure returns (uint160) {
        return 0;
    }

    function liquidity() external pure returns (uint128) {
        return 0;
    }

    function swap(bool, int256, address, uint256) external pure returns (int256, int256) {
        revert("shim");
    }
}
