# RateSpace

One ETH balance is the exit and entry liquidity for every staked-ETH token — on 1inch Aqua, priced at the live rate, running on 1inch's official router.

Built for ETHGlobal Tokyo 2026, 1inch "Build an Aqua App" track.

## The problem

- A pegged pool fixes its price when it is created. Staked-ETH tokens (wstETH, rETH, weETH) grow in value every day, so a frozen peg goes stale and arbitrageurs take the difference from the maker.
- Each staked-ETH pair needs its own pool with its own ETH. A maker who wants to serve three tokens has to split its ETH three ways.
- Exiting through the issuer's own withdrawal queue is not instant.

## What we built

- **MovingPegSwap** (SwapVM opcode `0x59`). 1inch's PeggedSwap curve, with two changes: the anchors are fixed once, in ETH value, and each token's rate is read live on every trade. A guard band around the reference rate stops trading if the rate moves too far. The order bytes never change when the rate moves.
- **Rate providers** for wstETH, rETH and weETH. One small contract per token that reads the token's own on-chain rate (`stEthPerToken()`, `getExchangeRate()`, `getRate()`). No oracle, no push.
- **MovingPegExtruction**. The same per-trade math, packaged as a target for the `Extruction` opcode of 1inch's official `AquaSwapVMRouter` v1.0.2. So the official router can serve our prices without a custom router.
- **Shared backing**. One maker wallet on Aqua backs many markets at once (one WETH balance, three staked-ETH orders).
- **The app** (`apps/web`). Three screens: the shared-backing view, a swap screen, and a rate screen that steps a demo rate and shows the quote follow it with the same order.

## How it differs from aqua0

- aqua0's `ForexCurve` adds a new SwapVM opcode that prices FX pairs from a Chainlink-style `latestRoundData()` feed, which an oracle has to push. A new opcode means a router built to include it.
- RateSpace reads each token's own on-chain exchange rate (nothing to push, nothing to go stale) and runs on 1inch's official `AquaSwapVMRouter` through its existing `Extruction` opcode. We also have our own router (`RateSpaceAquaRouter`) with the same math as a native opcode.

## Proofs

Local rows re-run from this commit with no network. Paths are under `packages/contracts/`.

| Claim | Where | Number |
|---|---|---|
| The Python model and the Solidity return the same integers | `test/ModelParity.t.sol`; `python3 analysis/gen_parity.py --check` | 109 + 18 + 16 cases equal to the wei; `--check` prints `True` |
| After a rate step 1.20 → 1.25 (width A = 50), the pool is barely off the new price; a frozen peg is far off | `python3 analysis/s3a_arb_step.py` | ours 0.010206 bps, frozen PeggedSwap 157.015569 bps (best arbitrage, bps of pool value) |
| The 0.05% fee blocks trading around a rate report while one report moves the rate less than the break-even step | `python3 analysis/s3e_fee_roundtrip.py` (Part 3) | break-even 10.0509 bps |
| Real Lido reports are much smaller than that | `python3 analysis/s5_lido_reports.py --offline` (data in `analysis/data/lido_reports.csv`) | 1228 reports since Lido V2, largest move 3.223442 bps, 0 drops |
| The same holds for rETH, cbETH and weETH over the last 365 days | `python3 analysis/s6_lst_rates.py --offline` (data in `analysis/data/lst_rates_*.csv`, 39 on-chain cross-checks) | rETH 363 updates, largest 3.491327 bps; cbETH 364, largest 3.341668; weETH 14863 changes (1598 oracle reports), largest 0.987708; 0 drops; none at or above the 10.0509 bps break-even |
| One 10 WETH wallet backs three markets | `test/SharedLiquidity.t.sol` (`-vv` logs) | 10e18 WETH in the wallet, 10e18 virtual WETH per strategy, 30e18 total; three 1e18 sells paid 3519603734275451780 wei = the wallet's drop exactly |
| MovingPeg pricing runs on 1inch's official `AquaSwapVMRouter` v1.0.2 via `Extruction`, equal to our router | `test/extruction/MovingPegExtructionEquivalence.t.sol` | same order, same 5-swap sequence, all 12 amounts equal to the wei |
| Full local suite | `MAINNET_RPC_URL= forge test` | 78 passed, 0 failed, 12 skipped (the fork tests) |

Mainnet-fork results. These tests are committed but skip without `MAINNET_RPC_URL`, so they cannot be re-run from a plain checkout. The numbers below come from our last fork runs on 2026-09-25 and 2026-09-26. They are not in any committed log file.

