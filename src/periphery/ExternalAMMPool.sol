// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IExternalVenue} from "../interfaces/IExternalVenue.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

/// @title ExternalAMMPool — generic constant-product external venue.
/// @notice Implements the v3-style lens the capture engine expects (`slot0`,
///         `liquidity`, `swap`), so the hook can arbitrage divergence between its
///         paired v4 pools and this venue — the role external AMM pools (e.g. v3)
///         play in the reference system. Not a production AMM: no LP tokens,
///         owner-seeded liquidity only.
contract ExternalAMMPool is IExternalVenue {
    using CurrencyLibrary for Currency;

    uint256 public constant BPS = 10_000;

    Currency public immutable token0_;
    Currency public immutable token1_;
    uint256 public immutable feeBps;
    address public immutable owner;

    uint256 private reserve0;
    uint256 private reserve1;

    error NotOwner();
    error BadAmount();
    error ExactInputOnly();
    error TooLittleOutput();
    error ZeroReserves();
    error TransferFailed();

    event Seed(uint256 amount0, uint256 amount1);
    event Drain(uint256 amount0, uint256 amount1);
    event Swap(address indexed caller, address indexed recipient, uint256 amountIn, uint256 amountOut, bool zeroForOne);

    constructor(Currency tokenA, Currency tokenB, uint256 feeBps_, address owner_) {
        require(
            !tokenA.isAddressZero() && !tokenB.isAddressZero() && Currency.unwrap(tokenA) != Currency.unwrap(tokenB),
            "bad tokens"
        );
        (token0_, token1_) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        feeBps = feeBps_;
        owner = owner_;
    }

    // ------------------------------------------------------------------ //
    //                            Venue lens                               //
    // ------------------------------------------------------------------ //

    function token0() external view returns (Currency) {
        return token0_;
    }

    function token1() external view returns (Currency) {
        return token1_;
    }

    /// @return sqrtPriceX96 sqrt(token1/token0) as Q64.96
    function slot0() external view returns (uint160) {
        if (reserve0 == 0 || reserve1 == 0) return 0;
        // sqrt(r1)·2^96 / sqrt(r0)
        return uint160(Math.mulDiv(Math.sqrt(reserve1), 1 << 96, Math.sqrt(reserve0)));
    }

    /// @return liquidity sqrt(r0·r1) — v3-style active liquidity
    function liquidity() external view returns (uint128) {
        if (reserve0 == 0 || reserve1 == 0) return 0;
        return uint128(Math.sqrt(reserve0 * reserve1));
    }

    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    // ------------------------------------------------------------------ //
    //                              Swap                                   //
    // ------------------------------------------------------------------ //

    /// @notice Exact-input swap; pulls input via ERC-20 allowance, pushes output.
    function swap(bool zeroForOne, int256 amountSpecified, address recipient, uint256 minOut)
        external
        returns (int256 amount0, int256 amount1)
    {
        if (amountSpecified >= 0) revert ExactInputOnly();
        uint256 amountIn = uint256(-amountSpecified);
        if (amountIn == 0) revert BadAmount();
        if (reserve0 == 0 || reserve1 == 0) revert ZeroReserves();

        (uint256 rIn, uint256 rOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
        uint256 inAfterFee = amountIn * (BPS - feeBps) / BPS;
        uint256 amountOut = rOut * inAfterFee / (rIn + inAfterFee);
        if (amountOut < minOut || amountOut >= rOut) revert TooLittleOutput();

        Currency inToken = zeroForOne ? token0_ : token1_;
        Currency outToken = zeroForOne ? token1_ : token0_;

        ERC20(Currency.unwrap(inToken)).transferFrom(msg.sender, address(this), amountIn);
        ERC20(Currency.unwrap(outToken)).transfer(recipient, amountOut);

        if (zeroForOne) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        emit Swap(msg.sender, recipient, amountIn, amountOut, zeroForOne);
        return (zeroForOne ? -int256(amountIn) : int256(amountOut), zeroForOne ? int256(amountOut) : -int256(amountIn));
    }

    // ------------------------------------------------------------------ //
    //                          Owner utilities                            //
    // ------------------------------------------------------------------ //

    /// @notice Seed liquidity (owner-only; pulls both tokens).
    function seed(uint256 amount0, uint256 amount1) external {
        if (msg.sender != owner) revert NotOwner();
        ERC20(Currency.unwrap(token0_)).transferFrom(owner, address(this), amount0);
        ERC20(Currency.unwrap(token1_)).transferFrom(owner, address(this), amount1);
        reserve0 += amount0;
        reserve1 += amount1;
        emit Seed(amount0, amount1);
    }

    /// @notice Drain all liquidity (owner-only).
    function drain() external {
        if (msg.sender != owner) revert NotOwner();
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        reserve0 = 0;
        reserve1 = 0;
        ERC20(Currency.unwrap(token0_)).transfer(owner, r0);
        ERC20(Currency.unwrap(token1_)).transfer(owner, r1);
        emit Drain(r0, r1);
    }
}
