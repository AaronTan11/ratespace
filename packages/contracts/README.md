# RateSpace contracts

Moving-peg swap instruction and routers built on top of the 1inch `swap-vm` VM.

## Layout

```
src/instructions/MovingPegSwap.sol        MovingPegSwap instruction (PeggedSwap with live rate providers)
src/rate-providers/                       IRateProvider, WstETH/RETH/WeETH rate providers
src/opcodes/                              RateSpaceAquaOpcodes / RateSpaceOpcodes (opcode dispatch)
src/routers/                              RateSpaceAquaRouter / RateSpaceRouter
test/                                     Foundry tests and mocks (including MockRateProvider, MockWstETH, MockRETH, MockWeETH)
lib/swap-vm/                              upstream 1inch swap-vm (READ-ONLY submodule)
```

`lib/swap-vm` is vendored upstream and must never be edited, added to, or deleted from.
All imports from it are resolved through `remappings.txt`.

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
`via_ir = true`). No package manager is required: the submodule's `node_modules` is already
populated.
