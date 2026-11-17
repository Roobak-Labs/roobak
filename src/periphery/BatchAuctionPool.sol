// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IExternalVenue} from "../interfaces/IExternalVenue.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

/// @title BatchAuctionPool — EXPERIMENTAL uniform-price batch venue.
/// @notice Dual-mode constant-product venue:
///         (1) immediate swaps through the standard `IExternalVenue` interface,
///             so it can be registered like any external venue; and
///         (2) a batch auction: orders accumulate escrowed while the batch is
///             open, and settlement nets token0 vs token1 flow, executes every
///             included order at ONE uniform clearing price — no intra-batch
///             ordering, no sandwiching between batch participants.
/// @dev Experimental reference implementation, deliberately minimal:
///      - one batch at a time, owner-configured interval;
///      - the clearing price is the average price of the NET residual trade
///        against the pool (dominant side after opposing flows net off at the
///        pre-batch spot); the fee applies only to that net residual — the
///        internally matched portion trades fee-free;
///      - orders whose `minOut` violates the clearing price are refunded and
///        their input removed from reserves (the clearing price itself is not
///        re-iterated);
///      - no partial fills; cancellation only while the batch is open;
///      - solvency is asserted against actual token balances before payouts.
contract BatchAuctionPool is IExternalVenue {
    using CurrencyLibrary for Currency;

    uint256 public constant BPS = 10_000;

    Currency public immutable token0_;
    Currency private immutable _token1;
    uint256 public immutable feeBps;
    address public immutable owner;

    uint256 private reserve0;
    uint256 private reserve1;

    // ---- batch state ---- //
    struct BatchOrder {
        address submitter;
        bool zeroForOne; // true: token0 in / token1 out
        uint256 amountIn;
        uint256 minOut;
        uint8 status; // 0=pending 1=filled 2=refunded 3=cancelled
    }
    BatchOrder[] public batchOrders;
    /// @notice batch open until this timestamp (0 = no open batch)
    uint64 public batchDeadline;
    /// @notice settlement interval in seconds (owner-settable)
    uint64 public batchInterval = 60;
    /// @notice first order index of each opened batch, by its deadline
    mapping(uint64 deadline => uint256 start) public batchStartIndex;

    error NotOwner();
    error BadAmount();
    error ExactInputOnly();
    error TooLittleOutput();
    error ZeroReserves();
    error BatchStillOpen();
    error BatchNotOpen();
    error NothingToCancel();
    error BatchInsolvent();

    event Seed(uint256 amount0, uint256 amount1);
    event Drain(uint256 amount0, uint256 amount1);
    event Swap(address indexed caller, address indexed recipient, uint256 amountIn, uint256 amountOut, bool zeroForOne);
    event BatchOpened(uint256 deadline);
    event OrderSubmitted(
        uint256 indexed orderId, address indexed submitter, bool zeroForOne, uint256 amountIn, uint256 minOut
    );
    event BatchSettled(uint256 indexed deadline, uint256 clearingPriceX96, uint256 filledCount, uint256 refundedCount);
    event OrderSettled(uint256 indexed orderId, uint8 indexed status, uint256 amountOut);
    event OrderCancelled(uint256 indexed orderId);
    event BatchIntervalSet(uint64 interval);

    constructor(Currency tokenA, Currency tokenB, uint256 feeBps_, address owner_) {
        require(
            !tokenA.isAddressZero() && !tokenB.isAddressZero() && Currency.unwrap(tokenA) != Currency.unwrap(tokenB),
            "bad tokens"
        );
        (token0_, _token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
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
        return _token1;
    }

    /// @return sqrtPriceX96 sqrt(token1/token0) as Q64.96
    function slot0() external view returns (uint160) {
        if (reserve0 == 0 || reserve1 == 0) return 0;
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

    function batchOrderCount() external view returns (uint256) {
        return batchOrders.length;
    }

    // ------------------------------------------------------------------ //
    //                       Mode 1 — immediate swap                        //
    // ------------------------------------------------------------------ //

    /// @notice Exact-input swap at current reserves (standard venue interface).
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

        Currency inToken = zeroForOne ? token0_ : _token1;
        Currency outToken = zeroForOne ? _token1 : token0_;

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
    //                      Mode 2 — batch auction                         //
    // ------------------------------------------------------------------ //

    /// @notice Submit an escrowed order to the current batch; the first
    ///         submission opens the batch. Input tokens are pulled immediately.
    function submitOrder(bool zeroForOne, uint256 amountIn, uint256 minOut) external returns (uint256 orderId) {
        if (amountIn == 0) revert BadAmount();
        if (batchDeadline == 0) {
            uint64 deadline = uint64(block.timestamp) + batchInterval;
            batchDeadline = deadline;
            batchStartIndex[deadline] = batchOrders.length; // this order's index
            emit BatchOpened(deadline);
        }

        Currency inToken = zeroForOne ? token0_ : _token1;
        ERC20(Currency.unwrap(inToken)).transferFrom(msg.sender, address(this), amountIn);

        orderId = batchOrders.length;
        batchOrders.push(
            BatchOrder({submitter: msg.sender, zeroForOne: zeroForOne, amountIn: amountIn, minOut: minOut, status: 0})
        );
        emit OrderSubmitted(orderId, msg.sender, zeroForOne, amountIn, minOut);
    }

    /// @notice Cancel a pending order while its batch is still open.
    function cancel(uint256 orderId) external {
        BatchOrder storage o = batchOrders[orderId];
        if (o.submitter != msg.sender || o.status != 0) revert NothingToCancel();
        if (batchDeadline != 0 && block.timestamp >= batchDeadline) revert BatchStillOpen(); // settle window
        o.status = 3;
        Currency inToken = o.zeroForOne ? token0_ : _token1;
        ERC20(Currency.unwrap(inToken)).transfer(o.submitter, o.amountIn);
        emit OrderCancelled(orderId);
    }

    /// @notice Settle the closed batch (permissionless): net token0 vs token1
    ///         flow, compute one uniform clearing price from the net residual
    ///         trade, pay filled orders, refund minOut violators.
    function settle() external {
        if (batchDeadline == 0 || block.timestamp < batchDeadline) revert BatchStillOpen();
        if (reserve0 == 0 || reserve1 == 0) revert ZeroReserves();
        uint64 deadline = batchDeadline;
        batchDeadline = 0; // close before external transfers

        uint256 start = batchStartIndex[deadline];
        uint256 end = batchOrders.length;

        // net inflows per side
        uint256 net0; // total token0 submitted (zfo side)
        uint256 net1; // total token1 submitted (!zfo side)
        for (uint256 i = start; i < end; i++) {
            BatchOrder memory o = batchOrders[i];
            if (o.status != 0) continue;
            if (o.zeroForOne) {
                net0 += o.amountIn;
            } else {
                net1 += o.amountIn;
            }
        }

        // ---- clearing price: average price of the net residual trade ---- //
        uint256 priceX96; // token1 per token0, Q64.96
        {
            uint256 spotX96 = Math.mulDiv(reserve1, 1 << 96, reserve0);
            uint256 net1As0 = Math.mulDiv(net1, 1 << 96, spotX96); // net1 in token0 terms
            if (net0 >= net1As0) {
                // token0 side dominant: the residual trades into the pool at the
                // CP price; both sides' full inflows then join reserves, from
                // which all outputs are paid
                uint256 residual0 = net0 - net1As0;
                uint256 out1net = 0;
                if (residual0 > 0) {
                    uint256 af = residual0 * (BPS - feeBps) / BPS;
                    out1net = Math.mulDiv(reserve1, af, reserve0 + af);
                    priceX96 = Math.mulDiv(out1net, 1 << 96, residual0);
                    reserve1 -= out1net;
                } else {
                    priceX96 = spotX96; // fully matched internally
                }
                reserve0 += net0;
                reserve1 += net1;
            } else {
                // token1 side dominant: symmetric
                uint256 net0As1 = Math.mulDiv(net0, spotX96, 1 << 96);
                uint256 residual1 = net1 - net0As1;
                if (residual1 > 0) {
                    uint256 af = residual1 * (BPS - feeBps) / BPS;
                    uint256 out0net = Math.mulDiv(reserve0, af, reserve1 + af);
                    priceX96 = Math.mulDiv(residual1, 1 << 96, out0net);
                    reserve0 -= out0net;
                } else {
                    priceX96 = spotX96;
                }
                reserve1 += net1;
                reserve0 += net0;
            }
        }

        // ---- distribute at the uniform price; refund violators ---- //
        uint256 filledCount = 0;
        uint256 refundedCount = 0;
        uint256 refund0; // violating inputs to remove from reserves again
        uint256 refund1;
        uint256 pay0; // total outputs to assert solvency
        uint256 pay1;
        for (uint256 i = start; i < end; i++) {
            BatchOrder storage o = batchOrders[i];
            if (o.status != 0) continue;
            if (priceX96 > 0) {
                uint256 out = o.zeroForOne
                    ? Math.mulDiv(o.amountIn, priceX96, 1 << 96)
                    : Math.mulDiv(o.amountIn, 1 << 96, priceX96);
                if (out >= o.minOut && out > 0) {
                    o.status = 1;
                    filledCount++;
                    if (o.zeroForOne) pay1 += out;
                    else pay0 += out;
                    emit OrderSettled(i, 1, out);
                    continue;
                }
            }
            o.status = 2;
            refundedCount++;
            if (o.zeroForOne) refund0 += o.amountIn;
            else refund1 += o.amountIn;
            emit OrderSettled(i, 2, o.amountIn);
        }

        // violating orders never traded: pull their inputs back out of reserves
        reserve0 -= refund0;
        reserve1 -= refund1;

        // ---- solvency assertion (experimental belt-and-braces): the balance,
        //      which includes reserves, must cover the payouts ---- //
        if (ERC20(Currency.unwrap(token0_)).balanceOf(address(this)) < pay0) revert BatchInsolvent();
        if (ERC20(Currency.unwrap(_token1)).balanceOf(address(this)) < pay1) revert BatchInsolvent();

        // outputs are paid from reserves (inflows joined them above)
        reserve0 -= pay0;
        reserve1 -= pay1;

        // ---- payouts ---- //
        for (uint256 i = start; i < end; i++) {
            BatchOrder memory o = batchOrders[i];
            if (o.status == 1) {
                uint256 out = o.zeroForOne
                    ? Math.mulDiv(o.amountIn, priceX96, 1 << 96)
                    : Math.mulDiv(o.amountIn, 1 << 96, priceX96);
                Currency outToken = o.zeroForOne ? _token1 : token0_;
                ERC20(Currency.unwrap(outToken)).transfer(o.submitter, out);
            } else if (o.status == 2) {
                Currency inToken = o.zeroForOne ? token0_ : _token1;
                ERC20(Currency.unwrap(inToken)).transfer(o.submitter, o.amountIn);
            }
        }

        emit BatchSettled(deadline, priceX96, filledCount, refundedCount);
    }

    // ------------------------------------------------------------------ //
    //                          Owner utilities                            //
    // ------------------------------------------------------------------ //

    function seed(uint256 amount0, uint256 amount1) external {
        if (msg.sender != owner) revert NotOwner();
        ERC20(Currency.unwrap(token0_)).transferFrom(owner, address(this), amount0);
        ERC20(Currency.unwrap(_token1)).transferFrom(owner, address(this), amount1);
        reserve0 += amount0;
        reserve1 += amount1;
        emit Seed(amount0, amount1);
    }

    function drain() external {
        if (msg.sender != owner) revert NotOwner();
        uint256 r0 = reserve0;
        uint256 r1 = reserve1;
        reserve0 = 0;
        reserve1 = 0;
        ERC20(Currency.unwrap(token0_)).transfer(owner, r0);
        ERC20(Currency.unwrap(_token1)).transfer(owner, r1);
        emit Drain(r0, r1);
    }

    function setBatchInterval(uint64 interval) external {
        if (msg.sender != owner) revert NotOwner();
        if (interval == 0) revert BadAmount();
        batchInterval = interval;
        emit BatchIntervalSet(interval);
    }
}
