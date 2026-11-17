// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RouteChecker} from "../src/libraries/RouteChecker.sol";

contract RouteCheckerTest is Test {
    using RouteChecker for *;

    uint160 constant S0 = 79228162514264337593543950336; // 2^96, price 1
    uint128 constant L = 1e22;

    function test_RC1_equalPricesNoRoute() public pure {
        (uint256 size, int256 est) = RouteChecker.estimatePair(S0, L, S0, L);
        assertEq(size, 0);
        assertEq(est, 0);
    }

    function test_RC2_divergenceYieldsPositivePlan() public {
        uint160 sRich = uint160(uint256(S0) * 1005 / 1000); // +0.5% sqrt → ~1% price
        (uint256 size, int256 est) = RouteChecker.estimatePair(S0, L, sRich, L);
        assertGt(size, 0);
        assertGt(est, 0);

        // direction: swapped arguments must also work (rich first)
        (uint256 size2, int256 est2) = RouteChecker.estimatePair(sRich, L, S0, L);
        assertEq(size2, 0, "estimatePair expects cheap first");
        assertEq(est2, 0);
    }

    function test_RC3_caps() public {
        uint160 sRich = uint160(uint256(S0) * 1100 / 1000); // +10% sqrt
        (uint256 size,) = RouteChecker.estimatePair(S0, L, sRich, L);
        uint256 lq = RouteChecker.quoteLiquidity(S0, L);

        // absolute cap binds
        uint256 capped = RouteChecker.capSize(size, 1e18, lq, lq, 25);
        assertEq(capped, 1e18);

        // liquidity-proportional cap binds
        capped = RouteChecker.capSize(size, type(uint256).max, lq, lq, 25);
        assertEq(capped, lq * 25 / 10_000);
    }

    function test_RC4_planSelectionPicksBest() public pure {
        RouteChecker.VenueState[] memory states = new RouteChecker.VenueState[](3);
        states[0] = _venue(S0, L);
        states[1] = _venue(uint160(uint256(S0) * 1002 / 1000), L); // +0.2%
        states[2] = _venue(uint160(uint256(S0) * 1010 / 1000), L); // +1.0%

        RouteChecker.CyclePlan memory plan = RouteChecker.planBestCycle(states, 0);
        // best spread is states[0] (cheap) → states[2] (rich)
        assertEq(plan.cheapIdx, 0);
        assertEq(plan.richIdx, 2);
        assertGt(uint256(plan.estProfitQuote), 0);
    }

    function test_RC5_monotonicityFuzz(uint64 bump) public pure {
        bump = uint64(bump % 50_000); // up to 5% sqrt bump in bps
        if (bump == 0) return;
        uint160 sRich = uint160(uint256(S0) * (100_000 + bump) / 100_000);
        (, int256 est1) = RouteChecker.estimatePair(S0, L, sRich, L);
        uint160 sRicher = uint160(uint256(S0) * (100_000 + bump * 2) / 100_000);
        (, int256 est2) = RouteChecker.estimatePair(S0, L, sRicher, L);
        assertGe(est2, est1, "wider divergence should not reduce estimated profit");
    }

    function test_RC6_normalizeInverts() public {
        uint160 s = uint160(uint256(S0) * 3 / 2);
        // base == token1 → invert: 2^192 / s
        uint160 inv = RouteChecker.normalizeSqrt(s, false);
        assertApproxEqRel(uint256(inv) * s, 1 << 192, 1e15); // ~0.1% tolerance
        // base == token0 → identity, capped
        assertEq(RouteChecker.normalizeSqrt(s, true), s);
        // oversized prices normalize to 0 (skipped)
        assertEq(RouteChecker.normalizeSqrt(uint160(1 << 128), true), 0);
    }

    function test_RC7_unsafeMagnitudesReturnZero() public pure {
        // liquidity beyond guard → skipped, not reverted
        (uint256 size, int256 est) = RouteChecker.estimatePair(S0, uint128(1 << 124), S0, L);
        assertEq(size, 0);
        assertEq(est, 0);
        // zero liquidity → skipped
        (size, est) = RouteChecker.estimatePair(S0, 0, S0, L);
        assertEq(size, 0);
    }

    function _venue(uint160 s, uint128 l) internal pure returns (RouteChecker.VenueState memory) {
        // struct fields key/venue left default — planBestCycle only uses price/liquidity
        RouteChecker.VenueState memory v;
        v.sqrtPriceX96 = s;
        v.liquidity = l;
        return v;
    }
}
