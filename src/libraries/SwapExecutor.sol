// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IExternalVenue} from "../interfaces/IExternalVenue.sol";
import {RouteChecker} from "./RouteChecker.sol";

/// @title SwapExecutor — protected cycle execution.
/// @notice Mirrors the reference architecture's "Executor": runs the price-correction
///         trade and closes all balances in one protected process. Every leg is an
///         exact-input swap; outputs are pulled to the hook wallet immediately
///         (v4 `take`) and inputs are paid per-leg (v4 `settle`), so the hook's
///         PoolManager deltas are zero by the time the cycle ends.
/// @dev Library functions execute in the calling hook's context: `msg.sender` seen
///      by the PoolManager / venues is the hook itself.
library SwapExecutor {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Slippage haircut applied to the estimate when protecting external
    ///         venue legs with a minOut (realized measurement remains the real guard).
    uint256 internal constant EXTERNAL_LEG_MIN_OUT_BPS = 7000; // 70% of estimate

    error ZeroOutput();
    error LegFailed();

    // ------------------------------------------------------------------ //
    //                              Cycle                                  //
    // ------------------------------------------------------------------ //

    /// @notice Execute one quote-first cycle: buy base on the cheap venue, sell ALL
    ///         of it on the rich venue. Base balance is neutral by construction;
    ///         profit equals the hook wallet's realized quote delta.
    /// @return baseBought base tokens acquired on the cheap leg (== sold on rich leg)
    /// @return minQuoteOutSellLeg protective floor used on the rich external leg
    function executeCycle(
        IPoolManager manager,
        RouteChecker.VenueState memory cheap,
        RouteChecker.VenueState memory rich,
        RouteChecker.CyclePlan memory plan,
        Currency base,
        Currency quote,
        uint256 baseBalanceStart
    ) internal returns (uint256 baseBought, uint256 minQuoteOutSellLeg) {
        // ---- leg 1: quote -> base on the cheap venue ------------------- //
        baseBought = _leg(manager, cheap, quote, plan.sizeQuote, base, 0);

        // ---- leg 2: base -> quote on the rich venue --------------------- //
        // protective floor for external rich legs: the sell must return at least
        // 70% of what the buy leg paid (we expect MORE than cost + spread; the
        // realized-profit measurement remains the true guard)
        minQuoteOutSellLeg = 0;
        if (rich.kind == 1) {
            minQuoteOutSellLeg = plan.sizeQuote * EXTERNAL_LEG_MIN_OUT_BPS / 10_000;
        }
        // sell ALL bought base: base balance is neutral by construction; the hook
        // still verifies neutrality against its own snapshot after the cycle
        _leg(manager, rich, base, baseBought, quote, minQuoteOutSellLeg);
        baseBalanceStart; // snapshot check performed by the hook (kept for interface clarity)
    }

    // ------------------------------------------------------------------ //
    //                                Legs                                 //
    // ------------------------------------------------------------------ //

    /// @notice One exact-input leg. Returns the output amount landed in the hook wallet.
    function _leg(
        IPoolManager manager,
        RouteChecker.VenueState memory v,
        Currency currencyIn,
        uint256 amountIn,
        Currency currencyOut,
        uint256 minOut
    ) private returns (uint256 amountOut) {
        if (v.kind == 0) {
            amountOut = _v4Leg(manager, v.key, currencyIn, amountIn, currencyOut);
        } else {
            amountOut = _externalLeg(IExternalVenue(v.venue), currencyIn, amountIn, currencyOut, minOut);
        }
        if (amountOut == 0) revert ZeroOutput();
    }

    /// @dev Exact-input swap on a v4 pool: swap → pay input (transfer+settle) →
    ///      take output to the hook wallet.
    function _v4Leg(
        IPoolManager manager,
        PoolKey memory key,
        Currency currencyIn,
        uint256 amountIn,
        Currency currencyOut
    ) private returns (uint256 amountOut) {
        bool zeroForOne = Currency.unwrap(currencyIn) == Currency.unwrap(key.currency0);
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta delta = manager.swap(key, params, "");

        // pay what we owe: sync → transfer → settle (ERC20 only; pairs are ERC20)
        manager.sync(currencyIn);
        ERC20(Currency.unwrap(currencyIn)).transfer(address(manager), amountIn);
        manager.settle();

        // withdraw what we are owed, straight to the hook wallet
        int128 outDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (outDelta <= 0) revert ZeroOutput();
        amountOut = uint128(outDelta);
        manager.take(currencyOut, address(this), amountOut);
    }

    /// @dev Exact-input swap on an external venue. The venue pulls the input via
    ///      ERC-20 allowance (hook pre-approves registered venues) and pushes the
    ///      output to the hook wallet.
    function _externalLeg(
        IExternalVenue venue,
        Currency currencyIn,
        uint256 amountIn,
        Currency currencyOut,
        uint256 minOut
    ) private returns (uint256 amountOut) {
        bool zeroForOne = Currency.unwrap(currencyIn) == Currency.unwrap(venue.token0());
        (int256 a0, int256 a1) = venue.swap(zeroForOne, -int256(amountIn), address(this), minOut);
        int256 outDelta = zeroForOne ? a1 : a0;
        if (outDelta <= 0) revert ZeroOutput();
        amountOut = uint256(outDelta);
        // the output token is already pushed to the hook wallet by the venue
    }
}