| Claim | Where | Number (last fork run) |
|---|---|---|
| A real Lido report (block 26047292 → 26047293) moves our price with the rate, same order hash | `test/fork/MainnetFork.t.sol` T3 | ours 0.003 bps from the new rate, frozen PeggedSwap 0.617 bps |
| Gas on the live Aqua | `test/fork/MainnetFork.t.sol` T5 | ours (fee + MovingPegSwap) 155076, upstream fee + PeggedSwap 117248 |
| Pricing on 1inch's live router at `0x111111338c5091e8440b67b168bae16a668ac0de` | prototype run on 2026-09-26, now `test/fork/LiveRouterExtruction.t.sol` | 12 swap amounts equal our router to the wei; gas 169788 (171544 with fee) |

The committed `LiveRouterExtruction.t.sol` has not been run on a fork yet. The live-router numbers come from the prototype it was built from.

## Run it locally

Needs Foundry (`anvil`, `forge`, `cast`) and bun. No mainnet RPC.

```bash
git submodule update --init
(cd packages/contracts/lib/swap-vm && bun install --ignore-scripts)
(cd packages/contracts/lib/swap-vm-v1 && bun install --ignore-scripts)
bun install --ignore-scripts

cd packages/contracts
script/demo.sh                   # anvil on :8545 (chain 31337), deploys + seeds, writes deployments/31337.json
script/rate-step.sh wstETH 1     # optional: step a demo rate by +1 bps (also rETH | weETH)
script/demo-stop.sh              # when done

cd ../.. && bun run dev:web      # the app; RPC defaults to http://127.0.0.1:8545
```

`demo.sh` deploys 1inch Aqua 0.1.0 and `AquaSwapVMRouter` v1.0.2 from source, `MovingPegExtruction`, an on-chain order builder, demo WETH, demo wstETH / rETH / weETH, and one settable demo rate feed per token.

Accounts (anvil's public test keys; `DEMO_MAKER_PK` / `DEMO_TAKER_PK` override):
- Maker = anvil #0 `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`. 10 WETH backing three no-fee orders (one per token) plus one wstETH order with the 0.05% fee.
- Taker = anvil #1 `0x70997970C51812dc3A010C7d01b50e0d17dc79C8`. 5 WETH and 2 of each demo token, router approved.

Import the keys into a browser wallet on chain 31337, then:
- `/`: one maker wallet, its WETH balance, and the virtual WETH each of the three markets quotes against.
- `/trade` (taker): pick wstETH, rETH or weETH, pick Exit (token → WETH) or Enter (WETH → token), type an amount, press Swap.
- `/rate` (maker): press "Simulate report +1 bp" on a card. The rate and the quote move; the order hash stays the same.

## Repo map

```
packages/contracts/
  src/instructions/MovingPegSwap.sol     the opcode (0x59)
  src/extruction/                        MovingPegExtruction for the official v1.0.2 router
  src/rate-providers/                    wstETH, rETH, weETH providers
  src/opcodes/, src/routers/             RateSpaceAquaRouter (our router)
  src/demo/, script/                     demo mocks, order builder, deploy script, demo.sh
  test/                                  unit, parity, invariant, shared-liquidity, extruction, fork
  analysis/                              exact-integer Python model; every number in MATH.md
  MATH.md                                the maths, with reproducible numbers
  lib/swap-vm, lib/swap-vm-v1            1inch swap-vm @ 3b3da7d and @ v1.0.2 (read-only)
apps/web/                                the app (TanStack Start, viem)
```

## Honest limits

- Not audited.
- The demo runs on a local anvil chain with mock tokens and settable mock rate feeds. Nothing is deployed on a public chain.
- The fork proofs need a mainnet RPC to re-run.
- Anchors must be value-balanced (equal ETH value on both sides at ship time). Unbalanced anchors put the centre price off the rate by design (`MATH.md` §2, Claim 3).
- The guard band is capped at 10% (1000 bps); the demo orders use 5%.
- Without a fee, a trader who knows a rate report is coming can buy before it and sell after it, taking the report's gain on the pool's staked-ETH side (`MATH.md` §3d). The 0.05% fee blocks this only while one report moves the rate less than 10.0509 bps.
- The codebase was started before the event. The git history starts on 2026-09-26. <!-- TODO-OWNER: confirm whether to write "history re-initialised at the start of the hackathon with the organiser's approval" -->

## Team and links

- Team: TODO-OWNER
- Demo video: TODO-OWNER
- ETHGlobal showcase page: TODO-OWNER
