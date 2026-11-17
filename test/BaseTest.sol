// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {RebateHook} from "../src/hook/RebateHook.sol";
import {PoolRegistry} from "../src/registry/PoolRegistry.sol";
import {PayoutLedger} from "../src/rewards/PayoutLedger.sol";
import {ILFund} from "../src/rewards/ILFund.sol";
import {SwapRouter} from "../src/periphery/SwapRouter.sol";
import {Create2Factory} from "../src/periphery/Create2Factory.sol";
import {ExternalAMMPool} from "../src/periphery/ExternalAMMPool.sol";
import {TestToken} from "../src/tokens/TestToken.sol";
import {WrappedNative} from "../src/tokens/WrappedNative.sol";

/// @notice Shared harness: full local v4 stack + protocol system + seeded demo pair.
abstract contract BaseTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ---- permission mask required by the hook (v4-core v4.0.0) ---- //
    // AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP = 0x10C0
    uint160 internal constant NEEDED_MASK = (1 << 12) | (1 << 7) | (1 << 6);
    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;
    /// @notice v4 dynamic-fee flag (LPFeeLibrary.DYNAMIC_FEE_FLAG)
    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;

    // ---- core v4 stack ---- //
    IPoolManager internal manager;
    WrappedNative internal wnt;

    // ---- protocol system ---- //
    PoolRegistry internal registry;
    PayoutLedger internal ledger;
    ILFund internal ilFund;
    RebateHook internal hook;
    SwapRouter internal router;
    Create2Factory internal factory;

    // ---- demo pair ---- //
    TestToken internal baseToken; // "BASE"
    TestToken internal quoteToken; // "QUOTE"
    PoolKey internal key1; // static fee 500
    PoolKey internal key2; // dynamic-fee pool (base 3000 / surge 10000)
    PoolId internal poolId1;
    PoolId internal poolId2;
    bytes32 internal pairId;

    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336; // 2^96 (price 1)
    int24 internal constant MIN_TICK = -887220;
    int24 internal constant MAX_TICK = 887220;

    address internal alice = makeAddr("alice"); // trader
    address internal bob = makeAddr("bob"); // LP / keeper
    uint256 internal constant LP_AMOUNT = 1e22; // 10k tokens (18d) per side per pool
    uint256 internal constant CAPITAL = 5e20;

    function setUp() public virtual {
        // ---- v4 stack ---- //
        wnt = new WrappedNative();
        manager = new PoolManager(address(this));

        // ---- protocol: registry → factory → ledger → (mine hook) → hook → bind ---- //
        registry = new PoolRegistry();
        factory = new Create2Factory();
        _deploySystem();

        // ---- demo tokens & pair ---- //
        baseToken = new TestToken("Base Token", "BASE", 18);
        quoteToken = new TestToken("Quote Token", "QUOTE", 18);
        baseToken.mint(address(this), 1e30);
        quoteToken.mint(address(this), 1e30);
        baseToken.mint(alice, 1e26);
        quoteToken.mint(alice, 1e26);
        baseToken.mint(bob, 1e26);
        quoteToken.mint(bob, 1e26);

        pairId = registry.pairId(Currency.wrap(address(baseToken)), Currency.wrap(address(quoteToken)));
        registry.registerPair(Currency.wrap(address(baseToken)), Currency.wrap(address(quoteToken)));

        (Currency c0, Currency c1) = _sorted(baseCurrency(), quoteCurrency());
        key1 = PoolKey({currency0: c0, currency1: c1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))});
        // dynamic-fee pool: PoolKey.fee flags dynamic; the hook's beforeSwap
        // returns baseFee (3000) or surgeFee (10000) per swap size
        key2 = PoolKey({
            currency0: c0, currency1: c1, fee: DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(address(hook))
        });

        manager.initialize(key1, SQRT_1_1);
        manager.initialize(key2, SQRT_1_1);
        poolId1 = key1.toId();
        poolId2 = key2.toId();

        // ---- seed liquidity (full range) via the router ---- //
        _seedLiquidity(key1, LP_AMOUNT, LP_AMOUNT);
        _seedLiquidity(key2, LP_AMOUNT, LP_AMOUNT);

        // ---- fund hook working capital ---- //
        quoteToken.approve(address(hook), type(uint256).max);
        hook.fundWorkingCapital(Currency.wrap(address(quoteToken)), CAPITAL);
    }

    /// @dev registry → factory → ledger → ILFund → CREATE2-mine the hook (mask
    ///      0x10C0) → bind.
    function _deploySystem() internal {
        ledger = new PayoutLedger(address(this));
        ilFund = new ILFund(manager, address(this));

        bytes memory initCode = abi.encodePacked(
            type(RebateHook).creationCode,
            abi.encode(manager, registry, address(ledger), address(ilFund), address(this))
        );
        bytes32 salt = _mineSalt(keccak256(initCode));
        address hookAddr = factory.deploy(initCode, salt);
        hook = RebateHook(hookAddr);
        assertEq(uint160(hookAddr) & ALL_HOOK_MASK, NEEDED_MASK, "hook mask mismatch");

        ledger.bindHook(hookAddr);
        ilFund.bindHook(hookAddr);
        registry.setHook(hookAddr);
        router = new SwapRouter(manager);
    }

    function _mineSalt(bytes32 codeHash) internal view returns (bytes32) {
        for (uint256 i = 0; i < 2_000_000; i++) {
            bytes32 salt = keccak256(abi.encode("rebate-hook", i));
            address predicted = factory.predictAddress(salt, codeHash);
            if (uint160(predicted) & ALL_HOOK_MASK == NEEDED_MASK) {
                return salt;
            }
        }
        revert("salt mining failed");
    }

    function _sorted(Currency a, Currency b) internal pure returns (Currency, Currency) {
        return Currency.unwrap(a) < Currency.unwrap(b) ? (a, b) : (b, a);
    }

    function _seedLiquidity(PoolKey memory key, uint256 amount0, uint256 amount1) internal {
        baseToken.approve(address(router), type(uint256).max);
        quoteToken.approve(address(router), type(uint256).max);
        router.addLiquidity(key, MIN_TICK, MAX_TICK, amount0, amount1, 0, type(uint64).max);
    }

    // ---- helpers ---- //
    function _doSwap(PoolKey memory key, bool zeroForOne, uint256 amountIn, address swapper)
        internal
        returns (uint256 amountOut)
    {
        vm.startPrank(swapper);
        Currency currencyIn = zeroForOne ? key.currency0 : key.currency1;
        ERC20(Currency.unwrap(currencyIn)).approve(address(router), type(uint256).max);
        amountOut = router.swapExactIn(key, zeroForOne, amountIn, 0, type(uint64).max);
        vm.stopPrank();
    }

    /// @notice BUY base: quote in, base out — direction derived from the key.
    function _buyBase(PoolKey memory key, uint256 quoteAmount, address swapper) internal returns (uint256 baseOut) {
        bool zeroForOne = Currency.unwrap(key.currency0) == Currency.unwrap(quoteCurrency());
        baseOut = _doSwap(key, zeroForOne, quoteAmount, swapper);
    }

    /// @notice SELL base: base in, quote out.
    function _sellBase(PoolKey memory key, uint256 baseAmount, address swapper) internal returns (uint256 quoteOut) {
        bool zeroForOne = Currency.unwrap(key.currency0) == Currency.unwrap(baseCurrency());
        quoteOut = _doSwap(key, zeroForOne, baseAmount, swapper);
    }

    /// @notice move pool prices apart so the next swap has divergence to capture.
    function _createDivergence(uint256 sizeQuote) internal {
        // buy base in pool1 only → pool1 base price rises vs pool2; done while
        // paused so no capture eats the divergence
        registry.setSystemPaused(true);
        _buyBase(key1, sizeQuote, alice);
        registry.setSystemPaused(false);
    }

    function quoteCurrency() internal view returns (Currency) {
        return Currency.wrap(address(quoteToken));
    }

    function baseCurrency() internal view returns (Currency) {
        return Currency.wrap(address(baseToken));
    }
}
