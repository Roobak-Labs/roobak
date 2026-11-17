// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolRegistry} from "../registry/PoolRegistry.sol";
import {PayoutLedger} from "../rewards/PayoutLedger.sol";
import {ILFund} from "../rewards/ILFund.sol";
import {RouteChecker} from "../libraries/RouteChecker.sol";
import {SwapExecutor} from "../libraries/SwapExecutor.sol";
import {IExternalVenue} from "../interfaces/IExternalVenue.sol";

using SafeERC20 for IERC20;

/// @title RebateHook — Uniswap v4 swap-rebate / arbitrage-capture hook.
/// @notice Backruns the price divergence every trade creates between its paired
///         pools (and approved external venues) inside the same transaction, then
///         shares the *realized* profit: 40%/60% trader/LP on buys, 10%/90% on
///         sells, with the LP side split 35/35/15/15 across paired and protocol
///         pools (defaults; owner-configurable in the registry). Searcher- or
///         keeper-triggered captures pay the searcher a `searcherBps` commission
///         instead of a trader share; a configurable `ilBps` of the LP side is
///         routed into the ILFund liquidity-compensation program.
/// @dev Permission bits required on the deployed address (v4-core v4.0.0):
///      AFTER_INITIALIZE (1<<12) | BEFORE_SWAP (1<<7) | AFTER_SWAP (1<<6)
///      → address & 0x3FFF == 0x10C0.
///      Deployed via CREATE2 (see Create2Factory) with a mined salt; the hook is
///      its own owner-administered working-capital holder.
contract RebateHook is IUnlockCallback, Ownable {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // ------------------------------------------------------------------ //
    //                          Immutables & state                         //
    // ------------------------------------------------------------------ //

    IPoolManager public immutable manager;
    PoolRegistry public immutable registry;
    PayoutLedger public immutable ledger;
    ILFund public immutable ilFund;

    /// @notice transient reentrancy guard slot — auto-discards on revert (Cancun).
    ///         Literal ("rebatehook-capture" hex) so it is usable in assembly.
    uint256 private constant CAPTURING_SLOT = 0x726562617465686f6f6b2d63617074757265;

    /// @notice per-pair diagnostics
    mapping(bytes32 pairId => int256) public lastCaptureProfit;
    mapping(bytes32 pairId => uint256) public captureCount;

    /// @notice working-capital floor per token (withdrawal protection)
    mapping(Currency token => uint256) public workingCapitalFloor;

    uint256 public totalCaptures;

    // ------------------------------------------------------------------ //
    //                            Skip reason codes                        //
    // ------------------------------------------------------------------ //

    uint8 internal constant SKIP_SYSTEM_PAUSED = 1;
    uint8 internal constant SKIP_PAIR_PAUSED = 2;
    uint8 internal constant SKIP_NO_PAIR = 3;
    uint8 internal constant SKIP_POOLS_INCOMPLETE = 4;
    uint8 internal constant SKIP_LOW_ESTIMATE = 5;
    uint8 internal constant SKIP_NO_PROFIT = 6;
    uint8 internal constant SKIP_EXECUTION_FAILED = 7;

    // unlock-callback action ids
    uint8 private constant ACTION_BACKRUN = 1;
    uint8 private constant ACTION_DONATE = 2;

    // ------------------------------------------------------------------ //
    //                               Errors                                //
    // ------------------------------------------------------------------ //

    error NotPoolManager();
    error NotSelf();
    error BaseNotNeutral();
    error NothingToDistribute();
    error UnknownPool();
    error DistributionPaused();
    error ExceedsWorkingCapitalFloor();
    error BadUnlockPayload();
    error ZeroAmount();

    // ------------------------------------------------------------------ //
    //                               Events                                //
    // ------------------------------------------------------------------ //

    event CaptureExecuted(
        bytes32 indexed pairId,
        address indexed cheapVenue,
        address indexed richVenue,
        bool viaExternalVenue,
        uint256 sizeQuote,
        int256 realizedQuote,
        bool traderSoldBase,
        uint256 traderShare,
        uint256 lpShare
    );
    event CaptureSkipped(bytes32 indexed pairId, uint8 reason);
    event LossGuardTripped(bytes32 indexed pairId, int256 loss);
    event KeeperBackrun(bytes32 indexed pairId, address indexed keeper);
    event ILFunded(PoolId indexed pool1, PoolId indexed pool2, uint256 amount1, uint256 amount2);
    event PoolRewardsDistributed(PoolId indexed poolId, uint256 amount);
    event WorkingCapitalFunded(Currency indexed token, address indexed from, uint256 amount);
    event WorkingCapitalWithdrawn(Currency indexed token, uint256 amount);
    event VenueApproved(address indexed venue, Currency indexed token0, Currency indexed token1);

    // ------------------------------------------------------------------ //
    //                             Constructor                             //
    // ------------------------------------------------------------------ //

    constructor(
        IPoolManager manager_,
        PoolRegistry registry_,
        PayoutLedger ledger_,
        ILFund ilFund_,
        address initialOwner
    ) Ownable(initialOwner) {
        manager = manager_;
        registry = registry_;
        ledger = ledger_;
        ilFund = ilFund_;
    }

    // ------------------------------------------------------------------ //
    //                         v4 hook callbacks                           //
    // ------------------------------------------------------------------ //

    /// @notice Auto-register pools initialized with this hook (auto-pairing).
    ///         Dynamic-fee pools (PoolKey.fee == DYNAMIC_FEE_FLAG) get their
    ///         initial LP fee set to the pair's `baseFee`.
    function afterInitialize(address, PoolKey calldata key, uint160, int24) external returns (bytes4) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        registry.attachPool(key); // registry ignores unregistered pairs
        if (key.fee.isDynamicFee()) {
            bytes32 id = registry.pairId(key.currency0, key.currency1);
            if (registry.isPair(id)) {
                manager.updateDynamicLPFee(key, registry.getPair(id).params.baseFee);
            }
        }
        return this.afterInitialize.selector;
    }

    /// @notice Dynamic-fee schedule for pools created with the dynamic-fee flag:
    ///         base fee normally, surge fee when the swap's input size exceeds
    ///         the pair's `surgeThreshold`. Static-fee pools get no override.
    /// @dev The hook's own capture legs are exempt (they settle at the stored
    ///      base fee) — surcharges only apply to user-initiated swaps.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != address(manager)) revert NotPoolManager();
        if (key.fee.isDynamicFee() && !_isCapturing()) {
            bytes32 id = registry.pairId(key.currency0, key.currency1);
            PoolRegistry.PairParams memory p = registry.getPair(id).params;
            uint256 size =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint24 fee = size > p.surgeThreshold ? p.surgeFee : p.baseFee;
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice The capture loop: backrun the divergence this trade created.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        if (_isCapturing()) {
            // hook-caused swap: never backrun our own backrun
            return (this.afterSwap.selector, 0);
        }

        bytes32 id = registry.pairId(key.currency0, key.currency1);
        address recipient = _decodeRecipient(hookData, sender);

        // direction: the swapper's input currency is zeroForOne ? currency0 : currency1;
        // BUY means quote flowed in (base was bought by the trader)
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        PoolRegistry.PairConfig memory cfg = registry.getPair(id);
        bool traderSoldBase = Currency.unwrap(inputCurrency) == Currency.unwrap(cfg.base);
        uint16 traderBps = traderSoldBase ? cfg.params.traderShareSellBps : cfg.params.traderShareBuyBps;

        // revert-isolated execution: a failing capture must never fail the user swap
        try this.runCapture{gas: gasleft()}(id, recipient, traderSoldBase, traderBps) {}
        catch (bytes memory) {
            emit CaptureSkipped(id, SKIP_EXECUTION_FAILED);
        }

        return (this.afterSwap.selector, 0);
    }

    // ------------------------------------------------------------------ //
    //                          Capture execution                          //
    // ------------------------------------------------------------------ //

    /// @notice Revert-isolated capture entry (only callable by this contract —
    ///         invoked from `afterSwap` and the keeper `backrun`).
    function runCapture(bytes32 id, address recipient, bool traderSoldBase, uint16 traderBps)
        external
        returns (bool captured, uint8 skipReason, int256 realized)
    {
        if (msg.sender != address(this)) revert NotSelf();
        _setCapturing();
        (captured, skipReason, realized) = _capture(id, recipient, traderSoldBase, traderBps);
        _clearCapturing();
    }

    /// @dev The full capture loop; may revert (transient guard auto-discards).
    ///      `traderBps` is the recipient's share of realized profit: the trader
    ///      BUY/SELL split for user swaps, or `searcherBps` for searcher/keeper
    ///      triggered captures.
    function _capture(bytes32 id, address recipient, bool traderSoldBase, uint16 traderBps)
        internal
        returns (bool captured, uint8 skipReason, int256 realized)
    {
        if (registry.systemPaused()) {
            emit CaptureSkipped(id, SKIP_SYSTEM_PAUSED);
            return (false, SKIP_SYSTEM_PAUSED, 0);
        }
        PoolRegistry.PairConfig memory cfg = registry.getPair(id);
        if (Currency.unwrap(cfg.base) == address(0)) {
            emit CaptureSkipped(id, SKIP_NO_PAIR);
            return (false, SKIP_NO_PAIR, 0);
        }
        if (cfg.capturePaused) {
            emit CaptureSkipped(id, SKIP_PAIR_PAUSED);
            return (false, SKIP_PAIR_PAUSED, 0);
        }
        if (PoolId.unwrap(cfg.pool1) == 0 || PoolId.unwrap(cfg.pool2) == 0) {
            // the paired-pool cycle needs both pools; external-only pairs unsupported
            emit CaptureSkipped(id, SKIP_POOLS_INCOMPLETE);
            return (false, SKIP_POOLS_INCOMPLETE, 0);
        }

        Currency base = cfg.base;
        Currency quote = cfg.quote;

        // ---- assemble the bounded venue set ---------------------------- //
        uint8 maxStates = cfg.params.maxRouteChecks;
        RouteChecker.VenueState[] memory states = new RouteChecker.VenueState[](maxStates);
        uint256 n = 0;
        _pushV4State(states, n++, cfg.key1, base);
        _pushV4State(states, n++, cfg.key2, base);
        for (uint256 i = 0; i < cfg.venues.length && n < maxStates; i++) {
            _pushVenueState(states, n++, cfg.venues[i], base);
        }
        {
            RouteChecker.VenueState[] memory trimmed = new RouteChecker.VenueState[](n);
            for (uint256 i = 0; i < n; i++) {
                trimmed[i] = states[i];
            }
            states = trimmed;
        }

        // ---- plan & caps ------------------------------------------------ //
        RouteChecker.CyclePlan memory plan = RouteChecker.planBestCycle(states, cfg.params.minProfitQuote);
        if (plan.sizeQuote == 0) {
            emit CaptureSkipped(id, SKIP_LOW_ESTIMATE);
            return (false, SKIP_LOW_ESTIMATE, 0);
        }
        {
            uint256 lqCheap =
                RouteChecker.quoteLiquidity(states[plan.cheapIdx].sqrtPriceX96, states[plan.cheapIdx].liquidity);
            uint256 lqRich =
                RouteChecker.quoteLiquidity(states[plan.richIdx].sqrtPriceX96, states[plan.richIdx].liquidity);
            uint256 size = RouteChecker.capSize(
                plan.sizeQuote, cfg.params.maxTradeSizeQuote, lqCheap, lqRich, cfg.params.maxSizeBpsOfLiquidity
            );
            // never trade more than the working capital actually held
            uint256 held = quote.balanceOf(address(this));
            if (size > held) size = held;
            if (size <= cfg.params.minProfitQuote) {
                emit CaptureSkipped(id, SKIP_LOW_ESTIMATE);
                return (false, SKIP_LOW_ESTIMATE, 0);
            }
            plan.sizeQuote = size;
        }

        // ---- snapshot & execute ----------------------------------------- //
        uint256 q0 = quote.balanceOf(address(this));
        uint256 b0 = base.balanceOf(address(this));

        SwapExecutor.executeCycle(manager, states[plan.cheapIdx], states[plan.richIdx], plan, base, quote, b0);

        // ---- measure realized profit ------------------------------------ //
        uint256 q1 = quote.balanceOf(address(this));
        uint256 b1 = base.balanceOf(address(this));
        realized = int256(q1) - int256(q0);

        // base neutrality within dust tolerance
        uint256 dust = b0 * cfg.params.baseDustToleranceBps / 10_000;
        if (b1 + dust < b0) revert BaseNotNeutral();

        captureCount[id]++;
        lastCaptureProfit[id] = realized;

        if (realized >= int256(cfg.params.minProfitQuote)) {
            (uint256 traderShare, uint256 lpShare) = _pay(id, quote, recipient, uint256(realized), traderBps, cfg);
            totalCaptures++;
            emit CaptureExecuted({
                pairId: id,
                cheapVenue: states[plan.cheapIdx].kind == 1 ? states[plan.cheapIdx].venue : address(0),
                richVenue: states[plan.richIdx].kind == 1 ? states[plan.richIdx].venue : address(0),
                viaExternalVenue: states[plan.cheapIdx].kind == 1 || states[plan.richIdx].kind == 1,
                sizeQuote: plan.sizeQuote,
                realizedQuote: realized,
                traderSoldBase: traderSoldBase,
                traderShare: traderShare,
                lpShare: lpShare
            });
            return (true, 0, realized);
        }

        if (realized < 0 && uint256(-realized) > cfg.params.maxLossGuardQuote) {
            registry.emergencyPause();
            emit LossGuardTripped(id, realized);
            return (false, SKIP_NO_PROFIT, realized);
        }

        // no captured profit → no payout
        emit CaptureSkipped(id, SKIP_NO_PROFIT);
        return (false, SKIP_NO_PROFIT, realized);
    }

    // ------------------------------------------------------------------ //
    //                              Payout                                 //
    // ------------------------------------------------------------------ //

    function _pay(
        bytes32 id,
        Currency quote,
        address recipient,
        uint256 profit,
        uint16 traderBps,
        PoolRegistry.PairConfig memory cfg
    ) internal returns (uint256 traderShare, uint256 lpShare) {
        PoolRegistry.PairParams memory p = cfg.params;

        traderShare = recipient == address(0) ? 0 : profit * traderBps / 10_000;

        // LP-yield engine: carve the IL-fund share out of the LP side first
        uint256 ilTotal = 0;
        if (p.ilBps > 0 && !quote.isAddressZero()) {
            ilTotal = (profit - traderShare) * p.ilBps / 10_000;
        }
        lpShare = profit - traderShare - ilTotal;

        uint256 s1 = lpShare * p.lpPool1Bps / 10_000;
        uint256 s2 = lpShare * p.lpPool2Bps / 10_000;
        uint256 s3 = lpShare * p.lpProtocol1Bps / 10_000;
        uint256 s4 = lpShare * p.lpProtocol2Bps / 10_000;

        PoolId[4] memory pools = [cfg.pool1, cfg.pool2, PoolId.wrap(0), PoolId.wrap(0)];
        {
            PoolKey[] memory proto = registry.protocolPoolKeys();
            if (proto.length == 2) {
                pools[2] = proto[0].toId();
                pools[3] = proto[1].toId();
            } else {
                // protocol pools not configured: fold their shares into the pair pools
                s1 += s3;
                s2 += s4;
                s3 = 0;
                s4 = 0;
            }
        }
        s1 += lpShare - (s1 + s2 + s3 + s4); // rounding dust to pool 1

        // IL carve-out: route to the paired pools pro-rata to their LP shares
        if (ilTotal > 0) {
            uint256 denom = uint256(p.lpPool1Bps) + p.lpPool2Bps;
            uint256 i1 = denom == 0 ? 0 : ilTotal * p.lpPool1Bps / denom;
            uint256 i2 = ilTotal - i1;
            IERC20(Currency.unwrap(quote)).forceApprove(address(ilFund), ilTotal);
            if (i1 > 0) ilFund.fund(cfg.pool1, quote, i1);
            if (i2 > 0) ilFund.fund(cfg.pool2, quote, i2);
            emit ILFunded(cfg.pool1, cfg.pool2, i1, i2);
        }

        // escrow & accrue via the ledger (pulls from the hook)
        IERC20(Currency.unwrap(quote)).forceApprove(address(ledger), profit - ilTotal);
        uint256[4] memory shares = [s1, s2, s3, s4];
        ledger.onCapture(id, quote, recipient, traderShare, pools, shares);
    }

    // ------------------------------------------------------------------ //
    //                        Venue state assembly                         //
    // ------------------------------------------------------------------ //

    function _pushV4State(RouteChecker.VenueState[] memory states, uint256 idx, PoolKey memory key, Currency base)
        internal
        view
    {
        PoolId poolId_ = key.toId();
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId_);
        uint128 liquidity = manager.getLiquidity(poolId_);
        bool baseIsToken0 = Currency.unwrap(base) == Currency.unwrap(key.currency0);
        states[idx] = RouteChecker.VenueState({
            sqrtPriceX96: RouteChecker.normalizeSqrt(sqrtPriceX96, baseIsToken0),
            liquidity: liquidity,
            kind: 0,
            key: key,
            venue: address(0)
        });
    }

    function _pushVenueState(RouteChecker.VenueState[] memory states, uint256 idx, address venue, Currency base)
        internal
        view
    {
        IExternalVenue v = IExternalVenue(venue);
        uint160 sqrtPriceX96 = v.slot0();
        uint128 liquidity = v.liquidity();
        bool baseIsToken0 = Currency.unwrap(base) == Currency.unwrap(v.token0());
        states[idx] = RouteChecker.VenueState({
            sqrtPriceX96: RouteChecker.normalizeSqrt(sqrtPriceX96, baseIsToken0),
            liquidity: liquidity,
            kind: 1,
            key: PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            }),
            venue: venue
        });
    }

    function _decodeRecipient(bytes calldata hookData, address fallbackRecipient) internal pure returns (address) {
        if (hookData.length >= 32) {
            return address(bytes20(hookData[12:32]));
        }
        return fallbackRecipient;
    }

    // ------------------------------------------------------------------ //
    //                        Keeper entry points                          //
    // ------------------------------------------------------------------ //

    /// @notice Permissionless searcher/keeper backrun in its own unlock session.
    /// @dev The searcher receives a `searcherBps` commission of realized profit;
    ///      all pauses, caps and guards still apply. `searcher` is the commission
    ///      beneficiary (searchers call with their own address; routers forward).
    function backrun(bytes32 pairId, address searcher) external {
        manager.unlock(abi.encode(ACTION_BACKRUN, abi.encode(pairId, searcher)));
        emit KeeperBackrun(pairId, searcher);
    }

    /// @notice Distribute a pool's accrued LP rewards into the pool (v4 `donate`),
    ///         flowing pro-rata to in-range liquidity via fee growth.
    function distributePoolRewards(PoolId poolId_) external {
        if (registry.distributionPaused()) revert DistributionPaused();
        uint256 amount = ledger.poolCredits(poolId_);
        if (amount == 0) revert NothingToDistribute();
        PoolKey memory key = registry.getPoolKey(poolId_);
        if (Currency.unwrap(key.currency0) == address(0)) revert UnknownPool();
        Currency quote = ledger.poolRewardCurrency(poolId_);

        ledger.releaseToHook(poolId_, amount);
        manager.unlock(abi.encode(ACTION_DONATE, abi.encode(key, quote, amount)));
        emit PoolRewardsDistributed(poolId_, amount);
    }

    // ------------------------------------------------------------------ //
    //                          Unlock callback                            //
    // ------------------------------------------------------------------ //

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotPoolManager();
        (uint8 action, bytes memory payload) = abi.decode(data, (uint8, bytes));

        if (action == ACTION_BACKRUN) {
            (bytes32 pairId, address searcher) = abi.decode(payload, (bytes32, address));
            _setCapturing();
            // searcher commission = searcherBps; the LP side takes the remainder
            uint16 searcherBps = registry.getPair(pairId).params.searcherBps;
            _capture(pairId, searcher, true, searcherBps);
            _clearCapturing();
            return "";
        }

        if (action == ACTION_DONATE) {
            (PoolKey memory key, Currency quote, uint256 amount) = abi.decode(payload, (PoolKey, Currency, uint256));
            bool quoteIsCurrency0 = Currency.unwrap(quote) == Currency.unwrap(key.currency0);
            manager.donate(key, quoteIsCurrency0 ? amount : 0, quoteIsCurrency0 ? 0 : amount, new bytes(0));
            // pay the donation: sync → transfer → settle
            manager.sync(quote);
            ERC20(Currency.unwrap(quote)).transfer(address(manager), amount);
            manager.settle();
            return "";
        }

        revert BadUnlockPayload();
    }

    // ------------------------------------------------------------------ //
    //                       Working capital & admin                       //
    // ------------------------------------------------------------------ //

    /// @notice Fund the hook's quote working capital (ERC-20 pull).
    function fundWorkingCapital(Currency token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        IERC20(Currency.unwrap(token)).safeTransferFrom(msg.sender, address(this), amount);
        emit WorkingCapitalFunded(token, msg.sender, amount);
    }

    /// @notice Withdraw working capital above the configured floor.
    function withdrawExcessCapital(Currency token, uint256 amount) external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        if (amount > balance - workingCapitalFloor[token]) revert ExceedsWorkingCapitalFloor();
        IERC20(Currency.unwrap(token)).safeTransfer(msg.sender, amount);
        emit WorkingCapitalWithdrawn(token, amount);
    }

    function setWorkingCapitalFloor(Currency token, uint256 floor) external onlyOwner {
        workingCapitalFloor[token] = floor;
    }

    /// @notice Approve an external venue to pull the pair's tokens (one-time setup
    ///         per venue; venues are owner-approved in the registry).
    function approveVenue(Currency token0, Currency token1, address venue) external onlyOwner {
        IERC20(Currency.unwrap(token0)).forceApprove(venue, type(uint256).max);
        IERC20(Currency.unwrap(token1)).forceApprove(venue, type(uint256).max);
        emit VenueApproved(venue, token0, token1);
    }

    // ------------------------------------------------------------------ //
    //                       Transient guard helpers                       //
    // ------------------------------------------------------------------ //

    function _isCapturing() internal view returns (bool b) {
        assembly {
            b := tload(CAPTURING_SLOT)
        }
    }

    function _setCapturing() internal {
        assembly {
            tstore(CAPTURING_SLOT, 1)
        }
    }

    function _clearCapturing() internal {
        assembly {
            tstore(CAPTURING_SLOT, 0)
        }
    }
}
