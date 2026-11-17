// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "v4-core/types/Currency.sol";

/// @notice Minimal external-venue lens required by the capture engine.
/// @dev Any AMM pool holding the same base/quote pair can integrate by exposing
///      v3-compatible state views plus an exact-input swap entry point.
interface IExternalVenue {
    function token0() external view returns (Currency);
    function token1() external view returns (Currency);

    /// @return sqrtPriceX96 current sqrt price (token1 per token0) as Q64.96
    function slot0() external view returns (uint160 sqrtPriceX96);

    /// @return liquidity active in-range liquidity (v3 convention)
    function liquidity() external view returns (uint128);

    /// @notice Exact-input swap; pulls `amountIn` of the input token from msg.sender
    ///         (standard ERC-20 allowance) and pushes the output to `recipient`.
    /// @param zeroForOne true = token0 in / token1 out
    /// @param amountSpecified negative exact-input amount (v3 convention)
    /// @param minOut minimum output accepted (reverts below)
    /// @return amount0 delta of token0 (negative when token0 is the input)
    /// @return amount1 delta of token1 (negative when token1 is the input)
    function swap(bool zeroForOne, int256 amountSpecified, address recipient, uint256 minOut)
        external
        returns (int256 amount0, int256 amount1);
}
