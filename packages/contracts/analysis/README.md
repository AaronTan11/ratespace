# analysis/ — exact-integer model of MovingPegSwap and PeggedSwap

Python 3, standard library only (`fractions`, `decimal`, `math`). No packages to install, no
network. Every number in `../MATH.md` is printed by one of these scripts.

Run from this directory (`packages/contracts/analysis`):

```
python3 s1_upstream_curve.py      # MATH.md §1  upstream curve, finite reserves, rates cancel   (<1 s)
python3 s2_moving_centre.py       # MATH.md §2  centre follows r(t); rescaled anchors freeze it (<1 s)
python3 s3a_arb_step.py           # MATH.md §3a arbitrage after one rate step, ours vs frozen    (<1 s)
python3 s3b_path.py               # MATH.md §3b many small steps vs one jump                     (~3 s)
python3 s3c_rate_drop.py          # MATH.md §3c rate goes down; band floor                       (<1 s)
python3 s3d_sandwich.py           # MATH.md §3d trading around a rate report                     (~1 min)
python3 s3e_fee_roundtrip.py      # MATH.md §3e 0.05% fee vs a +/-1bp, +/-3bp step; reproduces
                                  #             test_M_Fee_RateStepRoundTrip bit-exactly         (<1 s)
python3 s4_safety.py              # MATH.md §4  guards, rounding, drain, dust, overflow, large anchors (~1 s)
python3 gen_parity.py --check     # the parity table in ../test/ModelParity.t.sol equals the model
python3 gen_parity.py             # print the parity tables (to regenerate the test)
python3 gen_parity.py --gates     # also print the gate rows: amountIn with the current gate vs the legacy gate
```

Then, from `packages/contracts`:

```
forge test --match-path test/ModelParity.t.sol     # the Solidity returns exactly the model's values
```

## Files

| file | what it is |
|---|---|
| `swapvm_math.py` | Solidity 0.8 checked arithmetic (overflow/underflow/div-by-zero raise `Revert`), OpenZeppelin `Math.sqrt` (floor) and `Math.ceilDiv`, and a line-by-line port of `lib/swap-vm/contracts/libs/PeggedSwapMath.sol` (swap-vm 3b3da7d). |
| `pegged_model.py` | line-by-line port of upstream `PeggedSwap.exec` (`lib/swap-vm/contracts/instructions/PeggedSwap.sol`), drain branch included. |
| `moving_peg_model.py` | line-by-line port of `src/instructions/MovingPegSwap.sol` (build-time requires, the exec-time band-cap re-check, `_resolveRate` guards, value-unit normalization, drain branch, dust value floors), upstream `FeeFlatIn`, and a minimal Aqua balance book (`Order`). Each line carries the Solidity line number it mirrors. |
| `arb.py` | arbitrage search: exact integer search over trade sizes on the model, plus an independent real-number (Decimal) optimum of the same curve as a cross-check. |
| `common.py` | the demo order used by the economics scripts (6e18 ETH-side + 5e18 wstETH-side at 1.2e18, anchors 6e18 each) and the frozen-peg baseline (upstream PeggedSwap on the same deposit). |
| `s*.py` | one script per MATH.md section. |
| `gen_parity.py` | generates / checks the expected-value tables of `test/ModelParity.t.sol`. |

## Relation to the earlier probe port (scratchpad `mathprobe/`)

That port was not reused as-is. Differences found and fixed here:

1. Its `solve(u, a, invariantC)` does not match the pinned PeggedSwapMath: it computes `rightSide` inside
   `solve`, rounds the discriminant root UP (`sqrt_ceil`) and has an extra `sqrtD < ONE`
   require. The pinned upstream (`PeggedSwapMath.sol:72-112`, swap-vm 3b3da7d) takes
   `rightSide` from the caller and rounds the root DOWN (`Math.sqrt`). This port follows the
   pinned code.
2. It had no drain branch (`PeggedSwap.sol:151-158`): an exactIn past capacity raised a revert in
   the model, while the real code pays out the whole balance.
3. It modelled "our design" as upstream PeggedSwap with rates `1e18 / r` and anchors `S` (no
   `/ RATE_ONE`). Our code divides by `RATE_ONE` when normalizing (`MovingPegSwap.sol:175-176,
   189, 206, 216, 230, 238, 253, 263`), has the band / zero-rate guards, the exactOut saturation
   and the two dust value floors. `moving_peg_model.py` ports all of them.
4. Its oracle-report "sandwich" only counted each leg at the rate live when it executed. That
   leaves out the maker's loss from selling wstETH at the old rate just before a known rise.
   `s3d_sandwich.py` prints both measures.

## s5 — per-report wstETH rate moves from Lido mainnet history (network, read-only)

