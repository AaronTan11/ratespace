# RateSpace

**One ETH balance is the exit and entry liquidity for every staked-ETH token, priced at the live rate, on 1inch Aqua, through 1inch's official router.**

Built at ETHGlobal Tokyo 2026 for the 1inch "Build an Aqua App" track.

## The problem in three lines

- 1inch's PeggedSwap fixes its price when the order is created. wstETH, rETH and weETH gain value every day, so a fixed peg goes stale within hours and arbitrage takes the difference from the maker. 1inch's own docs say PeggedSwap is "not suitable for pairs where the peg ratio drifts over time (e.g. WETH/wstETH)".
- Every staked-ETH pair needs its own pool with its own ETH. A maker who wants to serve three tokens splits its capital three ways.
- Leaving a staking token through the issuer's own queue is not instant.

## What RateSpace does

- **Prices follow the token's own on-chain rate.** No oracle, nothing to push, nothing to go stale. wstETH reports `stEthPerToken()`, rETH `getExchangeRate()`, weETH `getRate()`. One small rate-provider contract per token.
- **One wallet backs many markets.** Aqua's shared-liquidity model lets the same 10 WETH be the backing for wstETH, rETH and weETH markets at once. Tokens leave the wallet only when a trade fills; an over-draw fails safely.
- **Runs on 1inch's official router.** Our pricing is packaged as an `Extruction` target, so the live `AquaSwapVMRouter` v1.0.2 serves it without any custom router. We also ship our own router (`RateSpaceAquaRouter`, opcode `0x59`) with the same maths as a native instruction; both give the same amounts to the wei.
- **The same order keeps trading as the rate moves.** Anchors are fixed once in ETH value; the live rate is read on every trade; a guard band around the reference rate stops trading if the rate moves too far (cap 10%).

## How it differs from other Aqua apps

- **aqua0** prices FX pairs from a Chainlink-style feed that an oracle has to push, with a new opcode on its own router. RateSpace reads each token's own exchange rate and runs on the official router through the existing `Extruction` opcode.
- **RWA Outlets** does instant exits for tokenized real-world assets. RateSpace is built for staked ETH, where the rate is on-chain and moves in small daily steps we have measured.

## What is proven

Everything below was re-run from this repository. Local rows need no network; fork rows need a mainnet RPC.

| Claim | Where | Result |
| --- | --- | --- |
| The Python model and the Solidity return the same integers | `test/ModelParity.t.sol`; `python3 analysis/gen_parity.py --check` | 109 MovingPegSwap + 18 band + 16 PeggedSwap cases equal to the wei; `--check` prints `True` |
| After a 1.20 → 1.25 rate step, a RateSpace pool is barely off the new price; a frozen peg is far off | `python3 analysis/s3a_arb_step.py` | ours 0.010206 bps, frozen PeggedSwap 157.015569 bps (best arbitrage, as bps of pool value, width A = 50) |
| The 0.05% fee blocks trading around a rate report while one report moves the rate by less than the break-even step | `python3 analysis/s3e_fee_roundtrip.py` | break-even 10.0509 bps |
| Real rate updates are far below that | `python3 analysis/s5_lido_reports.py --offline`, `python3 analysis/s6_lst_rates.py --offline` | Lido: 1228 reports since V2, largest 3.223442 bps, 0 drops. Last 365 days: rETH 363 updates, largest 3.491327; cbETH 364, largest 3.341668; weETH 14863 changes, largest 0.987708; 0 drops anywhere; 39 on-chain cross-checks match |
| One 10 WETH wallet backs three markets | `test/SharedLiquidity.t.sol` | 10e18 WETH in the wallet, 10e18 virtual WETH per strategy, 30e18 promised; three 1e18 sells paid 3519603734275451780 wei = the wallet's drop exactly; the next over-draw reverts |
| Our pricing on 1inch's official router equals our own router | `test/extruction/MovingPegExtructionEquivalence.t.sol` | same 5-swap sequence, all 12 amounts equal to the wei, also with a stepped rate and with unbalanced anchors |
| Full local suite | `MAINNET_RPC_URL= forge test` | 86 passed, 0 failed (12 fork tests skip without an RPC) |
| A real Lido report moves our price with the rate, same order hash | `test/fork/MainnetFork.t.sol` (mainnet fork, blocks 26047292 → 26047293) | ours 0.003 bps from the new rate, frozen PeggedSwap 0.617 bps |
| Gas on the live Aqua | `test/fork/MainnetFork.t.sol` | ours (fee + MovingPegSwap) 155076; upstream fee + PeggedSwap 117248 |
| Pricing on 1inch's LIVE router `0x111111338c5091e8440b67b168bae16a668ac0de` via `Extruction` | `test/fork/LiveRouterExtruction.t.sol` (mainnet fork) | 7/7: dispatch through opcode 0x20, 12 amounts equal our router, an arbitrary EOA fills, guards revert; gas 169756 (171512 with the fee) |

