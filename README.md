# Roobak — Uniswap v4 Swap-Rebate Hook

> **Every swap pays you back.**

![Solidity](https://img.shields.io/badge/Solidity-%5E0.8.26-363636?logo=solidity)
![EVM](https://img.shields.io/badge/EVM-Cancun-627EEA?logo=ethereum)
![Framework](https://img.shields.io/badge/Built%20with-Foundry-6C5CE7)
![Uniswap](https://img.shields.io/badge/Uniswap-v4%20Hook-FF007A)
![Tests](https://img.shields.io/badge/tests-63%2F63-brightgreen)
![License](https://img.shields.io/badge/License-MIT-green)

Roobak is a [Uniswap v4](https://v4.uniswap.org/) hook that **backruns the price
divergence every swap creates — atomically, inside the same transaction, before
outside bots can — and returns the realized profit to the people who created
it**: the trader and the liquidity providers.

Instead of letting external arbitrageurs capture the spread a trade leaves
behind, the hook performs the closing cycle itself, measures the **realized**
profit on-chain, and splits it:

| Trade direction | Trader rebate | Liquidity providers |
|---|---|---|
| **BUY** (trader receives base) | **40%** | **60%** |
| **SELL** (trader receives quote) | **10%** | **90%** |

The LP side is further split **35% / 35% / 15% / 15%** across the two paired
pools and the two protocol pools (defaults; every parameter is
owner-configurable per pair).

**No captured profit → no payout.** Payments are computed exclusively from
completed, positive, realized cycles — estimates are never trusted, and a
failed capture can never revert the trader's swap.

---

## Table of Contents

- [V2 Extensions](#v2-extensions)
- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [Repository Layout](#repository-layout)
- [Getting Started](#getting-started)
- [Testing](#testing)
- [Deployment](#deployment)
- [Configuration](#configuration)
- [Security Model](#security-model)
- [Disclaimer](#disclaimer)
- [License](#license)

---

## V2 Extensions

All V2 features feed the same realized-profit escrow — commissions, bounties
and compensation are carved out of the captured split, never minted from
nowhere.

- **Searcher network** — anyone can trigger captures through
  `SearcherRouter.submit` (batches of up to 8 pairs) and earn a `searcherBps`
  commission (default 10% of realized profit). Leftover divergence that the
  same-transaction backrun could not capture profitably is picked up by
  keepers in a later block.
- **Conditional orders** — escrowed limit/stop orders on the `OrderBook` with
  permissionless fills. A fill routes the placer's address through the swap
  hook data, so **the placer earns a capture rebate on their own fill**;
  fillers receive a small bounty from the same realized pot.
- **LP yield engine** — dynamic-fee pools running the hook's `beforeSwap`
  base/surge schedule (the hook's own capture legs are exempt), plus an
  **ILFund**: a configurable `ilBps` of every capture's LP side compensates
  LPs weighted by live position liquidity × time, under exactly-solvent
  accounting.
- **Batch auction venue** — *experimental* uniform-price batch settlement
  (`BatchAuctionPool`), dual-mode with the standard external-venue interface.
  Not registered anywhere by default.

## How It Works

Every swap pushes the pool it touched away from every other venue quoting the
same pair. Roobak captures that gap in the same transaction:

1. **Trigger** — the hook's `afterSwap` fires on every user swap in an
   attached pool. A transient-storage reentrancy guard
   (`tload`/`tstore`, Cancun) ensures the hook never backruns its own backrun.
2. **Isolation** — the capture runs through a `try/catch` boundary: any
   failure inside the capture loop emits a `CaptureSkipped` event and **never
   reverts the trader's swap**.
3. **Venue snapshot** — the engine collects a bounded set of venues: the
   pair's two paired v4 pools plus up to four registry-approved external
   venues (`IExternalVenue`), normalizing each to a base-per-quote price and
   a quote-liquidity figure.
4. **Plan** — `RouteChecker` enumerates the cheap→rich combinations within
   the pair's `maxRouteChecks` bound and picks the best cycle using a
   closed-form constant-product estimate.
5. **Caps** — the cycle size is capped by `maxTradeSizeQuote`, by
   `maxSizeBpsOfLiquidity` of the thinner venue's quote-liquidity, and by the
   working capital the hook actually holds.
6. **Execute** — `SwapExecutor` runs the buy-low / sell-high legs through the
   v4 `unlock` flash-accounting flow (`take`/`settle`) and the external venue
   interface, atomically.
7. **Measure** — realized profit is the hook's quote-balance delta after the
   cycle; base neutrality is enforced within `baseDustToleranceBps`. If the
   realized result is not positive, nothing is paid. If it exceeds
   `maxLossGuardQuote` in the negative, an automatic loss guard pauses the
   whole system.
8. **Payout** — realized profit is split trader / IL fund / LPs (see the
   table above), escrowed in the `PayoutLedger`, and LP shares are streamed
   into the pools via v4 `donate`, flowing pro-rata to in-range liquidity.

### The economics, end to end

```
     trader swap ──► pool price diverges from every other venue
                          │
                          ▼ (same transaction)
              RebateHook.afterSwap ── backrun cycle ──► realized profit
                          │
        ┌─────────────────┼──────────────────────────┐
        ▼                 ▼                          ▼
  trader rebate      IL fund carve-out          LP side
  (40% buy / 10%     (ilBps of LP side,         35% paired pool 1
   sell, paid to     default disabled)          35% paired pool 2
   the trader via                              15% protocol pool 1
   PayoutLedger)                               15% protocol pool 2
```

Searcher-triggered captures replace the trader share with the searcher
commission; conditional-order fills credit the placer as the rebate recipient.

## Architecture

| Contract | Path | Role |
|---|---|---|
| `RebateHook` | `src/hook/RebateHook.sol` | The v4 hook: auto-pairing, the afterSwap capture loop, dynamic fees, keeper entry points, working-capital management |
| `PoolRegistry` | `src/registry/PoolRegistry.sol` | Single source of truth: approved pairs, paired pools, external venues, protocol pools, per-pair parameters, pause switches |
| `RouteChecker` | `src/libraries/RouteChecker.sol` | Bounded route enumeration, closed-form cycle estimation, size capping, price normalization |
| `SwapExecutor` | `src/libraries/SwapExecutor.sol` | Protected atomic cycle execution over v4 take/settle legs and external venues |
| `PayoutLedger` | `src/rewards/PayoutLedger.sol` | Realized-profit escrow: trader credits, per-pool LP accruals, claims, releases |
| `ILFund` | `src/rewards/ILFund.sol` | Impermanent-loss compensation program funded by the `ilBps` carve-out; liquidity × time weighting, exactly solvent |
| `SwapRouter` | `src/periphery/SwapRouter.sol` | Minimal router: exact-in swaps and add/remove liquidity against the v4 manager |
| `OrderBook` | `src/periphery/OrderBook.sol` | Escrowed conditional (limit/stop) orders with permissionless fills and filler bounties |
| `SearcherRouter` | `src/periphery/SearcherRouter.sol` | Batched permissionless capture submissions (≤ 8 pairs) paying the searcher commission |
| `BatchAuctionPool` | `src/periphery/BatchAuctionPool.sol` | Experimental uniform-price batch settlement venue (dual-mode `IExternalVenue`) |
| `ExternalAMMPool` | `src/periphery/ExternalAMMPool.sol` | Generic constant-product external venue with a v3-style lens, for integration demos and tests |
| `Create2Factory` | `src/periphery/Create2Factory.sol` | Deterministic deployments — used to mine the hook address to its required permission bits |
| `WrappedNative` | `src/tokens/WrappedNative.sol` | WETH9-style native-token wrapper fixture |
| `TestToken` | `src/tokens/TestToken.sol` | ERC-20 fixture for testnet demos (not for production) |
| `IExternalVenue` | `src/interfaces/IExternalVenue.sol` | The integration surface any external venue must implement |

### Hook address requirements

v4 encodes hook permissions in the address itself. `RebateHook` requires
`AFTER_INITIALIZE` (1<<12), `BEFORE_SWAP` (1<<7) and `AFTER_SWAP` (1<<6), so
the deployed address must satisfy `address & 0x3FFF == 0x10C0`. The deploy
script mines a CREATE2 salt (via `Create2Factory`) until the predicted address
carries exactly that mask.

## Repository Layout

```
.
├── src/
│   ├── hook/            # RebateHook — the v4 hook
│   ├── registry/        # PoolRegistry — approved pairs, pools, venues, params
│   ├── libraries/       # RouteChecker, SwapExecutor
│   ├── rewards/         # PayoutLedger, ILFund
│   ├── periphery/       # SwapRouter, OrderBook, SearcherRouter,
│   │                    # BatchAuctionPool, ExternalAMMPool, Create2Factory
│   ├── interfaces/      # IExternalVenue
│   └── tokens/          # WrappedNative, TestToken (fixtures)
├── test/                # 8 suites, 63 tests (see Testing)
├── script/              # 5-step deploy + demo flow (see Deployment)
├── deployments/         # locally generated address book (gitignored)
├── .github/workflows/   # CI: fmt --check, build --sizes, test -vvv
├── foundry.toml         # Cancun, solc 0.8.26, via_ir, optimizer 10000
├── remappings.txt
├── .gitmodules          # v4-core, v4-periphery, openzeppelin, forge-std
├── foundry.lock         # pinned dependency revisions
└── .env.example         # RPC + deployer placeholders (never real secrets)
```

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
  (`forge`, `cast`)
- Git (submodules required)
- Any Cancun-compatible EVM chain if you plan to deploy (transient storage is
  required)

### Install, build, test

```bash
git clone <your-fork-url> roobak-contracts
cd roobak-contracts
git submodule update --init --recursive   # v4-core, v4-periphery, OZ, forge-std

forge build        # via_ir build (PoolManager size requirement)
forge test         # 63 tests across 8 suites
```

The default profile compiles with `via_ir = true` (required to fit v4's
`PoolManager`); the `test` profile disables it for faster iteration, and the
`ci` profile raises fuzz runs to 500.

## Testing

```
$ forge test
Ran 8 test suites: 63 tests passed, 0 failed, 0 skipped
```

| Suite | Tests | Covers |
|---|---|---|
| `RebateHook.t.sol` | 18 | Address bits, auto-pairing, buy/sell splits (incl. four-way LP split), no-divergence skip, single-capture-per-swap, dynamic-fee base/surge, IL carve-out, router slippage, loss-guard pause |
| `PoolRegistry.t.sol` | 10 | Pair lifecycle, parameter validation and hard caps, auto-pairing rules, venue registration, pause switches |
| `PayoutLedger.t.sol` | 8 | Escrow accounting, claims, releases, solvency invariant |
| `RouteChecker.t.sol` | 7 | Price normalization, closed-form estimation, size caps, best-cycle selection |
| `OrderBook.t.sol` | 6 | Order placement, crossing, fills, bounties, placer rebates |
| `ILFund.t.sol` | 5 | Funding, accrual weighting, claims, solvency |
| `BatchAuctionPool.t.sol` | 5 | Uniform-price settlement, dual-mode venue interface |
| `SearcherRouter.t.sol` | 4 | Batch submission, commission accounting, bounds |

Economic-parity suites assert that the trader/LP/protocol splits match the
configured bps exactly, and that every payout path (rebates, bounties,
searcher commissions, IL funding) draws from the same realized-profit pot
without creating or destroying value.

CI (`.github/workflows/test.yml`) runs `forge fmt --check`,
`forge build --sizes` and `forge test -vvv` on every push and pull request.

## Deployment

The system targets any Cancun-compatible EVM chain. Configure your endpoint
and deployer, then run the five scripts in order — each one records its
addresses to `deployments/deployment.json` (gitignored; the registry is never
committed):

```bash
cp .env.example .env       # fill in RPC_URL + DEPLOYER_PRIVATE_KEY
source .env

# 0) v4 infrastructure: PoolManager, StateView, WrappedNative, demo tokens
forge script script/DeployInfrastructure.s.sol \
  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow

# 1) protocol system: registry → factory → ledger → ILFund →
#    CREATE2-mined RebateHook (mask 0x10C0) → wiring → router →
#    order book → searcher router → batch auction pool
forge script script/DeploySystem.s.sol \
  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow

# 2) demo pair: register pair, initialize the two hook pools (auto-pairing),
#    seed liquidity, register an external venue, fund working capital
forge script script/SetupDemoPair.s.sol \
  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow

# 3) end-to-end demo trade: divergence → same-tx capture → LP distribution
#    → trader rebate claim
forge script script/DemoTrade.s.sol \
  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow

# 4) V2 feature showcase: conditional orders, searcher network, IL fund
forge script script/DemoV2.s.sol \
  --rpc-url $RPC_URL --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow
```

`DemoTrade` and `DemoV2` are executable documentation: they assert the
expected splits on-chain and revert if the economics do not hold.

## Configuration

All economic parameters live in `PoolRegistry.PairParams` and are set per
pair by the owner. Defaults, applied at `registerPair`:

| Parameter | Default | Meaning |
|---|---|---|
| `traderShareBuyBps` | `4000` | Trader share of realized profit on BUY (base received) |
| `traderShareSellBps` | `1000` | Trader share on SELL (base sold) |
| `searcherBps` | `1000` | Searcher commission for keeper-triggered captures |
| `ilBps` | `0` | LP-side carve-out into the IL fund (disabled by default) |
| `lpPool1Bps` / `lpPool2Bps` | `3500` / `3500` | LP share to the paired pools |
| `lpProtocol1Bps` / `lpProtocol2Bps` | `1500` / `1500` | LP share to the protocol pools |
| `baseFee` / `surgeFee` / `surgeThreshold` | `3000` / `10000` / `1e21` | Dynamic-fee schedule for pools created with the dynamic-fee flag |
| `minProfitQuote` | `1e14` | Minimum realized profit (quote units) worth paying out |
| `maxTradeSizeQuote` | `1e22` | Absolute per-cycle size cap |
| `maxSizeBpsOfLiquidity` | `25` | Cycle size ≤ 0.25% of the thinner venue's quote-liquidity |
| `baseDustToleranceBps` | `10` | Allowed base-balance drift per cycle |
| `maxLossGuardQuote` | `1e18` | Realized loss that trips the automatic pause |
| `maxRouteChecks` | `8` | Venue combinations examined per capture |
| `maxCyclesPerSwap` | `2` | Executed cycles per capture |

Enforced hard caps (revert on violation): `maxRouteChecks ≤ 16`,
`maxCyclesPerSwap ≤ 4`, LP split bps must sum to exactly `10_000`,
`baseDustToleranceBps ≤ 1000`, `surgeFee ≥ baseFee`, at most 4 external
venues per pair. If protocol pools are not configured, their 15%/15% shares
fold back into the paired pools.

## Security Model

**Bounds on everything the hook may do**

- Only registry-approved pools, venues and routes are ever touched.
- Bounded path enumeration (`maxRouteChecks ≤ 8` default, 16 hard) and
  bounded executions (`maxCyclesPerSwap ≤ 2` default, 4 hard).
- Cycle size is capped by absolute amount, by venue liquidity, and by the
  working capital the hook actually holds; withdrawals cannot break the
  configured floor.

**Payout integrity**

- Payouts come only from **realized positive profit** measured after
  execution — never from estimates.
- Filler bounties, searcher commissions and IL funding are all carved out of
  the same realized split; the ledger never owes more than it captured
  (`credits + claims + releases ≤ captured`, per token).
- ILFund solvency invariant: `funded − paid − owed ≥ 0`, per token.

**Fail-safe behavior**

- A failing capture is revert-isolated — the trader's swap always lands.
- Skip reasons are emitted as `CaptureSkipped` codes: `1` system paused,
  `2` pair paused, `3` unregistered pair, `4` pools incomplete,
  `5` low estimate, `6` no profit, `7` execution failed.
- Circuit breakers: global system pause, per-pair capture pause,
  distribution pause, and an automatic loss-guard pause callable by the hook
  itself. Swaps are never blocked — only captures stop.
- Transient-storage reentrancy guard; the hook never acts as its own price
  trigger, and its capture legs are exempt from surge fees.

## Disclaimer

This is a **testnet reference implementation, unaudited**. It is provided
as-is for research and experimentation. Review the security model above,
the threat surface of the external-venue interface, the honest scope of the
IL fund and the experimental status of the batch auction before any
mainnet use. No warranty, express or implied.

## License

[MIT](./LICENSE) © Roobak Contributors
