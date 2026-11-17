// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolRegistry} from "../registry/PoolRegistry.sol";

/// @title OrderBook — escrowed conditional orders on approved hook pools.
/// @notice Limit and stop orders, unified as {direction, trigger, triggerSide}:
///         an order fills when the pool price crosses its trigger in the chosen
///         direction. Input tokens are escrowed at placement; fills are
///         permissionless (anyone may trigger, earning a small bounty), execute
///         through the pool itself — so a fill on a rebate pool routes the
///         placer's address in the swap hook data and the placer earns the
///         ordinary trader share of any capture their order creates.
/// @dev Price P means the v4 raw sqrtPriceX96, i.e. sqrt(token1/token0).
///      `fillAbove` fills when P > trigger (limit-sell token0 / stop-buy token0);
///      `fillBelow` fills when P < trigger (limit-buy token0 / stop-sell token0).
///      Limit-style orders (1: zfo+above, 3: !zfo+below) additionally bound the
///      fill swap at the trigger so execution can never cross it; stop-style
///      orders rely on the placer's `minAmountOut`.
contract OrderBook is IUnlockCallback, Ownable {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    uint8 private constant ACTION_FILL = 1;
    uint8 public constant STATUS_OPEN = 0;
    uint8 public constant STATUS_FILLED = 1;
    uint8 public constant STATUS_CANCELLED = 2;
    /// @notice Upper bound for the permissionless filler bounty (bps of output).
    uint16 public constant MAX_FILL_REWARD_BPS = 1000;

    struct Order {
        address placer;
        PoolKey key;
        bool zeroForOne; // swap direction: token0 in (true) / token1 in (false)
        bool fillAbove; // fill when price > trigger (else when price < trigger)
        uint256 amountIn; // escrowed input
        uint256 minAmountOut; // placer's slippage guard on the output
        uint160 triggerSqrtPriceX96; // trigger price (raw v4 sqrt)
        uint64 deadline; // 0 = open-ended
        uint8 status;
    }

    IPoolManager public immutable manager;
    PoolRegistry public immutable registry;

    mapping(uint256 orderId => Order) public orders;
    uint256 public orderCount;
    mapping(address placer => uint256[]) public placerOrderIds;
    /// @notice bounty for the permissionless filler, bps of the order's output
    uint16 public fillRewardBps = 100; // 1%

    // ------------------------------------------------------------------ //
    //                               Errors                                //
    // ------------------------------------------------------------------ //

    error NotPoolManager();
    error BadUnlockPayload();
    error UnknownOrder();
    error NotPlacer();
    error OrderNotOpen();
    error ZeroAmount();
    error BadTrigger();
    error BadPool();
    error Expired();
    error NotCrossed();
    error TooLittleOutput();
    error NativeTransferFailed();

    // ------------------------------------------------------------------ //
    //                               Events                                //
    // ------------------------------------------------------------------ //

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed placer,
        PoolKey key,
        bool zeroForOne,
        bool fillAbove,
        uint256 amountIn,
        uint256 minAmountOut,
        uint160 triggerSqrtPriceX96,
        uint64 deadline
    );
    event OrderFilled(
        uint256 indexed orderId,
        address indexed placer,
        address indexed filler,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fillerReward
    );
    event OrderCancelled(uint256 indexed orderId, address indexed placer, uint256 refunded);
    event FillRewardBpsSet(uint16 bps);

    constructor(IPoolManager manager_, PoolRegistry registry_, address initialOwner) Ownable(initialOwner) {
        manager = manager_;
        registry = registry_;
    }

    function setFillRewardBps(uint16 bps) external onlyOwner {
        if (bps > MAX_FILL_REWARD_BPS) revert ZeroAmount();
        fillRewardBps = bps;
        emit FillRewardBpsSet(bps);
    }

    // ------------------------------------------------------------------ //
    //                              Placement                              //
    // ------------------------------------------------------------------ //

    /// @notice Place an order; the input amount is escrowed until fill or cancel.
    /// @param key an initialized, registry-approved pool.
    /// @param zeroForOne swap direction (token0 in when true).
    /// @param fillAbove fill when price rises through the trigger (false: falls).
    /// @param triggerSqrtPriceX96 trigger price, strictly inside TickMath bounds.
    /// @param deadline unix timestamp after which the order is only cancellable
    ///        (0 = open-ended).
    function place(
        PoolKey memory key,
        bool zeroForOne,
        bool fillAbove,
        uint256 amountIn,
        uint256 minAmountOut,
        uint160 triggerSqrtPriceX96,
        uint64 deadline
    ) external payable returns (uint256 orderId) {
        if (amountIn == 0) revert ZeroAmount();
        if (triggerSqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || triggerSqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert BadTrigger();
        }
        if (!registry.isApprovedPool(key.toId())) revert BadPool();
        if (deadline != 0 && deadline < block.timestamp) revert Expired();

        Currency currencyIn = zeroForOne ? key.currency0 : key.currency1;
        if (currencyIn.isAddressZero()) {
            if (msg.value != amountIn) revert ZeroAmount();
        } else {
            if (msg.value != 0) revert ZeroAmount();
            ERC20(Currency.unwrap(currencyIn)).transferFrom(msg.sender, address(this), amountIn);
        }

        orderId = orderCount++;
        orders[orderId] = Order({
            placer: msg.sender,
            key: key,
            zeroForOne: zeroForOne,
            fillAbove: fillAbove,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            triggerSqrtPriceX96: triggerSqrtPriceX96,
            deadline: deadline,
            status: STATUS_OPEN
        });
        placerOrderIds[msg.sender].push(orderId);

        emit OrderPlaced(
            orderId, msg.sender, key, zeroForOne, fillAbove, amountIn, minAmountOut, triggerSqrtPriceX96, deadline
        );
    }

    /// @notice Cancel an open order and refund the escrow (permissionless race
    ///         with fillers; last transaction wins).
    function cancel(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (o.placer == address(0)) revert UnknownOrder();
        if (msg.sender != o.placer) revert NotPlacer();
        if (o.status != STATUS_OPEN) revert OrderNotOpen();
        o.status = STATUS_CANCELLED;

        Currency currencyIn = o.zeroForOne ? o.key.currency0 : o.key.currency1;
        _payout(currencyIn, o.placer, o.amountIn);
        emit OrderCancelled(orderId, o.placer, o.amountIn);
    }

    // ------------------------------------------------------------------ //
    //                                 Fill                                //
    // ------------------------------------------------------------------ //

    /// @notice Permissionless fill: execute a crossed order through its pool.
    ///         The filler receives `fillRewardBps` of the output.
    function fill(uint256 orderId) external returns (uint256 amountOut, uint256 fillerReward) {
        Order memory o = orders[orderId];
        if (o.placer == address(0)) revert UnknownOrder();
        if (o.status != STATUS_OPEN) revert OrderNotOpen();
        if (o.deadline != 0 && block.timestamp > o.deadline) revert Expired();
        _requireCrossed(o);

        // mark first — reentrant fills/cancels during settlement see a closed order
        orders[orderId].status = STATUS_FILLED;

        (amountOut, fillerReward) =
            abi.decode(manager.unlock(abi.encode(ACTION_FILL, abi.encode(orderId, msg.sender))), (uint256, uint256));
        emit OrderFilled(orderId, o.placer, msg.sender, o.amountIn, amountOut, fillerReward);
    }

    function _requireCrossed(Order memory o) internal view {
        (uint160 sqrt,,,) = manager.getSlot0(o.key.toId());
        bool crossed = o.fillAbove ? sqrt > o.triggerSqrtPriceX96 : sqrt < o.triggerSqrtPriceX96;
        if (!crossed) revert NotCrossed();
    }

    // ------------------------------------------------------------------ //
    //                          Unlock callback                            //
    // ------------------------------------------------------------------ //

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (action != ACTION_FILL) revert BadUnlockPayload();
        (uint256 orderId, address filler) = abi.decode(payload, (uint256, address));

        Order memory o = orders[orderId];
        if (o.status != STATUS_FILLED) revert BadUnlockPayload(); // set optimistically by fill()

        Currency currencyIn = o.zeroForOne ? o.key.currency0 : o.key.currency1;
        Currency currencyOut = o.zeroForOne ? o.key.currency1 : o.key.currency0;

        // limit-style orders bound execution at the trigger; stop-style orders
        // sweep toward the TickMath bound and rely on minAmountOut
        uint160 limit = o.zeroForOne
            ? (o.fillAbove ? o.triggerSqrtPriceX96 : TickMath.MIN_SQRT_PRICE + 1)
            : (o.fillAbove ? TickMath.MAX_SQRT_PRICE - 1 : o.triggerSqrtPriceX96);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: o.zeroForOne, amountSpecified: -int256(o.amountIn), sqrtPriceLimitX96: limit
        });

        // the placer is the rebate recipient when this fill creates a capture
        BalanceDelta delta = manager.swap(o.key, params, abi.encode(o.placer));

        // pay the escrowed input
        if (currencyIn.isAddressZero()) {
            manager.settle{value: o.amountIn}();
        } else {
            manager.sync(currencyIn);
            ERC20(Currency.unwrap(currencyIn)).transfer(address(manager), o.amountIn);
            manager.settle();
        }

        // take the output to the book, then split placer / filler
        int128 outDelta = o.zeroForOne ? delta.amount1() : delta.amount0();
        if (outDelta <= 0 || uint256(uint128(outDelta)) < o.minAmountOut) {
            revert TooLittleOutput();
        }
        uint256 amountOut = uint128(outDelta);
        manager.take(currencyOut, address(this), amountOut);

        uint256 reward = amountOut * fillRewardBps / 10_000;
        _payout(currencyOut, o.placer, amountOut - reward);
        _payout(currencyOut, filler, reward); // the permissionless filler

        return abi.encode(amountOut, reward);
    }

    // ------------------------------------------------------------------ //
    //                               Views                                 //
    // ------------------------------------------------------------------ //

    function orderIdsOf(address placer) external view returns (uint256[] memory) {
        return placerOrderIds[placer];
    }

    /// @notice Whether an open order's trigger is currently crossed.
    function isCrossed(uint256 orderId) external view returns (bool) {
        Order memory o = orders[orderId];
        if (o.status != STATUS_OPEN) return false;
        (uint160 sqrt,,,) = manager.getSlot0(o.key.toId());
        return o.fillAbove ? sqrt > o.triggerSqrtPriceX96 : sqrt < o.triggerSqrtPriceX96;
    }

    // ------------------------------------------------------------------ //
    //                              Internals                              //
    // ------------------------------------------------------------------ //

    function _payout(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (currency.isAddressZero()) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            ERC20(Currency.unwrap(currency)).transfer(to, amount);
        }
    }
}
