// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./BaseTest.sol";
import {ILFund} from "../src/rewards/ILFund.sol";
import {PoolRegistry} from "../src/registry/PoolRegistry.sol";
import {RebateHook} from "../src/hook/RebateHook.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract ILFundTest is BaseTest {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice the full-range position this test contract seeded through the
    ///         SwapRouter in BaseTest: owner = router, salt = this contract.
    bytes32 internal routerSalt;

    function setUp() public override {
        super.setUp();
        routerSalt = bytes32(uint256(uint160(address(this))));
    }

    /// @notice hook-path funding: capture with ilBps set funds the ILFund
    function _captureWithIL(uint16 ilBps) internal returns (uint256 profit) {
        PoolRegistry.PairParams memory p = registry.getPair(pairId).params;
        p.ilBps = ilBps;
        registry.setPairParams(pairId, p);

        _createDivergence(1e20);
        uint256 before = ilFund.fundedTotal(quoteCurrency());
        _buyBase(key2, 1e18, alice);
        profit = ilFund.fundedTotal(quoteCurrency()) - before;
    }

    // ---------------------------------------------------------------- //
    // IL-1: fund → accrue → pending grows → claim pays exactly
    // ---------------------------------------------------------------- //
    function test_IL1_fundAccrueClaim() public {
        uint256 firstFund = _captureWithIL(1000);
        assertGt(firstFund, 0, "no IL funding");

        // LP (this contract) registers its router-held position
        ilFund.accrue(poolId1, address(router), MIN_TICK, MAX_TICK, routerSalt);
        assertEq(ilFund.stakeTotal(poolId1), manager.getLiquidity(poolId1));

        // second capture accrues index against the registered stake
        uint256 secondFund = _captureWithIL(1000);
        assertGt(secondFund, 0);

        // pending = stake · Δindex — the first funding (before any stake) rolled
        // forward and was folded into the index by the second funding event, so
        // this LP (sole staker of pool1) has accrued both pool1 shares
        uint256 expectPool1Share = firstFund / 2 + secondFund / 2;
        assertApproxEqRel(
            ilFund.pending(poolId1, address(router), MIN_TICK, MAX_TICK, routerSalt), expectPool1Share, 1e15
        );

        uint256 settled = ilFund.pending(poolId1, address(router), MIN_TICK, MAX_TICK, routerSalt);
        ilFund.accrue(poolId1, address(router), MIN_TICK, MAX_TICK, routerSalt);
        assertEq(ilFund.owed(address(this), quoteCurrency()), settled, "second accrue should settle pending");
        assertEq(ilFund.pending(poolId1, address(router), MIN_TICK, MAX_TICK, routerSalt), 0, "pending not zeroed");

        uint256 before = quoteToken.balanceOf(address(this));
        ilFund.claim(quoteCurrency(), address(this));
        assertGt(quoteToken.balanceOf(address(this)), before);
        assertTrue(ilFund.isSolvent(quoteCurrency()));
    }

    // ---------------------------------------------------------------- //
    // IL-2: only the position beneficiary can accrue
    // ---------------------------------------------------------------- //
    function test_IL2_beneficiaryCheck() public {
        // bob cannot accrue for a position salted to this contract
        vm.prank(bob);
        vm.expectRevert(ILFund.NotBeneficiary.selector);
        ilFund.accrue(poolId1, address(router), MIN_TICK, MAX_TICK, routerSalt);

        // the owner itself (positionOwner == msg.sender) is fine
        ilFund.accrue(poolId1, address(this), MIN_TICK, MAX_TICK, bytes32(0));
    }

    // ---------------------------------------------------------------- //
    // IL-3: funding before any stake rolls forward to the next funded event
    // ---------------------------------------------------------------- //
    function test_IL3_pendingRollForward() public {
        uint256 first = _captureWithIL(1000); // nobody accrued yet → pending
        assertEq(ilFund.pendingRewards(poolId1), first / 2);

        ilFund.accrue(poolId1, address(router), MIN_TICK, MAX_TICK, routerSalt); // register

        uint256 second = _captureWithIL(1000);
        assertEq(ilFund.pendingRewards(poolId1), 0, "pending should be folded in");

        // the second funding event folded the rolled-forward first share in, and
        // this LP (sole staker, registered before it) earns all of it
        uint256 expect = first / 2 + second / 2;
        assertApproxEqRel(ilFund.pending(poolId1, address(router), MIN_TICK, MAX_TICK, routerSalt), expect, 1e15);
    }

    // ---------------------------------------------------------------- //
    // IL-4: nothing to claim reverts
    // ---------------------------------------------------------------- //
    function test_IL4_nothingToClaim() public {
        vm.expectRevert(ILFund.NothingToClaim.selector);
        ilFund.claim(quoteCurrency(), address(this));
    }

    // ---------------------------------------------------------------- //
    // IL-5: only the hook can fund
    // ---------------------------------------------------------------- //
    function test_IL5_onlyHookFunds() public {
        quoteToken.approve(address(ilFund), 1e18);
        vm.expectRevert(ILFund.OnlyHook.selector);
        ilFund.fund(poolId1, quoteCurrency(), 1e18);
    }
}
