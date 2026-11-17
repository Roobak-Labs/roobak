// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

/// @title SwapRouter — minimal non-custodial router for v4 pools.
/// @notice Swap with slippage protection, and add/remove liquidity with
///         per-user position salts. Encodes the EOA trader as the rebate
///         recipient in the swap's hook data.
/// @dev No owner, no fees, no batching — the smallest safe surface for a fresh
///      chain. Integrators can deploy the official Universal Router alongside.
contract SwapRouter is IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    uint8 private constant ACTION_SWAP = 1;
    uint8 private constant ACTION_ADD_LIQUIDITY = 2;
    uint8 private constant ACTION_REMOVE_LIQUIDITY = 3;

    error Expired();
    error InsufficientNative();
    error TooLittleOutput();
    error NativeLiquidityUnsupported();
    error TooLittleLiquidity();
    error NotPoolManager();
    error BadUnlockPayload();
    error NotPositionOwner();
    error NativeTransferFailed();

    IPoolManager public immutable manager;

    event SwapRouted(address indexed user, PoolId indexed poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut);
    event LiquidityAdded(
        address indexed user, PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity
    );
    event LiquidityRemoved(
        address indexed user, PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity
    );

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    // ------------------------------------------------------------------ //
    //                                Swap                                 //
    // ------------------------------------------------------------------ //

    /// @notice Exact-input swap. Native input supported via msg.value; native
    ///         output is sent to the user directly.
    function swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut, uint64 deadline)
        external
        payable
        returns (uint256 amountOut)
    {
        if (block.timestamp > deadline) revert Expired();
        Currency currencyIn = zeroForOne ? key.currency0 : key.currency1;

        if (currencyIn.isAddressZero()) {
            if (msg.value < amountIn) revert InsufficientNative();
        } else {
            ERC20(Currency.unwrap(currencyIn)).transferFrom(msg.sender, address(this), amountIn);
        }

        bytes memory payload = abi.encode(ACTION_SWAP, abi.encode(msg.sender, key, zeroForOne, amountIn, minAmountOut));
        amountOut = abi.decode(manager.unlock(payload), (uint256));
        emit SwapRouted(msg.sender, key.toId(), zeroForOne, amountIn, amountOut);

        // refund unused native
        uint256 leftover = address(this).balance;
        if (leftover > 0) {
            (bool ok,) = msg.sender.call{value: leftover}("");
            if (!ok) revert NativeTransferFailed();
        }
    }

    // ------------------------------------------------------------------ //
    //                            Liquidity                                //
    // ------------------------------------------------------------------ //

    /// @notice Add liquidity in [tickLower, tickUpper]; pulls at most the given
    ///         amounts and refunds the unused remainder.
    function addLiquidity(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Max,
        uint256 amount1Max,
        uint128 minLiquidity,
        uint64 deadline
    ) external returns (uint128 liquidity) {
        if (block.timestamp > deadline) revert Expired();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeLiquidityUnsupported();

        ERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), amount0Max);
        ERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount1Max);

        bytes memory payload = abi.encode(
            ACTION_ADD_LIQUIDITY,
            abi.encode(msg.sender, key, tickLower, tickUpper, amount0Max, amount1Max, minLiquidity)
        );
        liquidity = abi.decode(manager.unlock(payload), (uint128));
        emit LiquidityAdded(msg.sender, key.toId(), tickLower, tickUpper, liquidity);
    }

    /// @notice Remove liquidity the caller added through this router (same ticks).
    function removeLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        bytes memory payload =
            abi.encode(ACTION_REMOVE_LIQUIDITY, abi.encode(msg.sender, key, tickLower, tickUpper, liquidity));
        manager.unlock(payload);
        emit LiquidityRemoved(msg.sender, key.toId(), tickLower, tickUpper, liquidity);
    }

    // ------------------------------------------------------------------ //
    //                          Unlock callback                            //
    // ------------------------------------------------------------------ //

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));

        if (action == ACTION_SWAP) {
            (address user, PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut) =
                abi.decode(payload, (address, PoolKey, bool, uint256, uint256));
            return abi.encode(_swap(user, key, zeroForOne, amountIn, minAmountOut));
        }

        if (action == ACTION_ADD_LIQUIDITY) {
            (
                address user,
                PoolKey memory key,
                int24 tickLower,
                int24 tickUpper,
                uint256 amount0Max,
                uint256 amount1Max,
                uint128 minLiquidity
            ) = abi.decode(payload, (address, PoolKey, int24, int24, uint256, uint256, uint128));
            return abi.encode(_addLiquidity(user, key, tickLower, tickUpper, amount0Max, amount1Max, minLiquidity));
        }

        if (action == ACTION_REMOVE_LIQUIDITY) {
            (address user, PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) =
                abi.decode(payload, (address, PoolKey, int24, int24, uint128));
            _removeLiquidity(user, key, tickLower, tickUpper, liquidity);
            return "";
        }

        revert BadUnlockPayload();
    }

    // ------------------------------------------------------------------ //
    //                             Internals                               //
    // ------------------------------------------------------------------ //

    function _swap(address user, PoolKey memory key, bool zeroForOne, uint256 amountIn, uint256 minAmountOut)
        internal
        returns (uint256 amountOut)
    {
        Currency currencyIn = zeroForOne ? key.currency0 : key.currency1;
        Currency currencyOut = zeroForOne ? key.currency1 : key.currency0;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        // hookData: the EOA trader — rebate recipient for RebateHook pools
        BalanceDelta delta = manager.swap(key, params, abi.encode(user));

        // pay the input
        if (currencyIn.isAddressZero()) {
            manager.settle{value: amountIn}();
        } else {
            manager.sync(currencyIn);
            ERC20(Currency.unwrap(currencyIn)).transfer(address(manager), amountIn);
            manager.settle();
        }

        // take the output straight to the user
        int128 outDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (outDelta <= 0 || uint256(uint128(outDelta)) < minAmountOut) revert TooLittleOutput();
        amountOut = uint128(outDelta);
        manager.take(currencyOut, user, amountOut);
    }

    function _addLiquidity(
        address user,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Max,
        uint256 amount1Max,
        uint128 minLiquidity
    ) internal returns (uint128 liquidity) {
        (uint160 sqrtP,,,) = manager.getSlot0(key.toId());
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );
        if (liquidity < minLiquidity) revert TooLittleLiquidity();

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: _positionSalt(user)
        });
        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");

        _settleOwed(key.currency0, uint256(uint128(-delta.amount0())));
        _settleOwed(key.currency1, uint256(uint128(-delta.amount1())));

        // refund unused input to the user
        _refund(key.currency0, user);
        _refund(key.currency1, user);
    }

    function _removeLiquidity(address user, PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        returns (uint128)
    {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: -int256(uint256(liquidity)),
            salt: _positionSalt(user)
        });
        (BalanceDelta principal, BalanceDelta fees) = manager.modifyLiquidity(key, params, "");

        _takeToUser(key.currency0, user, principal.amount0() + fees.amount0());
        _takeToUser(key.currency1, user, principal.amount1() + fees.amount1());
        return liquidity;
    }

    function _settleOwed(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        manager.sync(currency);
        ERC20(Currency.unwrap(currency)).transfer(address(manager), amount);
        manager.settle();
    }

    function _takeToUser(Currency currency, address user, int128 amount) internal {
        if (amount <= 0) return;
        manager.take(currency, user, uint128(amount));
    }

    function _refund(Currency currency, address user) internal {
        uint256 leftover = currency.balanceOf(address(this));
        if (leftover > 0) {
            ERC20(Currency.unwrap(currency)).transfer(user, leftover);
        }
    }

    /// @notice Per-user position salt: positions belong to their depositor.
    function _positionSalt(address user) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(user)));
    }
}
