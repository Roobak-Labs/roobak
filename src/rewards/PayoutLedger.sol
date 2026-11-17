// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

using SafeERC20 for IERC20;

/// @title PayoutLedger — captured-value accounting & escrow.
/// @notice Mirrors the reference architecture's "Payout ledger": records trader and
///         pool shares and **can never pay more than it captured**. The ledger is the
///         token holder of record — the hook deposits realized profit here before any
///         credit is created, so claims are always fully reserved.
/// @dev Written exclusively by the hook. Users claim their own rebates; the hook
///      releases pool credits back to itself for LP distribution via v4 `donate`.
contract PayoutLedger is Ownable {
    using CurrencyLibrary for Currency;

    // ------------------------------------------------------------------ //
    //                              Storage                                //
    // ------------------------------------------------------------------ //

    /// @notice the RebateHook — sole writer (bound once after hook deployment)
    address public hook;

    /// @notice accrued, unclaimed trader rebates: user → token → amount
    mapping(address user => mapping(Currency token => uint256)) public traderCredits;

    /// @notice accrued, undistributed LP rewards per pool
    mapping(PoolId poolId => uint256) public poolCredits;
    /// @notice the currency in which a pool's rewards accrue (set on first accrual)
    mapping(PoolId poolId => Currency) public poolRewardCurrency;

    // --- solvency accounting: for every token,
    //     capturedTotal == rebatesOutstanding + poolOutstanding (exact, at rest) --- //
    mapping(Currency token => uint256) public capturedTotal;
    mapping(Currency token => uint256) public rebatesOutstanding;
    mapping(Currency token => uint256) public poolOutstanding;

    // --- lifetime totals (diagnostics) --- //
    mapping(Currency token => uint256) public rebatesClaimedTotal;
    mapping(PoolId poolId => uint256) public poolDistributedTotal;
    mapping(bytes32 pairId => uint256) public pairCapturedTotal;

    // ------------------------------------------------------------------ //
    //                               Errors                                //
    // ------------------------------------------------------------------ //

    error OnlyHook();
    error HookAlreadyBound();
    error LedgerOverdraft();
    error ZeroAmount();
    error NothingToClaim();
    error NothingToDistribute();
    error CurrencyMismatch(PoolId poolId);
    error TransferFailed();
    error BadSplit();

    // ------------------------------------------------------------------ //
    //                               Events                                //
    // ------------------------------------------------------------------ //

    event CaptureRecorded(
        bytes32 indexed pairId,
        Currency indexed quote,
        address indexed trader,
        uint256 captured,
        uint256 traderShare,
        PoolId[4] pools,
        uint256[4] poolShares
    );
    event RebateClaimed(address indexed user, Currency indexed token, uint256 amount);
    event PoolRewardsReleased(PoolId indexed poolId, uint256 amount);

    // ------------------------------------------------------------------ //
    //                             Constructor                             //
    // ------------------------------------------------------------------ //

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Bind the RebateHook exactly once (deploy-time wiring; breaks the
    ///         hook↔ledger constructor cycle since the hook's CREATE2 address is
    ///         mined after the ledger exists).
    function bindHook(address hook_) external onlyOwner {
        if (hook != address(0) || hook_ == address(0)) revert HookAlreadyBound();
        hook = hook_;
    }

    // ------------------------------------------------------------------ //
    //                            Hook entry points                        //
    // ------------------------------------------------------------------ //

    /// @notice Record a completed capture: escrow the tokens, then create credits.
    /// @dev `pools`/`poolShares` length 4: [pairPool1, pairPool2, protocolPool1,
    ///      protocolPool2]; shares in the same units as `traderShare`.
    ///      The hook must have approved the ledger for `traderShare + Σ poolShares`.
    function onCapture(
        bytes32 pairId,
        Currency quote,
        address trader,
        uint256 traderShare,
        PoolId[4] calldata pools,
        uint256[4] calldata poolShares
    ) external {
        if (msg.sender != hook) revert OnlyHook();

        uint256 total = traderShare;
        for (uint256 i = 0; i < 4; i++) {
            // pool slots with zero share may carry PoolId(0) (folded configuration)
            if (poolShares[i] > 0 && PoolId.unwrap(pools[i]) == 0) revert BadSplit();
            total += poolShares[i];
        }
        if (total == 0) revert ZeroAmount();

        // escrow first — credits are always fully reserved
        IERC20(Currency.unwrap(quote)).safeTransferFrom(hook, address(this), total);

        // solvency accounting
        capturedTotal[quote] += total;
        rebatesOutstanding[quote] += traderShare;
        poolOutstanding[quote] += total - traderShare;
        pairCapturedTotal[pairId] += total;

        // credits
        if (traderShare > 0) {
            traderCredits[trader][quote] += traderShare;
        }
        for (uint256 i = 0; i < 4; i++) {
            if (poolShares[i] > 0) {
                Currency existing = poolRewardCurrency[pools[i]];
                if (Currency.unwrap(existing) != address(0) && Currency.unwrap(existing) != Currency.unwrap(quote)) {
                    revert CurrencyMismatch(pools[i]);
                }
                poolRewardCurrency[pools[i]] = quote;
                poolCredits[pools[i]] += poolShares[i];
            }
        }

        emit CaptureRecorded(pairId, quote, trader, total, traderShare, pools, poolShares);
    }

    /// @notice Move a pool's undistributed rewards back to the hook for `donate`.
    function releaseToHook(PoolId poolId, uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        if (amount == 0) revert ZeroAmount();
        uint256 credit = poolCredits[poolId];
        if (credit < amount) revert LedgerOverdraft();

        Currency quote = poolRewardCurrency[poolId];
        poolCredits[poolId] = credit - amount;
        poolOutstanding[quote] -= amount;
        poolDistributedTotal[poolId] += amount;
        IERC20(Currency.unwrap(quote)).safeTransfer(hook, amount);

        emit PoolRewardsReleased(poolId, amount);
    }

    // ------------------------------------------------------------------ //
    //                              User claims                            //
    // ------------------------------------------------------------------ //

    /// @notice Claim accrued rebates in `token` to `to`.
    function claim(Currency token, address to) external returns (uint256 amount) {
        amount = traderCredits[msg.sender][token];
        if (amount == 0) revert NothingToClaim();

        traderCredits[msg.sender][token] = 0;
        rebatesOutstanding[token] -= amount;
        rebatesClaimedTotal[token] += amount;
        IERC20(Currency.unwrap(token)).safeTransfer(to, amount);

        emit RebateClaimed(msg.sender, token, amount);
    }

    // ------------------------------------------------------------------ //
    //                            Views / invariant                        //
    // ------------------------------------------------------------------ //

    /// @notice Ledger solvency: credits outstanding must always be covered by
    ///         captured value still held (or already reserved for distribution).
    function isSolvent(Currency token) external view returns (bool) {
        return capturedTotal[token] >= rebatesOutstanding[token] + poolOutstanding[token];
    }
}
