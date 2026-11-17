// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RebateHook} from "../hook/RebateHook.sol";

/// @title SearcherRouter — batch entry point for the searcher network.
/// @notice Anyone may watch for divergence — including trades on external
///         venues that leave the pair's own pools stale — and trigger a capture
///         via the hook's permissionless backrun. The submitter earns the pair's
///         `searcherBps` commission of realized profit. This router exists to
///         batch submissions across pairs and to emit a stable, searchable event
///         surface for searchers and integrators; calling
///         `RebateHook.backrun(pair, searcher)` directly is equivalent.
/// @dev All capture guards still apply per pair: pauses, bounded route checks,
///      minimum profit, size caps, loss guard. Failed submissions cost the
///      submitter only gas — the hook skips unprofitable or paused pairs.
contract SearcherRouter {
    /// @notice Hard cap on pairs per submission (bounds gas).
    uint256 public constant MAX_PAIRS_PER_SUBMIT = 8;

    RebateHook public immutable hook;

    error TooManyPairs();

    event Submitted(address indexed searcher, bytes32[] pairIds);
    event SearcherBatchResult(address indexed searcher, bytes32 indexed pairId, bool ok);

    constructor(RebateHook hook_) {
        hook = hook_;
    }

    /// @notice Trigger captures for up to 8 pairs; the caller is the commission
    ///         beneficiary for every profitable capture executed.
    function submit(bytes32[] calldata pairIds) external {
        if (pairIds.length == 0 || pairIds.length > MAX_PAIRS_PER_SUBMIT) revert TooManyPairs();
        emit Submitted(msg.sender, pairIds);

        for (uint256 i = 0; i < pairIds.length; i++) {
            try hook.backrun(pairIds[i], msg.sender) {
                emit SearcherBatchResult(msg.sender, pairIds[i], true);
            } catch {
                // one bad pair must not abort the batch — the searcher paid gas,
                // the skip is recorded, nothing else changes
                emit SearcherBatchResult(msg.sender, pairIds[i], false);
            }
        }
    }
}
