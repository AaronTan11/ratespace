# RateSpace contracts

Moving-peg swap instruction and routers built on top of the 1inch `swap-vm` VM.

## Layout

```
src/instructions/MovingPegSwap.sol        MovingPegSwap instruction (PeggedSwap with live rate providers)
src/rate-providers/                       IRateProvider, WstETH/RETH/WeETH rate providers
src/opcodes/                              RateSpaceAquaOpcodes / RateSpaceOpcodes (opcode dispatch)
src/routers/                              RateSpaceAquaRouter / RateSpaceRouter
test/                                     Foundry tests and mocks (including MockRateProvider, MockWstETH, MockRETH, MockWeETH)
lib/swap-vm/                              upstream 1inch swap-vm @ 3b3da7d (READ-ONLY submodule)
src/extruction/                           MovingPegExtruction (Extruction target) + MovingPegExtructionArgs (builder)
lib/swap-vm-v1/                           upstream 1inch swap-vm @ v1.0.2 = 32c687c (READ-ONLY submodule)
```

`lib/swap-vm` and `lib/swap-vm-v1` are vendored upstream and must never be edited, added to, or deleted from.
All imports from them are resolved through `remappings.txt`.

## Two swap-vm pins

- `lib/swap-vm` (main @ `3b3da7d`) is what our own `RateSpaceAquaRouter` (opcode `0x59`) is built from.
- `lib/swap-vm-v1` (tag `v1.0.2` @ `32c687c`) is the version of 1inch's live `AquaSwapVMRouter`
  (`0x111111338c5091e8440b67b168bae16a668ac0de`, eip712Domain `"1inch SwapVM v1.0"` / `"1.0.2"`).
  Its swap/quote ABI and program encoding differ from `3b3da7d`. `MovingPegExtruction` runs MovingPegSwap's
  per-trade math behind that router's `Extruction` opcode (`0x20` in the v1.0.2 AquaOpcodes table), so the
  official router can serve the same prices.

Imports: `@swap-vm/` resolves to `lib/swap-vm/contracts/`, `@swap-vm-v1/` to `lib/swap-vm-v1/src/`,
and `@aqua-v1/` to the Aqua 0.1.0 package in `lib/swap-vm-v1/node_modules`. Files under `lib/swap-vm-v1/`
resolve `@1inch/aqua` and `@1inch/solidity-utils` to their own `node_modules` (aqua 0.1.0, solidity-utils 6.9.7).
OpenZeppelin (5.4.0) and forge-std (1.11.0) are byte-identical in both trees and shared.
`MovingPegExtruction` imports `PeggedSwapMath` and `InstructionArgs` from `lib/swap-vm` (3b3da7d), the
same files MovingPegSwap uses.

`lib/swap-vm-v1/node_modules` is untracked. Populate it with `bun install --ignore-scripts` inside
`lib/swap-vm-v1`.

## Demo pair

The demo order is the WETH/wstETH pair. The WETH side uses a static rate of `1e18`; the wstETH
side takes its live rate from `WstETHRateProvider` (`stEthPerToken`).

Assumption: **1 stETH is treated as 1 ETH; this is an assumption, not an oracle.**

## Rate providers

- `WstETHRateProvider` (Lido wstETH): reads `stEthPerToken()`.
- `RETHRateProvider` (Rocket Pool rETH): reads `getExchangeRate()`.
- `WeETHRateProvider` (ether.fi weETH): reads `getRate()`.
- Each returns the token's rate 1e18-scaled and holds the token address as an immutable set in the constructor.
- Anyone can add a provider by implementing `IRateProvider` (`rate() returns (uint256)`, 1e18-scaled, non-zero).

## Build / test

```
forge build
forge test
```

Foundry uses the same compiler settings as upstream (solc 0.8.30, optimizer on, 700 runs,
`via_ir = true`). After a fresh checkout, run `bun install --ignore-scripts` once inside each of `lib/swap-vm` and
`lib/swap-vm-v1` to populate their untracked `node_modules` (bun only; no npm/yarn/pnpm).
`via_ir = true`). No package manager is required for `lib/swap-vm`: its `node_modules` is already
populated. `lib/swap-vm-v1` needs the one `bun install --ignore-scripts` described above.

## Local demo

Runs on a plain local anvil (chain 31337); no mainnet RPC needed. From `packages/contracts`:

```
script/demo.sh              # start anvil :8545, deploy + seed, write deployments/31337.json and 31337.abi.json
script/rate-step.sh wstETH 1   # bump a demo rate feed by +1 bps (simulates an oracle report); also rETH | weETH
script/demo-stop.sh         # stop anvil
```

Deployed (`script/DeployDemo.s.sol`): 1inch Aqua 0.1.0 and AquaSwapVMRouter v1.0.2 built from `lib/swap-vm-v1`, `MovingPegExtruction`, `RateSpaceOrderBuilder` (the app eth_calls it for all order/taker bytes), `DemoWETH`, Demo wstETH / rETH / weETH and one settable `DemoRateFeed` each. Maker = anvil account #0: 10 WETH shared as backing by three no-fee orders (one per yield token) plus one wstETH order with the 0.05% fee. Taker = anvil account #1: 5 WETH + 2 of each yield token, router approved. Keys default to anvil's public test keys (`DEMO_MAKER_PK` / `DEMO_TAKER_PK` override).

The same `MovingPegExtruction` + order encoding was proven equal to the wei against 1inch's LIVE AquaSwapVMRouter and Aqua on a mainnet fork (`test/fork/LiveRouterExtruction.t.sol`).
