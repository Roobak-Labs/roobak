// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @title RouteChecker — bounded route enumeration & closed-form profit estimation.
/// @notice Mirrors the reference architecture's "Route checker": looks at a limited
///         set of paths and estimates whether a safe profit exists. Pure math only —
///         never executes anything, never pays on estimates.
/// @dev All venue sqrt prices passed in must already be normalized to the
///      "quote per base" orientation via `normalizeSqrt`. All price/liquidity
///      magnitudes are guarded so intermediates fit `Math.mulDiv` precision.
library RouteChecker {
    // ------------------------------------------------------------------ //
    //                          Types & constants                          //
    // ------------------------------------------------------------------ //

    /// @notice Snapshot of one venue's state used for estimation.
    struct VenueState {
        uint160 sqrtPriceX96; // normalized: sqrt(quote/base) as Q64.96
        uint128 liquidity; // active liquidity
        uint8 kind; // 0 = v4 pool, 1 = external venue
        PoolKey key; // v4 key (empty for external venues)
        address venue; // external venue address (0 for v4 pools)
    }

    /// @notice A planned, capped cycle ready for execution.
    struct CyclePlan {
        uint256 sizeQuote; // exact-input quote size
        int256 estProfitQuote; // estimate — gate only, never paid on
        uint8 cheapIdx; // venue index to buy base in
        uint8 richIdx; // venue index to sell base in
    }

    /// @notice Safety guards on magnitudes (docs/04 §4.3).
    uint160 internal constant MIN_SQRT = 1 << 32;
    uint160 internal constant MAX_SQRT = 1 << 127;
    uint128 internal constant MAX_LIQUIDITY = 1 << 120;

    // ------------------------------------------------------------------ //
    //                          Orientation math                           //
    // ------------------------------------------------------------------ //

    /// @notice Convert a venue's raw sqrtPriceX96 (sqrt(token1/token0)) into the
    ///         normalized sqrt(quote/base) view.
    /// @param raw venue sqrtPriceX96
    /// @param baseIsToken0 true when the base token is the venue's token0
    /// @return normalized sqrt(quote/base), 0 when unsafe to invert
    function normalizeSqrt(uint160 raw, bool baseIsToken0) internal pure returns (uint160) {
        if (baseIsToken0) {
            return raw <= MAX_SQRT ? raw : 0;
        }
        // invert: 2^192 / raw  (both are Q64.96 quantities)
        if (raw <= MIN_SQRT) return 0;
        uint256 inv = Math.mulDiv(1 << 192, 1, raw);
        return inv <= MAX_SQRT ? uint160(inv) : 0;
    }

    /// @notice Quote-side depth of a venue: y ≈ L·s / 2^96 (v3 convention).
    function quoteLiquidity(uint160 s, uint128 l) internal pure returns (uint256) {
        return Math.mulDiv(l, s, 1 << 96);
    }

    // ------------------------------------------------------------------ //
    //                            Core estimation                          //
    // ------------------------------------------------------------------ //

    /// @notice Two-venue equalization: both venues converge to a common sqrt price m
    ///         with matched base flows:
    ///             Lc·(m − sc)/(sc·m)  =  Lr·(sr − m)/(sr·m)
    ///         =>  m = sc·sr·(Lc + Lr) / (Lc·sr + Lr·sc)
    ///         size (quote in)      y  = Lc·(m − sc)/2^96
    ///         est. quote out at rich  y' = Lr·(sr − m)/2^96
    ///         estProfit = y' − y   (positive iff sr > sc)
    function estimatePair(uint160 sc, uint128 lc, uint160 sr, uint128 lr)
        internal
        pure
        returns (uint256 sizeQuote, int256 estProfitQuote)
    {
        if (lc == 0 || lr == 0) return (0, 0);
        if (!_isSafe(sc, lc) || !_isSafe(sr, lr)) return (0, 0);

        uint256 m = targetSqrt(sc, lc, sr, lr);
        if (m <= sc || m >= sr) return (0, 0);

        sizeQuote = Math.mulDiv(lc, m - sc, 1 << 96);
        uint256 quoteOut = Math.mulDiv(lr, sr - m, 1 << 96);
        estProfitQuote = int256(quoteOut) - int256(sizeQuote);
    }

    function _isSafe(uint160 s, uint128 l) private pure returns (bool) {
        return s >= MIN_SQRT && s <= MAX_SQRT && l <= MAX_LIQUIDITY;
    }

    /// @dev Common target: m = sc·sr·(Lc + Lr) / (Lc·sr + Lr·sc)
    ///      inputs ≤ 2^127 each / 2^120 for L — every mulDiv input fits uint256 and
    ///      the result ≤ 2^127.
    function targetSqrt(uint256 sc, uint256 lc, uint256 sr, uint256 lr) internal pure returns (uint256) {
        // split the products so every mulDiv INPUT fits uint256 and the final
        // result stays <= 2^127:
        //   m = sc·sr·(Lc+Lr) / (Lc·sr + Lr·sc)
        uint256 num = Math.mulDiv(sr, lc + lr, 1); // sr·(Lc+Lr) <= 2^248
        uint256 den = Math.mulDiv(lc, sr, 1) + Math.mulDiv(lr, sc, 1); // <= 2^249
        return Math.mulDiv(sc, num, den); // 512-bit intermediate, result <= 2^127
    }

    /// @notice L·Δs / 2^96 — quote delta for a liquidity·sqrt-price move (v3 convention).
    function mulDiv96(uint256 l, uint256 dS) internal pure returns (uint256) {
        return Math.mulDiv(l, dS, 1 << 96);
    }

    /// @notice L·2^96·(1/sc − 1/m) — base out when quote `y = mulDiv96(l, m − sc)`
    ///         moves the venue from sc to m.
    function baseOutForQuote(uint128 l, uint160 sc, uint160 m) internal pure returns (uint256) {
        if (m <= sc) return 0;
        uint256 num = Math.mulDiv(l, m - sc, 1); // ≤ 2^247
        return Math.mulDiv(num, 1 << 96, uint256(sc) * m); // denominator ≤ 2^254
    }

    // ------------------------------------------------------------------ //
    //                          Route planning                            //
    // ------------------------------------------------------------------ //

    /// @notice Best-cycle plan over the assembled (bounded) venue states.
    /// @dev `states[0]` is the v4 pool being swapped; the rest are its pair partner
    ///      and/or external venues. Estimates every (cheap, rich) combination — the
    ///      state count is bounded by the caller (registry.maxRouteChecks).
    ///      A cycle mixes v4 and external venues freely; two v4 states make the
    ///      classic paired-pool backrun.
    function planBestCycle(VenueState[] memory states, uint256 minProfitQuote)
        internal
        pure
        returns (CyclePlan memory best)
    {
        uint256 n = states.length;
        if (n < 2) return best;

        for (uint256 i = 0; i < n; i++) {
            if (states[i].liquidity == 0 || states[i].sqrtPriceX96 == 0) continue;
            for (uint256 j = 0; j < n; j++) {
                if (i == j) continue;
                if (states[j].liquidity == 0 || states[j].sqrtPriceX96 == 0) continue;
                if (states[j].sqrtPriceX96 <= states[i].sqrtPriceX96) continue; // j must be rich

                (uint256 size, int256 est) = estimatePair(
                    states[i].sqrtPriceX96, states[i].liquidity, states[j].sqrtPriceX96, states[j].liquidity
                );
                if (size == 0 || est <= int256(minProfitQuote)) continue;
                if (best.sizeQuote == 0 || est > best.estProfitQuote) {
                    best = CyclePlan({sizeQuote: size, estProfitQuote: est, cheapIdx: uint8(i), richIdx: uint8(j)});
                }
            }
        }
    }

    // ------------------------------------------------------------------ //
    //                                Caps                                 //
    // ------------------------------------------------------------------ //

    /// @notice Apply the absolute and liquidity-proportional caps to a plan size.
    function capSize(uint256 size, uint256 maxAbs, uint256 lqCheap, uint256 lqRich, uint16 bpsOfLiq)
        internal
        pure
        returns (uint256)
    {
        uint256 byLiquidity = Math.mulDiv(Math.min(lqCheap, lqRich), bpsOfLiq, 10_000);
        uint256 cap = Math.min(maxAbs, byLiquidity);
        return size > cap ? cap : size;
    }
}
