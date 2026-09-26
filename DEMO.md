# RateSpace demo: video script (2–3 minutes, local anvil)

Every number below was observed by the Playwright suite (`cd apps/web && bun run test:e2e`) on a fresh
deploy of `script/DeployDemo.s.sol`. The deploy is deterministic, so a fresh `script/demo.sh` gives the same
addresses, rates and quotes, **as long as you follow the scenes in this order** (any extra swap or rate
step changes the later numbers). The app shows 6 decimals; hover a number for the full value in wei.

## Setup (before recording)

1. Terminal 1: `cd packages/contracts && script/demo.sh` (anvil on http://127.0.0.1:8545, chain 31337,
   deploys 1inch Aqua + 1inch `AquaSwapVMRouter` v1.0.2 + RateSpace contracts and demo tokens).
2. Terminal 2, repo root: `bun run dev:web` (app on http://localhost:3001).
3. MetaMask: add network **Anvil**: RPC `http://127.0.0.1:8545`, chain id `31337`, currency symbol `ETH`.
4. MetaMask: import two anvil accounts. The keys are anvil's public test keys: see the `anvil` output
   (the "Private Keys" list it prints at startup; `script/demo.sh` prints the anvil log path).
   - Account 0 = **maker** `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
   - Account 1 = **taker** `0x70997970C51812dc3A010C7d01b50e0d17dc79C8`
5. Start with the **taker** selected in MetaMask. Open http://localhost:3001 and click **Connect wallet**.
   If MetaMask was used against an earlier anvil, reset both accounts' activity/nonce data (MetaMask's
   "clear activity" option under Settings → Advanced; the wording varies by version) or the first
   transaction can fail on a stale nonce.
6. The small "TanStack Router" badge at the bottom left is the dev-mode router devtools; crop it or ignore it.

## Scene 1: Markets (about 30 s), page `/`

- Say: "One maker wallet. Three staked-ETH markets. One balance backs all of them."
- On screen (observed): **"10.000000 WETH in the wallet backs 30.000000 WETH of quotes"**.
  Three rows: wstETH / WETH, rETH / WETH, weETH / WETH, each with 10.000000 virtual WETH backing on Aqua,
  each on router `AquaSwapVMRouter`.
- Live rates shown: wstETH 1.244787, rETH 1.172468, weETH 1.104406.
- Say: "This is 1inch Aqua shared liquidity: the WETH stays in the maker's wallet, promised to three
  strategies at once. The wallet is the limit at fill time."

## Scene 2: Trade, quote (about 20 s), page `/trade`, taker connected

- wstETH tab, **Exit: wstETH → WETH**, amount **0.1**.
- On screen (observed): **You receive 0.124471 WETH** (0.124471102205239420, i.e. 124471102205239420 wei),
  implied WETH per wstETH 1.244711, feed rate() 1.244787, **Quote vs feed −0.6162 bps**.
- Order hash `0xe4fd74a1…07ff9419` = strategy hash (Market panel on the right).
- Say: "The price follows the live wstETH rate. The quote is within a fraction of a basis point of the feed."
- Do not swap yet.

## Scene 3: Rate +1 bp (about 40 s), page `/rate`, switch MetaMask to the **maker**

- Switch MetaMask to account 0 (maker) and reload `/rate`. The wstETH row shows feed rate() 1.244787 and
  the green **matches** badge.
- Click **Simulate report +1 bp** on the wstETH row and confirm in MetaMask.
- On screen (observed):
  - toast "wstETH feed stepped +0.9999 bps" (the display truncates; the exact step is rate × 10001 / 10000,
    rounded down)
  - Rate 1.244787 → 1.244912 (1244787728742679575 → 1244912207515553842 wei)
  - Quote (1 wstETH → WETH) 1.244017 → 1.244141, +0.9948 bps
  - Hash `0xe4fd…9419` → `0xe4fd…9419`, **unchanged**; badge still **matches**
- Say: "An oracle report moved the rate. Same order, same hash, no re-ship, no cancel-and-replace. The
  quote moved by itself."

## Scene 4: Trade after the step (about 30 s), page `/trade`, switch back to the **taker**

- Switch MetaMask to account 1 (taker), reload `/trade`, wstETH, Exit, 0.1.
- On screen (observed): **You receive 0.124483 WETH** (124483487496839615 wei; it was 124471102205239420
  before the step), feed rate() 1.244912, Quote vs feed −0.6211 bps, order hash still `0xe4fd74a1…07ff9419`.
- Click **Swap**, confirm in MetaMask (one transaction: the demo already approved the router).
- On screen (observed): toast "Swapped 0.1 wstETH → 0.124483487496839615 WETH … amounts from Swapped event".
  Taker wstETH balance 2.000000 → 1.900000; WETH 5.000000 → 5.124483.
- Say: "What you are quoted is what you get, to the wei."

## Closing line (about 10 s)

"RateSpace: one wallet backs every staked-ETH market, and the price follows the live rate on 1inch's own
router, with no re-shipping."

Router note, if asked: the anvil demo ships every order to 1inch's official `AquaSwapVMRouter` v1.0.2 (the
MovingPeg maths is an `Extruction` target, so no custom router is needed). Our own router,
`RateSpaceAquaRouter` (opcode `0x59`), is in `packages/contracts/src/routers/`; it is not deployed by the
anvil demo, and the app has no router picker (each market's order carries its router).

## If Sepolia is ready (20-second add-on)

Follow `packages/contracts/script/SEPOLIA.md` (deploy + ship with your own wallet, then restart the app
with `VITE_CHAIN_ID=11155111`). Show `/` and `/rate` on Sepolia: the wstETH rate there is read from Lido's
real Sepolia wstETH, read only (no +1 bp button; the rate moves when Lido reports). Say: "Same contracts,
live Lido rate, on a public testnet."

## Reset between takes

```bash
cd packages/contracts && script/demo-stop.sh && script/demo.sh
```

Then reload the app. In MetaMask, reset both accounts' activity/nonce data again (Settings → Advanced),
because the fresh anvil starts again at nonce 0. The `bun run dev:web` server
can keep running: the fresh deploy has the same addresses.

## Checked by the E2E suite

`cd apps/web && bun run test:e2e` runs all of the above against its own anvil on port 8547 and its own
dev server on 3002 (it never touches 8545 or 3001), with a stand-in EIP-1193 wallet that forwards to
anvil. It asserts quote == received to the wei for Exit and Enter (and for the 0.05% fee order, checked
with viem because the UI lists only the no-fee order), the +1 bp step (unchanged hash, new quote), and zero
console errors. The suite runs the scenes in the order above, then its extra swaps.
