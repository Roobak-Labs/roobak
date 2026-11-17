// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IExternalVenue} from "../interfaces/IExternalVenue.sol";

/// @title PoolRegistry — the pool list.
/// @notice Single source of truth for the pools, venues and parameters the capture
///         engine is allowed to use. Mirrors the reference architecture's "Pool list"
///         module: approved pairs, paired v4 pools, external venues, protocol pools,
///         pause switches.
contract PoolRegistry is Ownable {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------ //
    //                              Constants                              //
    // ------------------------------------------------------------------ //

    /// @notice Hard cap on external venues per pair.
    uint256 public constant MAX_VENUES_PER_PAIR = 4;
    /// @notice Hard cap on route checks per capture (bounds afterSwap work).
    uint8 public constant MAX_ROUTE_CHECKS_HARD = 16;
    /// @notice Hard cap on executed cycles per capture.
    uint8 public constant MAX_CYCLES_HARD = 4;
    /// @notice Hard cap on trader share bps.
    uint16 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Hard cap on an LP fee (hundredths of a bip) — mirrors v4 MAX_LP_FEE.
    uint24 public constant MAX_LP_FEE = 1_000_000;

    // ------------------------------------------------------------------ //
    //                              Types                                  //
    // ------------------------------------------------------------------ //

    struct PairParams {
        // payout split, bips of captured profit
        uint16 traderShareBuyBps; // default 4000 (40%)
        uint16 traderShareSellBps; // default 1000 (10%)
        // V2 searcher network: bounty for searcher/keeper-triggered captures
        uint16 searcherBps; // default 1000 (10%) of realized profit
        // V2 LP yield engine: LP-side carve-out routed into the IL fund
        uint16 ilBps; // default 0 (disabled); bips of the LP share
        // LP-side split, bips of the LP share; must sum to 10_000
        uint16 lpPool1Bps; // default 3500 (35%) paired pool 1 (third-party pool 1)
        uint16 lpPool2Bps; // default 3500 (35%) paired pool 2 (third-party pool 2)
        uint16 lpProtocol1Bps; // default 1500 (15%) protocol pool 1
        uint16 lpProtocol2Bps; // default 1500 (15%) protocol pool 2
        // capture bounds
        uint256 minProfitQuote; // minimum realized profit to pay out
        uint256 maxTradeSizeQuote; // absolute per-cycle cap (quote units)
        uint16 maxSizeBpsOfLiquidity; // cycle size <= this bips of venue quote-liquidity
        uint16 baseDustToleranceBps; // allowed base-balance drift per cycle
        uint256 maxLossGuardQuote; // realized loss beyond this trips the breaker
        uint8 maxRouteChecks; // bounded estimation per capture
        uint8 maxCyclesPerSwap; // bounded executions per capture
        // V2 dynamic-fee schedule (applies only to paired pools created with
        // PoolKey.fee == DYNAMIC_FEE_FLAG; static-fee pools ignore these)
        uint24 baseFee; // default 3000 (0.3%), hundredths of a bip
        uint24 surgeFee; // default 10000 (1.0%) when a swap exceeds surgeThreshold
        uint256 surgeThreshold; // per-swap threshold in the swap's input-token units
    }

    struct PairConfig {
        Currency base;
        Currency quote;
        // paired v4 pools (both governed by the hook)
        PoolId pool1;
        PoolKey key1;
        PoolId pool2;
        PoolKey key2;
        bool capturePaused;
        address[] venues; // IExternalVenue implementations
        PairParams params;
    }

    // ------------------------------------------------------------------ //
    //                              Storage                                //
    // ------------------------------------------------------------------ //

    mapping(bytes32 pairId => PairConfig) private _pairs;
    bytes32[] public pairList;
    /// @notice v4 pool id => pair id (only attached — i.e. approved — pools)
    mapping(PoolId poolId => bytes32) public poolToPair;
    /// @notice v4 pool id => pool key (attached pools + protocol pools)
    mapping(PoolId poolId => PoolKey) public poolKeyOf;

    /// @notice protocol pools receiving the 15%/15% LP-side shares
    PoolKey[] private _protocolPoolKeys;

    bool public systemPaused;
    bool public distributionPaused;

    /// @notice the RebateHook — sole caller of `attachPool`
    address public hook;

    // ------------------------------------------------------------------ //
    //                               Errors                                //
    // ------------------------------------------------------------------ //

    error PairExists();
    error PairNotFound();
    error BadPair();
    error ZeroAddress();
    error NotHook();
    error HookAlreadySet();
    error BadPoolKey();
    error PoolsFull();
    error DuplicatePool();
    error BadParams();
    error TooManyVenues();
    error BadVenue();
    error VenueNotFound();
    error NotTwoProtocolPools();
    error TooManyRouteChecks();
    error TooManyCycles();

    // ------------------------------------------------------------------ //
    //                               Events                                //
    // ------------------------------------------------------------------ //

    event PairRegistered(bytes32 indexed pairId, Currency indexed base, Currency indexed quote);
    event PairParamsUpdated(bytes32 indexed pairId);
    event PairedPoolsSet(bytes32 indexed pairId, PoolId pool1, PoolId pool2);
    event PoolAutoPaired(bytes32 indexed pairId, uint8 slot, PoolId poolId);
    event PoolAttachIgnored(bytes32 indexed pairId, uint8 reason); // 1=noPair 2=mismatch 3=full 4=dup
    event VenueRegistered(bytes32 indexed pairId, address indexed venue);
    event VenueRemoved(bytes32 indexed pairId, address indexed venue);
    event ProtocolPoolsSet(PoolKey key1, PoolKey key2);
    event SystemPauseSet(bool paused);
    event PairCapturePauseSet(bytes32 indexed pairId, bool paused);
    event DistributionPauseSet(bool paused);
    event HookBound(address indexed hook);

    // ------------------------------------------------------------------ //
    //                             Constructor                             //
    // ------------------------------------------------------------------ //

    constructor() Ownable(msg.sender) {}

    /// @notice Bind the hook (once) — called right after hook deployment.
    function setHook(address hook_) external onlyOwner {
        if (hook_ == address(0)) revert ZeroAddress();
        if (hook != address(0)) revert HookAlreadySet();
        hook = hook_;
        emit HookBound(hook_);
    }

    // ------------------------------------------------------------------ //
    //                          Pair administration                        //
    // ------------------------------------------------------------------ //

    /// @notice Compute the canonical pair id for a currency pair (order-independent).
    function pairId(Currency a, Currency b) public pure returns (bytes32) {
        (Currency lo, Currency hi) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encodePacked(Currency.unwrap(lo), Currency.unwrap(hi)));
    }

    function registerPair(Currency base, Currency quote) external onlyOwner returns (bytes32 id) {
        if (Currency.unwrap(base) == Currency.unwrap(quote) || base.isAddressZero() || quote.isAddressZero()) {
            revert BadPair();
        }
        if (Currency.unwrap(base).code.length == 0 || Currency.unwrap(quote).code.length == 0) {
            revert BadPair();
        }
        id = pairId(base, quote);
        if (Currency.unwrap(_pairs[id].base) != address(0) || Currency.unwrap(_pairs[id].quote) != address(0)) {
            revert PairExists();
        }
        // overflow-safe: 4000/1000, 3500/3500/1500/1500, searcher 1000, IL 0
        PairParams memory defaults = PairParams({
            traderShareBuyBps: 4000,
            traderShareSellBps: 1000,
            searcherBps: 1000,
            ilBps: 0,
            lpPool1Bps: 3500,
            lpPool2Bps: 3500,
            lpProtocol1Bps: 1500,
            lpProtocol2Bps: 1500,
            minProfitQuote: 1e14,
            maxTradeSizeQuote: 1e22,
            maxSizeBpsOfLiquidity: 25,
            baseDustToleranceBps: 10,
            maxLossGuardQuote: 1e18,
            maxRouteChecks: 8,
            maxCyclesPerSwap: 2,
            baseFee: 3000,
            surgeFee: 10_000,
            surgeThreshold: 1e21
        });
        _pairs[id] = PairConfig({
            base: base,
            quote: quote,
            pool1: PoolId.wrap(0),
            key1: PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            }),
            pool2: PoolId.wrap(0),
            key2: PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(0)),
                fee: 0,
                tickSpacing: 0,
                hooks: IHooks(address(0))
            }),
            capturePaused: false,
            venues: new address[](0),
            params: defaults
        });
        pairList.push(id);
        emit PairRegistered(id, base, quote);
    }

    function setPairParams(bytes32 id, PairParams calldata p) external onlyOwner {
        _requirePair(id);
        if (p.traderShareBuyBps > BPS_DENOMINATOR || p.traderShareSellBps > BPS_DENOMINATOR) {
            revert BadParams();
        }
        if (p.searcherBps > BPS_DENOMINATOR || p.ilBps > BPS_DENOMINATOR) revert BadParams();
        uint256 lpSum = uint256(p.lpPool1Bps) + p.lpPool2Bps + p.lpProtocol1Bps + p.lpProtocol2Bps;
        if (lpSum != BPS_DENOMINATOR) revert BadParams();
        if (p.maxRouteChecks == 0 || p.maxRouteChecks > MAX_ROUTE_CHECKS_HARD) revert TooManyRouteChecks();
        if (p.maxCyclesPerSwap == 0 || p.maxCyclesPerSwap > MAX_CYCLES_HARD) revert TooManyCycles();
        if (p.maxSizeBpsOfLiquidity == 0 || p.maxSizeBpsOfLiquidity > BPS_DENOMINATOR) revert BadParams();
        if (p.baseDustToleranceBps > 1000) revert BadParams();
        // dynamic-fee schedule sanity (applies only to dynamic-fee pools of the pair)
        if (p.baseFee > MAX_LP_FEE || p.surgeFee > MAX_LP_FEE || p.surgeFee < p.baseFee) revert BadParams();
        if (p.surgeThreshold == 0) revert BadParams();
        _pairs[id].params = p;
        emit PairParamsUpdated(id);
    }

    /// @notice Explicitly bind the two paired pools (alternative to auto-pairing).
    function setPairedPools(bytes32 id, PoolKey calldata key1_, PoolKey calldata key2_) external onlyOwner {
        _requirePair(id);
        _validatePoolKey(id, key1_);
        _validatePoolKey(id, key2_);
        if (key1_.fee == key2_.fee && key1_.tickSpacing == key2_.tickSpacing) revert BadPoolKey();
        PairConfig storage cfg = _pairs[id];
        cfg.key1 = key1_;
        cfg.pool1 = key1_.toId();
        cfg.key2 = key2_;
        cfg.pool2 = key2_.toId();
        poolToPair[key1_.toId()] = id;
        poolToPair[key2_.toId()] = id;
        poolKeyOf[key1_.toId()] = key1_;
        poolKeyOf[key2_.toId()] = key2_;
        emit PairedPoolsSet(id, cfg.pool1, cfg.pool2);
    }

    /// @notice Called by the hook when a pool initialized with the hook address.
    ///         Auto-pairs the pool into slot 1 or 2 when the pair matches.
    function attachPool(PoolKey calldata key) external {
        if (msg.sender != hook) revert NotHook();
        bytes32 id = pairId(key.currency0, key.currency1);
        PairConfig storage cfg = _pairs[id];
        if (cfg.base == Currency.wrap(address(0))) {
            emit PoolAttachIgnored(id, 1); // pair not registered
            return;
        }
        _validatePoolKey(id, key); // reverts on mismatch (hook-guaranteed currencies)
        PoolId poolId_ = key.toId();
        if (PoolId.unwrap(cfg.pool1) == 0) {
            cfg.pool1 = poolId_;
            cfg.key1 = key;
            poolToPair[poolId_] = id;
            poolKeyOf[poolId_] = key;
            emit PoolAutoPaired(id, 1, poolId_);
        } else if (PoolId.unwrap(cfg.pool2) == 0) {
            if (cfg.key1.fee == key.fee && cfg.key1.tickSpacing == key.tickSpacing) {
                emit PoolAttachIgnored(id, 4); // duplicate configuration
                return;
            }
            cfg.pool2 = poolId_;
            cfg.key2 = key;
            poolToPair[poolId_] = id;
            poolKeyOf[poolId_] = key;
            emit PoolAutoPaired(id, 2, poolId_);
        } else {
            emit PoolAttachIgnored(id, 3); // both slots taken
        }
    }

    function _validatePoolKey(bytes32 id, PoolKey calldata key) internal view {
        PairConfig storage cfg = _pairs[id];
        // currencies must be exactly the pair's {base, quote} (PoolKey sorts internally)
        bool baseQuote =
            (Currency.unwrap(key.currency0) == Currency.unwrap(cfg.base)
                    && Currency.unwrap(key.currency1) == Currency.unwrap(cfg.quote))
                || (Currency.unwrap(key.currency0) == Currency.unwrap(cfg.quote)
                    && Currency.unwrap(key.currency1) == Currency.unwrap(cfg.base));
        if (!baseQuote) revert BadPoolKey();
        if (address(key.hooks) != hook) revert BadPoolKey();
    }

    // ------------------------------------------------------------------ //
    //                          Venue administration                       //
    // ------------------------------------------------------------------ //

    function registerVenue(bytes32 id, address venue) external onlyOwner {
        _requirePair(id);
        PairConfig storage cfg = _pairs[id];
        if (cfg.venues.length >= MAX_VENUES_PER_PAIR) revert TooManyVenues();
        if (venue == address(0) || venue.code.length == 0) revert BadVenue();
        IExternalVenue v = IExternalVenue(venue);
        Currency t0 = v.token0();
        Currency t1 = v.token1();
        bool ok = (Currency.unwrap(t0) == Currency.unwrap(cfg.base)
                && Currency.unwrap(t1) == Currency.unwrap(cfg.quote))
            || (Currency.unwrap(t0) == Currency.unwrap(cfg.quote) && Currency.unwrap(t1) == Currency.unwrap(cfg.base));
        if (!ok || Currency.unwrap(t0) == Currency.unwrap(t1)) revert BadVenue();
        for (uint256 i = 0; i < cfg.venues.length; i++) {
            if (cfg.venues[i] == venue) revert BadVenue();
        }
        cfg.venues.push(venue);
        emit VenueRegistered(id, venue);
    }

    function removeVenue(bytes32 id, address venue) external onlyOwner {
        _requirePair(id);
        address[] storage list = _pairs[id].venues;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == venue) {
                list[i] = list[list.length - 1];
                list.pop();
                emit VenueRemoved(id, venue);
                return;
            }
        }
        revert VenueNotFound();
    }

    // ------------------------------------------------------------------ //
    //                         Protocol pools / pauses                     //
    // ------------------------------------------------------------------ //

    /// @notice Set the two protocol pools receiving lpProtocol1Bps / lpProtocol2Bps.
    /// @dev Keys must be initialized pools governed by the hook, but need not belong
    ///      to any registered pair (the protocol's own pair pools).
    function setProtocolPools(PoolKey calldata key1_, PoolKey calldata key2_) external onlyOwner {
        if (address(key1_.hooks) != hook || address(key2_.hooks) != hook) revert BadPoolKey();
        if (PoolId.unwrap(key1_.toId()) == PoolId.unwrap(key2_.toId())) revert BadPoolKey();
        delete _protocolPoolKeys;
        _protocolPoolKeys.push(key1_);
        _protocolPoolKeys.push(key2_);
        poolKeyOf[key1_.toId()] = key1_;
        poolKeyOf[key2_.toId()] = key2_;
        emit ProtocolPoolsSet(key1_, key2_);
    }

    function setSystemPaused(bool paused_) external onlyOwner {
        systemPaused = paused_;
        emit SystemPauseSet(paused_);
    }

    /// @notice Emergency stop callable by the hook itself (loss-guard circuit breaker).
    function emergencyPause() external {
        if (msg.sender != hook && msg.sender != owner()) revert NotHook();
        if (!systemPaused) {
            systemPaused = true;
            emit SystemPauseSet(true);
        }
    }

    function setPairCapturePaused(bytes32 id, bool paused_) external onlyOwner {
        _requirePair(id);
        _pairs[id].capturePaused = paused_;
        emit PairCapturePauseSet(id, paused_);
    }

    function setDistributionPaused(bool paused_) external onlyOwner {
        distributionPaused = paused_;
        emit DistributionPauseSet(paused_);
    }

    // ------------------------------------------------------------------ //
    //                                Views                                //
    // ------------------------------------------------------------------ //

    function getPair(bytes32 id) external view returns (PairConfig memory) {
        return _pairs[id];
    }

    function isPair(bytes32 id) public view returns (bool) {
        return Currency.unwrap(_pairs[id].base) != address(0);
    }

    function isApprovedPool(PoolId poolId_) public view returns (bool) {
        return poolToPair[poolId_] != bytes32(0);
    }

    function venueCount(bytes32 id) external view returns (uint256) {
        return _pairs[id].venues.length;
    }

    function venueAt(bytes32 id, uint256 i) external view returns (address) {
        return _pairs[id].venues[i];
    }

    function protocolPoolKeys() external view returns (PoolKey[] memory) {
        return _protocolPoolKeys;
    }

    /// @notice Full PoolKey lookup (public mapping getter flattens structs).
    function getPoolKey(PoolId poolId_) external view returns (PoolKey memory) {
        return poolKeyOf[poolId_];
    }

    function protocolPoolCount() external view returns (uint256) {
        return _protocolPoolKeys.length;
    }

    function _requirePair(bytes32 id) internal view {
        if (!isPair(id)) revert PairNotFound();
    }
}