`s5_lido_reports.py` measures how far `wstETH.stEthPerToken()` moves at each Lido oracle
report, from every stETH `TokenRebased` log (topic0
`0xff08c3ef606d198e316ef5b822193c489965899eb4e3c248cea1a4626c3eda50`, checked against the log
at block 26047293). Per report: `preRate = preTotalEther*1e18 // preTotalShares`,
`postRate = postTotalEther*1e18 // postTotalShares`, `move_bps = (post-pre)/pre*1e4` (exact).
The threshold it compares against is re-derived from `s3e_fee_roundtrip.py` Part 3
(fee 5000, demo order A=50, band 500): `1206113946104793 / 1.2e18 * 1e4` bps. It applies to that
order only.

```
python3 s5_lido_reports.py --offline                  # summary from data/lido_reports.csv, no network
set -a; . ../.env; set +a                              # loads MAINNET_RPC_URL into the environment only
python3 s5_lido_reports.py --fetch                    # re-collect every log from block 0, rewrite the CSV
python3 s5_lido_reports.py --offline --crosscheck     # eth_call stEthPerToken() at block-1 / block
```

`data/lido_reports.csv` columns: `block, tx_hash, report_timestamp, time_elapsed, preRate,
postRate, move_bps` (move_bps rounded to 6 dp; the script recomputes it exactly from the rates).

Scope limits:
- `TokenRebased` exists only from Lido V2 (first log at block 17272708). Reports before that
  (Lido V1, from stETH launch) are **not** covered.
- Drops are checked at each report (post vs pre) and between consecutive reports (next pre vs
  previous post). A move inside a report period that nets to zero would not show.

## s6 — rETH / cbETH / weETH rate-update history (network, read-only)

`s6_lst_rates.py` lists every block in which each token's rate function changed over 365 days
(blocks 23441102..26055515 for rETH, 23441114..26055528 for cbETH and weETH), and compares
the moves with the same s3e Part 3 threshold as s5 (`1206113946104793 / 1.2e18 * 1e4` bps,
demo order A=50, band 500, fee 5000; that order only).

Mechanism per token (each confirmed by eth_call of the rate at block-1 and block):
- **rETH** `getExchangeRate()` on 0xae78…6393. It changes only in blocks with a
  `BalancesUpdated` event from RocketNetworkBalances (the address RocketStorage returns for
  `contract.addressrocketNetworkBalances`: 0x6Cc6…1399, then 0x1D9F…9473 after an upgrade
  between blocks 24474719 and 24481884). 363 changes, 363 events, each event's
  `totalEth*1e18 // rethSupply` equals the post-block rate.
- **cbETH** `exchangeRate()` on 0xBe98…9704. It changes only in blocks with an
  `ExchangeRateUpdated` event on cbETH itself. 364 changes, 364 events, each
  `newExchangeRate` equals the post-block rate.
- **weETH** `getRate()` on 0xCd5f…b7ee (= LiquidityPool `amountForShare(1e18)`). It moves at
  each ether.fi oracle report (`Rebase` event on LiquidityPool 0x3088…F216; 1598 blocks) **and
  also on ordinary transactions** that change pooled ETH or eETH shares, e.g. withdrawal
  claims (`batchClaimWithdraw`) and `redeemWeEth` (13265 changes in blocks with no `Rebase`).
  In one block, 25632424, the rate moved again after the `Rebase` tx (tx index 391): the only
  later tx in that block with eETH share logs is a `redeemWeEth` call (index 432, eETH shares
  burned), so the event rate differs from the post-block rate by 175572725 wei. The summary
  prints both rates and the cross-check confirms the block-1 and block values.

```
python3 s6_lst_rates.py --offline                     # summaries from data/lst_rates_<token>.csv, no network
set -a; . ../.env; set +a                              # loads MAINNET_RPC_URL into the environment only
python3 s6_lst_rates.py --fetch [TOKEN ...]           # resumable re-collection; re-run until COMPLETE
python3 s6_lst_rates.py --offline --crosscheck        # eth_call at block-1 / block for >= 12 changes per token
```

`--fetch` keeps its progress in `$S6_CACHE` (default `<temp dir>/s6_lst_cache`) and writes a
CSV only when a token is complete. `--rewrite` rebuilds the CSVs from a complete cache.

`data/lst_rates_<token>.csv` columns: `block, timestamp, gap_s, preRate, postRate, move_bps,
update_event_tx, event_rate` (`preRate` = rate at block-1, `postRate` = rate at block;
move_bps rounded to 6 dp and recomputed exactly by the script; the event columns are empty
when the block has no update event). The `#` header lines give the scanned range and event
counts.

Scope limits:
- Granularity is one block: several rate-moving txs in one block appear as one change.
- Changes are found by sampling the rate every 256 blocks (rETH, cbETH) or 64 blocks (weETH)
  and bisecting every interval whose endpoints differ, plus a block-1 / block check of every
  update-event block. A rise and an equal fall inside one sampling interval with no update
  event would not show.
- The 365-day window only; older history is not covered.