Both fork files ran 12/12 on 2026-09-26 against Ethereum mainnet block 26047293.

## Reviews

The contracts went through four rounds of adversarial review by independent reviewers (two per round) plus a hands-on re-run of every finding. Findings were reproduced before being accepted, and each surviving mutation got a pinning test. No value-extracting bug was found in any round; every round-4+ finding was a missing test. The confirming reviews are part of the commit history.

## Run it locally

Needs Foundry (`anvil`, `forge`, `cast`) and bun. No mainnet RPC needed.

```bash
git submodule update --init
(cd packages/contracts/lib/swap-vm && bun install --ignore-scripts)
(cd packages/contracts/lib/swap-vm-v1 && bun install --ignore-scripts)
bun install --ignore-scripts

cd packages/contracts
script/demo.sh                   # anvil on :8545 (chain 31337); deploys 1inch Aqua + router v1.0.2 from source, RateSpace, demo tokens; seeds 4 orders
script/rate-step.sh wstETH 1     # optional: move a demo rate by +1 bp (also rETH | weETH)
script/demo-stop.sh              # when done

cd ../.. && bun run dev:web      # the app on http://localhost:3001 (RPC http://127.0.0.1:8545)
```

Accounts (anvil's public test keys):
- Maker = anvil #0 `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`: 10 WETH backing three no-fee orders (wstETH, rETH, weETH) plus one wstETH order with the 0.05% fee.
- Taker = anvil #1 `0x70997970C51812dc3A010C7d01b50e0d17dc79C8`: 5 WETH and 2 of each demo token, router approved.

Import the keys into a browser wallet on chain 31337, then:
- `/` — one maker wallet, its real WETH balance, and the virtual WETH each of the three markets quotes against.
- `/trade` (taker) — pick a token, Exit (token → WETH) or Enter (WETH → token), type an amount, press Swap. The app never encodes order bytes itself: an on-chain `RateSpaceOrderBuilder` built from 1inch's own libraries produces them.
- `/rate` (maker) — press "Simulate report +1 bp". The rate and the quote move; the order hash stays the same.

Mainnet-fork proofs: put `MAINNET_RPC_URL=<your rpc>` in `packages/contracts/.env` and run `forge test --match-path 'test/fork/*' -vv`.

## Repo map

```
packages/contracts/
  src/instructions/MovingPegSwap.sol     the instruction (opcode 0x59): PeggedSwap with live, guarded rates
  src/extruction/                        MovingPegExtruction: the same maths as an Extruction target for the official router
  src/rate-providers/                    wstETH, rETH, weETH rate providers (IRateProvider)
  src/opcodes/, src/routers/             RateSpaceAquaRouter (our router)
  src/demo/, script/                     on-chain order builder, demo tokens and rate feeds, deploy + seed script, demo.sh
  test/                                  unit, parity, invariant, shared-liquidity, extruction, fork
  analysis/                              exact-integer Python model; every number in MATH.md comes from a script here
  MATH.md                                the maths, with reproducible numbers
  lib/swap-vm, lib/swap-vm-v1            1inch swap-vm @ 3b3da7d and @ v1.0.2 (read-only submodules)
apps/web/                                the app (TanStack Start, viem)
PITCH.md                                 the pitch
```

## Limits

- Not audited.
- The demo runs on a local chain with mock tokens and settable mock rate feeds. Nothing is deployed on a public chain.
- Anchors must be value-balanced at ship time (the deploy script does this); unbalanced anchors move the centre price by design.
- Without a fee, a trader who knows a rate report is coming can buy before and sell after it. The 0.05% fee blocks this while one report moves the rate by less than 10.0509 bps; the largest report we measured across four tokens was 3.49 bps.
- The demo taker data carries no minimum-output threshold; add one before any non-local use.

## Links

- Team: 
- Demo video: 
- ETHGlobal showcase: 
