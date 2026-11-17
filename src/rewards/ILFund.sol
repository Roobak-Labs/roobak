// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

using SafeERC20 for IERC20;

/// @title ILFund — liquidity-time weighted LP compensation.
/// @notice Receives the `ilBps` carve-out of every capture's LP side (routed per
///         pool, split between the paired pools like their LP shares) and pays it
///         to LPs weighted by *registered position liquidity × time*. Stakes are
///         real v4 positions read live from the PoolManager at each `accrue` —
///         nothing is self-declared.
/// @dev Honest scope: liquidity-time weighted compensation funded by captured
///      arbitrage profit — **not** mark-to-market impermanent-loss insurance.
///      Classic stake/index accounting, exactly solvent: each funding event
///      divides by the currently registered stake total, and past index deltas
///      always settle against the stake that was registered for them, so total
///      claims can never exceed total funds received. Participation is lazy:
///      an LP accrues from their first `accrue` onward (no retroactive credit
///      before registration) — accrue early and often.
contract ILFund is Ownable {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /// @notice Fixed-point scale of the per-stake reward index.
    uint256 internal constant PRECISION = 1e18;

    IPoolManager public immutable manager;
    /// @notice the RebateHook — sole caller of `fund` (bound once after deployment)
    address public hook;

    /// @notice per-pool reward index: cumulative reward per 1 unit of staked liquidity
    mapping(PoolId poolId => uint256) public cumulativePerStake;
    /// @notice per-pool total registered stake
    mapping(PoolId => uint256) public stakeTotal;
    /// @notice per-pool funding that arrived before any stake existed (rolls
    ///         into the index at the next funded event with stake)
    mapping(PoolId => uint256) public pendingRewards;
    /// @notice the currency a pool's rewards accrue in (fixed at first funding)
    mapping(PoolId => Currency) public rewardCurrency;

    /// @notice one LP's registration for a specific v4 position
    struct PositionRecord {
        uint128 stake; // position liquidity registered at the last accrue
        uint256 checkpoint; // cumulativePerStake at the last settle
    }
    /// @notice (poolId, positionOwner, tickLower, tickUpper, salt) → record
    mapping(PoolId => mapping(address => mapping(int24 => mapping(int24 => mapping(bytes32 => PositionRecord))))) public
        records;

    /// @notice accrued, unclaimed compensation: beneficiary → token → amount
    mapping(address beneficiary => mapping(Currency token => uint256)) public owed;

    // --- solvency accounting: funded − paid − owedOutstanding = surplus ≥ 0 --- //
    mapping(Currency token => uint256) public fundedTotal;
    mapping(Currency token => uint256) public paidTotal;
    mapping(Currency token => uint256) public owedOutstanding;

    // ------------------------------------------------------------------ //
    //                               Errors                                //
    // ------------------------------------------------------------------ //

    error OnlyHook();
    error HookAlreadyBound();
    error NotBeneficiary();
    error ZeroAmount();
    error NothingToClaim();
    error NativeUnsupported();
    error CurrencyMismatch(PoolId poolId);

    // ------------------------------------------------------------------ //
    //                               Events                                //
    // ------------------------------------------------------------------ //

    event HookBound(address indexed hook);
    event Funded(PoolId indexed poolId, Currency indexed token, uint256 amount, uint256 stakeTotal);
    event Accrued(
        PoolId indexed poolId,
        address indexed beneficiary,
        address indexed positionOwner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint128 stake,
        uint256 settled
    );
    event Claimed(address indexed beneficiary, Currency indexed token, uint256 amount);

    constructor(IPoolManager manager_, address initialOwner) Ownable(initialOwner) {
        manager = manager_;
    }

    /// @notice Bind the RebateHook exactly once (deploy-time wiring; the hook's
    ///         CREATE2 address is mined after this contract exists).
    function bindHook(address hook_) external onlyOwner {
        if (hook != address(0) || hook_ == address(0)) revert HookAlreadyBound();
        hook = hook_;
        emit HookBound(hook_);
    }

    // ------------------------------------------------------------------ //
    //                            Hook entry point                         //
    // ------------------------------------------------------------------ //

    /// @notice Deposit captured profit for a pool's LPs (pull-based; the hook
    ///         approves this contract for `amount` first).
    /// @dev ERC-20 only — native-currency quotes are never routed here.
    function fund(PoolId poolId, Currency token, uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        if (amount == 0) revert ZeroAmount();
        if (token.isAddressZero()) revert NativeUnsupported();

        Currency existing = rewardCurrency[poolId];
        if (!existing.isAddressZero() && Currency.unwrap(existing) != Currency.unwrap(token)) {
            revert CurrencyMismatch(poolId);
        }
        rewardCurrency[poolId] = token;

        IERC20(Currency.unwrap(token)).safeTransferFrom(hook, address(this), amount);
        fundedTotal[token] += amount;

        uint256 total = stakeTotal[poolId];
        if (total == 0) {
            pendingRewards[poolId] += amount; // no participants yet — roll forward
            emit Funded(poolId, token, amount, 0);
            return;
        }

        uint256 rolled = pendingRewards[poolId];
        if (rolled > 0) {
            amount += rolled;
            pendingRewards[poolId] = 0;
        }
        cumulativePerStake[poolId] += (amount * PRECISION) / total;
        emit Funded(poolId, token, amount, total);
    }

    // ------------------------------------------------------------------ //
    //                            LP participation                         //
    // ------------------------------------------------------------------ //

    /// @notice Register / refresh an LP position and settle everything accrued
    ///         since the last accrue. Call after adding or removing liquidity
    ///         and periodically to checkpoint rewards.
    /// @param positionOwner the v4 position owner — either `msg.sender` holding
    ///        the position directly, or the router contract holding it (e.g.
    ///        SwapRouter per-user positions, where `salt` equals
    ///        `bytes32(uint160(msg.sender))`).
    function accrue(PoolId poolId, address positionOwner, int24 tickLower, int24 tickUpper, bytes32 salt) external {
        // the caller earns for this position only if they own it — either
        // outright, or through the standard per-user router position salt
        if (positionOwner != msg.sender && salt != bytes32(uint256(uint160(msg.sender)))) revert NotBeneficiary();

        PositionRecord storage r = records[poolId][positionOwner][tickLower][tickUpper][salt];
        uint256 cum = cumulativePerStake[poolId];

        // settle past index deltas against the OLD stake, then refresh it
        uint256 settled = 0;
        if (r.stake > 0) {
            settled = (uint256(r.stake) * (cum - r.checkpoint)) / PRECISION;
        }
        r.checkpoint = cum;

        (uint128 liveLiquidity,,) = manager.getPositionInfo(poolId, positionOwner, tickLower, tickUpper, salt);
        stakeTotal[poolId] = stakeTotal[poolId] - r.stake + liveLiquidity;
        r.stake = liveLiquidity;

        if (settled > 0) {
            Currency token = rewardCurrency[poolId];
            owed[msg.sender][token] += settled;
            owedOutstanding[token] += settled;
        }

        emit Accrued(poolId, msg.sender, positionOwner, tickLower, tickUpper, salt, liveLiquidity, settled);
    }

    // ------------------------------------------------------------------ //
    //                                Claims                               //
    // ------------------------------------------------------------------ //

    /// @notice Claim accrued compensation in `token` to `to`.
    function claim(Currency token, address to) external returns (uint256 amount) {
        amount = owed[msg.sender][token];
        if (amount == 0) revert NothingToClaim();

        owed[msg.sender][token] = 0;
        owedOutstanding[token] -= amount;
        paidTotal[token] += amount;
        IERC20(Currency.unwrap(token)).safeTransfer(to, amount);

        emit Claimed(msg.sender, token, amount);
    }

    // ------------------------------------------------------------------ //
    //                              Views                                  //
    // ------------------------------------------------------------------ //

    /// @notice Unsettled compensation for a registered position — what the next
    ///         `accrue` would settle right now.
    function pending(PoolId poolId, address positionOwner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint256)
    {
        PositionRecord storage r = records[poolId][positionOwner][tickLower][tickUpper][salt];
        if (r.stake == 0) return 0;
        return (uint256(r.stake) * (cumulativePerStake[poolId] - r.checkpoint)) / PRECISION;
    }

    /// @notice Fund solvency: everything funded is paid, owed, or held surplus.
    function isSolvent(Currency token) external view returns (bool) {
        return fundedTotal[token] >= paidTotal[token] + owedOutstanding[token];
    }
}
