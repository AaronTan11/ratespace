# MovingPegSwap: the maths, with reproducible numbers

This document describes the current code:
`src/instructions/MovingPegSwap.sol` (ours)
and upstream `lib/swap-vm` pinned at **3b3da7d** (`contracts/instructions/PeggedSwap.sol`,
`contracts/libs/PeggedSwapMath.sol`). Every number below is printed by a script in `analysis/`.
The script name is given next to each table. How to re-run everything is in §6.

Trust chain: `analysis/moving_peg_model.py` and `analysis/pegged_model.py` are exact-integer
ports of the two `exec` functions, line by line, with the same rounding and the same checked
arithmetic. `test/ModelParity.t.sol` runs the real Solidity on 109 MovingPegSwap cases, 18
MovingPegSwap cases with a hand-encoded band, and 16 PeggedSwap cases and asserts the model's
values to the wei (and, for the band cases, the exact revert selector and argument). The model also reproduces the
four committed `test_M_Fee_RateStepRoundTrip` numbers exactly (§3e) and the four committed
`PeggedSwapBaseline` B2 log values (§1), both of which run through the real Aqua router. So the economics in §3 are
produced by a model that computes the same integers as the contract.

Notation. `ONE = 1e27` (PeggedSwapMath scale), `RATE_ONE = 1e18` (our rate scale). "Value units"
means `balance × rate / 1e18`, i.e. ETH-equivalent wei when the ETH side has rate 1e18.
`A` is `linearWidth / 1e27`. The demo order is 6e18 of the ETH side + 5e18 of the wstETH side,
shipped at rate 1.2e18, so both anchors are 6e18 value units (test/MovingPegSwap.t.sol:33-38).

---

## 1. The upstream curve (PeggedSwap)

**In plain English.** PeggedSwap is a curve that trades two tokens near a fixed price. Each
side is measured against its own starting amount (its "anchor"). The curve has a finite end:
one side can only be emptied by paying a lot of the other, and a trade that asks for more
simply takes the whole remaining balance. The rates in the order do NOT set the price. They
cancel out, and the price at rest is always the ratio of the two starting balances. That is why
upstream PeggedSwap cannot follow a rate that drifts: the peg is frozen at ship time.

**The curve.** `PeggedSwapMath.sol:11`: `√u + √v + A(u + v) = C`, where
`u = x·ONE/x0_init`, `v = y·ONE/y0_init` (both rounded down, `PeggedSwapMath.sol:56-57`), and `C`
is recomputed from the current balances on every swap (`PeggedSwap.sol:127`). At rest `u = v = 1`,
so `C = 2 + 2A`.

**What `exec` does with `x0_init`, `y0_init` and the rates** (`PeggedSwap.sol`):

- `:116-117` reads `(x0, y0, linearWidth, rateA, rateB)` from the order and swaps the pairs when
  the input token is the greater address. `x0_init, y0_init` are used only as divisors (`:141`,
  `:179`, and inside `invariantFromReserves`) and multipliers (`:155`, `:165`, `:187`).
- `:123-124` multiplies balances by the rates: `x0 = balanceIn·rateIn`, `y0 = balanceOut·rateOut`.
- exactIn `:137-170`: `x1 = x0 + amountIn·rateIn`; `u1 = x1·ONE/x0_init` (down); capacity check
  `:151`; else `v1 = solve(C − √u1 − A·u1)`, `y1 = ⌈v1·y0_init/ONE⌉`, `amountOut = ⌊(y0 − y1)/rateOut⌋`.
- exactOut `:172-199`: `amountOut` clamped to the balance (`:172`); `v1 = ⌊y1·ONE/y0_init⌋`;
  `u1 = solve(...)`; `x1 = ⌈u1·x0_init/ONE⌉`; `amountIn = ⌈(x1 − x0)/rateIn⌉`, at least 1 wei (`:194`).

**Finite reserves and the hard boundary.** With the other side at `v = 0`, `u` can reach at most
`u*`, the root of `√u* + A·u* = C`. Beyond it there is no curve. PeggedSwap's exactIn checks this
without solving (`:151`) and, past capacity, pays out the whole output balance and charges only
the input needed to reach `u*` (`:154-158`). An exactOut above the balance is clamped (`:172`).

`python3 analysis/s1_upstream_curve.py` (1a, 1b):

| A | C / ONE | u* (real) |
|---|---|---|
| 0 | 2 | 4.0000000000 |
| 20 | 42 | 2.0287823348 |
| 50 | 102 | 2.0116335862 |
| 100 | 202 | 2.0058372416 |
| 300 | 602 | 2.0019503235 |

Demo deposit 6e18 / 5e18, A = 50: exactIn of 10e18 or 1e24 is charged `6069801516926199140` and
pays out `5000000000000000000` (the whole balance). An exactOut of 7e18 is clamped to 5e18 and
costs the same `6069801516926199140`.

**The rates cancel.** The order's own documentation says the anchors are `balance × rate`
(`PeggedSwap.sol:32-33`). Put `x0_init = X·ra`, `y0_init = Y·rb`. Then

- `u = ⌊x·ra·ONE / (X·ra)⌋ = ⌊x·ONE/X⌋` and `v = ⌊y·ONE/Y⌋`: no rate left.
- exactIn: `u1 = ⌊(x + amt)·ra·ONE/(X·ra)⌋ = ⌊(x + amt)·ONE/X⌋`, and
  `amountOut = ⌊(y·rb − ⌈v1·Y·rb/ONE⌉)/rb⌋ = y − ⌈⌈v1·Y·rb/ONE⌉/rb⌉ = y − ⌈v1·Y/ONE⌉`
  (for an integer `n > 0`, `⌈⌈z⌉/n⌉ = ⌈z/n⌉`).
- exactOut and the drain branch reduce the same way: `⌈⌈u1·X·ra/ONE⌉/ra⌉ − x = ⌈u1·X/ONE⌉ − x`.

So every trade is bit-identical to the same order with `rateA = rateB = 1` and anchors `X, Y`.
Script result (1c): **2000 random cases, 2000 bit-identical, 0 mismatches**, over rates
{1, 3, 7919, 1e6, 1e12, 1e18, 1244787728742679575, 1183746519283746519}, A up to 5000, both
directions, exactIn and exactOut, including drains and clamps.

**The peg is the ship-time balance ratio.** At `u = v` the curve's slope is `dv/du = −1`, so in
token units `dx/dy = x0_init/y0_init = X/Y`. Script result (1d): deposit 6e18 / 5e18 with
`rateB` = 1, 1.2e18, 1.25e18 or 1244787728742679575, A = 0 or 50: the price at rest is
`1000000000/833333333 = 1.200000000` every time. Setting `rateB` to 1.25e18 does not move it.

**Router cross-check (1e).** The committed `PeggedSwapBaseline` B2 tests (upstream Aqua router,
world rate 1.25e18) log `104155923072964493`, `5194903841205616`, `6069801516926199140` and
`180198483073800860`; `pegged_model.py` gives the same four values (`EQUAL` ×4).

---

## 2. Our change (MovingPegSwap)

**In plain English.** We keep the same curve, but measure both sides in ETH value instead of
token counts, and read the wstETH rate live on every trade. The anchors are fixed once, at ship
time, in ETH value, equal on both sides. Then the curve's centre (where it trades one-for-one in
value) is always at "1 wstETH = r(t) ETH", for whatever r(t) the rate provider reports now. The
order never changes. The obvious alternative, rescaling the anchors by the live rate too,
cancels the rate out again and freezes the price, exactly like upstream.

**What changed in `exec`** (`MovingPegSwap.sol`):

- `:159` re-checks the band cap at exec time: `0 < maxDeviationBps ≤ 1000`, else
  `MovingPegSwapInvalidMaxDeviation(maxDeviationBps)`, before any provider is called.
- `:161-168` picks the anchors like upstream and resolves each side's live rate through
  `_resolveRate` (`:126-132`): provider `address(0)` means "use the reference rate"; a zero rate
  reverts (`:128`); a rate outside `ref × (1 ± maxDeviationBps/10000)` reverts (`:129`).
- `:175-176` normalizes to value units: `x0 = ⌊balanceIn·rateIn/1e18⌋`, `y0 = ⌊balanceOut·rateOut/1e18⌋`.
- `:189` `x1 = x0 + ⌊amountIn·rateIn/1e18⌋`; `:230` `amountOut = ⌊(y0 − y1)·1e18/rateOut⌋`;
  `:253` `amountIn = ⌈(x1 − x0)·1e18/rateIn⌉`; `:206` drain `⌈(x1Capped − x0)·1e18/rateIn⌉`.
- The anchors are supplied in value units: `anchorFor(balance, rate) = ⌊balance·rate/1e18⌋` (`:120-122`).

**Claim 1: with value-balanced anchors the centre is `x = y·r(t)`.** Let the ETH side (rate 1e18)
be `x`, the wstETH side `y`, and fix `x0_init = y0_init = S` at ship. Ignoring floors,
`u = x/S` and `v = y·r(t)/S` with `r(t)` the live rate over 1e18. The curve is symmetric in
`u, v`, so its slope at `u = v` is `dv/du = −1`, i.e. `d(x)/d(y·r(t)) = −1`: one unit of ETH value
for one unit of wstETH value, price `dx/dy = r(t)` ETH per wstETH. And `u = v ⟺ x = y·r(t)`.
Neither statement involves the order bytes: `S` stays, `r(t)` comes from the provider (`:127`)
and `C` is recomputed from the balances each swap (`:179`). When the rate moves, the pool just
finds itself at a new point `(u, v)`, on a new level curve, whose centre is at the new rate.

Script result, `python3 analysis/s2_moving_centre.py` (2a): anchors 6e18 fixed, balances put at
`y = 5e18`, `x = y·r(t)`, price probed with a 1e12-wei trade in each direction:

| live r(t) | u = v | buy (A=50) | sell (A=50) |
|---|---|---|---|
| 1.14e18 | 0.9500000000 | 1.1400000010 | 1.1399999988 |
| 1.2e18 | 1.0000000000 | 1.2000000010 | 1.1999999988 |
| 1244787728742679575 | 1.0373231073 | 1.2447877297 | 1.2447877275 |
| 1.25e18 | 1.0416666667 | 1.2500000010 | 1.2499999988 |
| 1.26e18 | 1.0500000000 | 1.2600000010 | 1.2599999988 |

Buy and sell straddle r(t) for every rate (A = 0 and 300 give the same picture, see the script).

**Claim 2: rescaling both anchors by r(t) cancels r(t) (the frozen-price mistake).** If
`y0_init(t) = Y·r(t)`, then `v = y·r(t)/(Y·r(t)) = y/Y`, exactly the §1 cancellation: the centre is
back at `x/y = X/Y = 1.2`, whatever r(t) is. Script result (2b), A = 50, price at the centre of
each scheme: ours `1.1400000010, 1.2000000010, 1.2447877297, 1.2500000010, 1.2600000010` for the
five rates; rescaled anchors `1.2000000010` for all five.

**Claim 3 (why the anchors must be value-balanced).** With `x0_init ≠ y0_init` the slope at
`u = v` is `dx/dy = r(t)·x0_init/y0_init`. Script result (2c): anchors 6e18 and 7.2e18 give a
centre price `1.0000000008` at r = 1.2 and `1.0416666675` at r = 1.25, not the rate.

---

## 3. Measured economics

**In plain English.** When the rate moves, both designs are suddenly off their best price and an
arbitrageur takes the difference. For ours that difference is tiny, because only the pool's
position on the curve is off, not the peg. It is smaller than the frozen peg's at every width,
and thousands of times smaller from width 20 up. Many small rate steps leak far less than one big step. A rate drop behaves
the same as a rise. The real exposure is different: someone who knows a rate report is coming can
buy the pool's wstETH just before it and sell it back just after. That takes the report's whole
rate gain on the pool's wstETH, whatever the width. The 0.05% fee stops this only when one report
moves the rate by less than about 10 bps.

Setup for §3a-3d: demo order (6e18 ETH side + 5e18 wstETH side, ship rate 1.2e18, anchors 6e18,
band 500). "Frozen" = upstream PeggedSwap on the same deposit (peg fixed at 1.2; it has no
oracle and no band). Profit = the best single exactIn trade, valued at the true new rate,
searched over integer sizes on the exact model; the continuous (real-number) optimum of the same
curve is computed independently in `arb.py` and agrees with every row below to 12 decimals of
ETH. bps are of the pool's value at the new rate.

### 3a. Arbitrage after one rate step — `python3 analysis/s3a_arb_step.py`

Step 1.20 → 1.21 (pool value 12.05 ETH):

| A | ours, ETH | ours, bps | frozen, ETH | frozen, bps |
|---|---|---|---|---|
| 0 | 0.000051867443 | 0.043044 | 0.000207468880 | 0.172173 |
| 20 | 0.000001262498 | 0.001048 | 0.008229419017 | 6.829393 |
| 50 | 0.000000512484 | 0.000425 | 0.017811713541 | 14.781505 |
| 100 | 0.000000257514 | 0.000214 | 0.027457406117 | 22.786229 |
| 300 | 0.000000086123 | 0.000071 | 0.040045637085 | 33.232894 |

Step 1.20 → 1.25 (pool value 12.25 ETH):

| A | ours, ETH | ours, bps | frozen, ETH | frozen, bps |
|---|---|---|---|---|
| 0 | 0.001275643042 | 1.041341 | 0.005102040816 | 4.164931 |
| 20 | 0.000030802633 | 0.025145 | 0.138303239634 | 112.900604 |
| 50 | 0.000012502181 | 0.010206 | 0.192344071835 | 157.015569 |
| 100 | 0.000006281873 | 0.005128 | 0.218272485948 | 178.181621 |
| 300 | 0.000002100855 | 0.001715 | 0.238686156825 | 194.845842 |

A wider curve makes ours better and the frozen peg worse. The frozen peg stays off-price after
the arb, so every further step costs it again.

### 3b. Path dependence — `python3 analysis/s3b_path.py`

Rate 1.20 → 1.25 in N equal integer steps, best arb after every step, applied to the balances:

| A | N = 1 | N = 10 | N = 100 |
|---|---|---|---|
| 0 | 0.001275643042 ETH | 0.000126405134 | 0.000012628863 |
| 50 | 0.000012502181 | 0.000001244625 | 0.000000124405 |
| 300 | 0.000002100855 | 0.000000209154 | 0.000000020906 |

N steps leak about 1/N of one jump (the loss is about quadratic in the step size), so a rate that
moves often in small steps costs less than one that jumps.

### 3c. Rate drop — `python3 analysis/s3c_rate_drop.py`

| r1 | A | ours, ETH | ours, bps | frozen, ETH | frozen, bps |
|---|---|---|---|---|---|
| 1.19 | 0 | 0.000052301484 | 0.04377 | 0.000209205021 | 0.17507 |
| 1.19 | 50 | 0.000000518909 | 0.00043 | 0.017922718737 | 14.99809 |
| 1.19 | 300 | 0.000000087206 | 0.00007 | 0.040115940293 | 33.56982 |
| 1.15 | 0 | 0.001329937765 | 1.13186 | 0.005319148936 | 4.52694 |
| 1.15 | 50 | 0.000013306028 | 0.01132 | 0.194329670621 | 165.38695 |
| 1.15 | 300 | 0.000002236316 | 0.00190 | 0.239142478536 | 203.52551 |
| 1.14 | 0 | 0.001923393115 | 1.64393 | 0.007692307692 | 6.57462 |
| 1.14 | 50 | 0.000019284458 | 0.01648 | 0.243108936663 | 207.78542 |
| 1.14 | 300 | 0.000003241156 | 0.00277 | 0.289176718283 | 247.15959 |

1.14e18 is the band floor (1.2e18 × 9500/10000, inclusive). At `1139999999999999999` our order
reverts (`MovingPegSwapRateOutOfBand`): below the band it stops trading instead of pricing a rate
it was not built for. The frozen peg keeps trading at 1.2.

### 3d. Trading around a rate report — `python3 analysis/s3d_sandwich.py`

The rate jumps r0 → r1 in one transaction. A trader who can order trades around it does leg 1 (any
exactIn at r0) just before and leg 2 (the best arb at r1) just after. Two measures, each
maximised over the size of leg 1:

- **(L) live-marked**: each leg valued at the rate live when it ran. This leaves out the gain from
  holding wstETH across the report.
- **(M) maker loss**: pool value at r1 minus the value of just holding the deposit at r1 (both legs
  valued at r1). This is what the maker loses, and it equals the trader's profit in ETH.

| step | A | fee | plain back-run | (L) best | (M) best | (M) bps |
|---|---|---|---|---|---|---|
| 1.20→1.21 | 0 | 0 | 0.000051867443 | 0.100000000000 | 0.050000000000 | 41.4938 |
| 1.20→1.21 | 20 | 0 | 0.000001262498 | 0.000735580817 | 0.050000000000 | 41.4938 |
| 1.20→1.21 | 50 | 0 | 0.000000512484 | 0.000293109977 | 0.050000000000 | 41.4938 |
| 1.20→1.21 | 100 | 0 | 0.000000257514 | 0.000146352810 | 0.050000000000 | 41.4938 |
| 1.20→1.21 | 300 | 0 | 0.000000086123 | 0.000048737891 | 0.050000000000 | 41.4938 |
| 1.20→1.21 | 50 | 5000 | 0.000000000000 | 0.000000000000 | 0.044045965212 | 36.5527 |
| 1.20→1.25 | 0 | 0 | 0.001275643042 | 0.500000000000 | 0.250000000000 | 204.0816 |
| 1.20→1.25 | 20 | 0 | 0.000030802633 | 0.003647968178 | 0.250000000000 | 204.0816 |
| 1.20→1.25 | 50 | 0 | 0.000012502181 | 0.001453611476 | 0.250000000000 | 204.0816 |
| 1.20→1.25 | 100 | 0 | 0.000006281873 | 0.000725802357 | 0.250000000000 | 204.0816 |
| 1.20→1.25 | 300 | 0 | 0.000002100855 | 0.000241704039 | 0.250000000000 | 204.0816 |
| 1.20→1.25 | 50 | 5000 | 0.000000000000 | 0.000000000000 | 0.244045965212 | 199.2212 |

(All values in ETH. (M)'s best leg 1 is always "buy all the wstETH", e.g. 6069801516926195372 wei
at A = 50 without the fee.)

What (M) says. Without the fee the maker's loss is exactly `5 wstETH × (r1 − r0)`: 0.05 ETH for
+0.01, 0.25 ETH for +0.05, at every width. The trader buys the pool's whole wstETH side at r0 and
sells it back at r1; the curve slippage of the two legs cancels because the pool returns to its
centre. So a report that everyone can see coming costs the maker the whole report gain on its
wstETH inventory. The limit is the inventory, not the width. With the fee the loss goes down only
slightly (0.244045965212 instead of 0.250000000000). This is larger than the frozen peg's plain
arbitrage on the same step at A = 50 (0.017811713541 / 0.192344071835 ETH, §3a), but it is capped at one
report's gain on the inventory. The frozen peg's loss keeps growing with every step (§3a).

(L) is the measure the earlier probe used. It is smaller, but it does not describe the maker's loss.

This is an oracle-timing risk, not a flaw in the curve maths. The design removes the stale-peg
loss (§3a). It does not remove the loss to someone who trades before a rate update everyone can
predict. §3e shows the fee blocks that only for small per-report steps.

### 3e. The 0.05% fee against a small rate step — `python3 analysis/s3e_fee_roundtrip.py`

FeeFlatIn with feeBps 5000 on its 1e7 scale, placed before MovingPegSwap (as
`test/MovingPegSwap.t.sol:181-183`). Round trip: exactIn 1e18 of the ETH side at 1.2e18, the rate
steps, then sell everything received back.

**Part 1: the committed forge numbers are reproduced bit-exactly** (taker net ETH-side wei):

| step | fee | model | forge log (test_M_Fee_RateStepRoundTrip) |
|---|---|---|---|
| +1bp | 0 | 99444698259675 | 99444698259675 |
| +1bp | 5000 | -899622604228900 | -899622604228900 |
| +3bp | 5000 | -700931903607749 | -700931903607749 |
| +3bp | 0 | 298333992743292 | 298333992743292 |

`all four equal: True`. No explanation needed: the model is the same arithmetic.

**Part 2: both signs, fixed size and best size.** For −1bp and −3bp the round trip starts with the
wstETH side, since that is the direction that gains; P&L is in wstETH wei, shown in ETH at r1.

| step | fee | P&L at 1e18 (token wei) | in ETH | best size (wei) | best P&L, ETH |
|---|---|---|---|---|---|
| +1 | 0 | 99444698259675 | 0.000099444698 | 6069801512593620301 | 0.000599999703 |
| +1 | 5000 | -899622604228900 | -0.000899622604 | none | 0 |
| +3 | 0 | 298333992743292 | 0.000298333993 | 6069801513784801365 | 0.001799997326 |
| +3 | 5000 | -700931903607749 | -0.000700931904 | none | 0 |
| −1 | 0 | 99492308450860 | 0.000119378831 | 5058167928720701057 | 0.000603455134 |
| −1 | 5000 | -899426090593806 | -0.001079203378 | none | 0 |
| −3 | 0 | 298536384469201 | 0.000358136188 | 5058167929226556007 | 0.001810363078 |
| −3 | 5000 | -700580671913528 | -0.000840444597 | none | 0 |

With the fee no trade size is taker-positive at ±1bp or ±3bp. Without it the best size is the whole
inventory, and the gain is the inventory times the step (the §3d effect).

**Part 3: break-even step.** Searching the step size for the smallest upward step whose best-size
round trip is taker-positive (A = 50): without the fee **r0 + 1 wei** (P&L 3 wei); with the fee
**r0 + 1206113946104793 wei = 10.0509 bps of r0** (best size 6072837917463250681 wei). The search
assumes the best P&L grows with the step size.

---

## 4. Safety

**In plain English.** The order refuses to trade on a zero rate or a rate outside its band. It
cannot be built with a band above 10%, and it also refuses to trade with one when
the order bytes were written by hand instead of through `build`. Every rounding step favours the maker. A round trip at
an unchanged rate never pays the taker, and no trade can take more than the pool holds. In the
dust corner the taker never gets more value than it pays. Overflow only happens at pool sizes far
beyond any real token supply, and it reverts rather than mispricing. The one known wei-level leak,
at anchors above ~1e27 value units per side, was accepted by the owner and is measured below.

### 4a. Guards — `python3 analysis/s4_safety.py` (4a)

| guard | where | measured |
|---|---|---|
| anchors > 0 | build `:85` | build(x0=0) → `MovingPegSwapInvalidInitialBalances` |
| width ≤ 5000e27 | build `:86` | 5000e27+1 → `MovingPegSwapInvalidLinearWidth` |
| reference rates > 0 | build `:87` | refRateGt=0 → `MovingPegSwapInvalidRefRates` |
| 0 < band ≤ 1000 bps | build `:88` (cap `:28`) | band 0 and 1001 revert, 1000 ok |
| 0 < band ≤ 1000 bps, at exec | exec `:159` | order bytes with a hand-encoded band: 0, 1001 and 65535 → `MovingPegSwapInvalidMaxDeviation(band)` in all four direction/mode combinations; 1 and 1000 trade |
| live rate ≠ 0 | exec `:128` | rate 0 → `MovingPegSwapZeroRate` |
| live rate in band | exec `:129` | 1.14e18 and 1.26e18 trade (inclusive); 1.14e18−1 and 1.26e18+1 → `MovingPegSwapRateOutOfBand` |

A reverting provider reverts the swap (`:127`, no try/catch).

### 4b. Rounding directions

Every rounding in `exec` is chosen to favour the maker:

| step | line | direction |
|---|---|---|
| balances to value units | `:175-176` | down (the pool looks poorer) |
| input to value units | `:189` | down |
| `u1` | `:192` | down |
| `y1` | `:226` | up, so `amountOut` is smaller |
| `amountOut` back to tokens | `:230` | down |
| drain `x1Capped` | `:204` | up |
| drain `amountIn` | `:206` | up; at least 1 wei (`:209`) |
| exactOut value removed `c` | `:238` | up; saturates at 0 (`:239`) |
| `v1` | `:242` | down |
| `x1` | `:249` | up |
| `amountIn` back to tokens | `:253` | up; at least 1 wei (`:256`) |

Measured (4b), 20000 random cases (random anchors 1e15..1e24, balances, sizes, directions, modes,
widths {0, 20, 50, 300}, five rates, live rate within ±4% of reference), for ours and for
upstream PeggedSwap:

| | ours | upstream |
|---|---|---|
| reverted | 0 | 0 |
| invariant after − before: min | −118 | −634 |
| cases with a decrease | 10 | 10 |
| worst relative decrease −dC/C | 1.21e-27 | 8.73e-28 |
| exactIn round trip at the same rate, max taker gain | −1 wei | 0 wei |
| cases with a taker gain | 0 | 0 |

The invariant can fall by about 1e-27 of itself, from the floors inside `PeggedSwapMath.solve`.
Upstream shows the same. That is far below one wei of value for any pool in the 1e15..1e24 range
tested. No round trip at a fixed rate ever returned more than it cost. (Informational: an exactOut
for the output that an exactIn produced can cost less than that exactIn, by at most a relative
4.0e-19 for ours and 1.5e-19 for upstream. exactIn rounds its output down, and the taker, not the
maker, pays for that.)

### 4c. Drain and capacity (4c)

Demo pool, A = 50. An exactIn of 1e30 pays out exactly the output balance (5e18) and is charged
`6069801516926199140` at r = 1.2e18 and `6294382899261806757` at r = 1244787728742679575. An exactOut of
1e30 is clamped to the balance and charged the same amount. The output can never exceed the
live balance: the drain branch pays `y0_raw` (`:220`) and exactOut clamps to it (`:233`).

### 4d. Dust floors (4d)

When the output reserve is so small that its value rounds to 0 in value units, a curve price
would let 1 wei of input take it. Two floors stop that:

- drain: at least 1 wei in (`:209`); and if the normalized output `y0 == 0`, input worth at least
  the output (`:215-217`);
- exactOut: at least 1 wei in (`:256`); and if the normalized output `y0 == 0` (the same gate as
  the drain floor), input worth at least the output (`:262-264`). An earlier revision gated this on
  `c > y0` (removed value above the floored reserve), which also fired on a full-reserve exactOut
  whenever `balance × rate` was not a multiple of 1e18.

Measured: output rate 0.3e18, balanceOut 1, 2 or 3 wei → drain charges 1 wei (1 wei at rate 1e18
is worth ≥ 3 wei at 0.3e18); exactOut of 3 wei of 3 → 1 wei. rateIn 0.05e18, rateOut 0.999e18,
exactOut 1 of 1 wei → **20 wei in** (value 1000000000000000000 ≥ 999000000000000000 out, in 1e-18 units).

**Gate comparison, measured (4d).** Full-reserve exactOut (amount = the whole wstETH-side reserve),
ETH side = Lt at 1e18, provider on Gt, A = 50, anchors `anchorFor(deposit, rate)`, ETH-side
deposit 6e18. `in current` is the model of the current code (these are parity rows H, so the
Solidity returns the same wei); `in legacy` is the model with the old gate:

| case | y0 | c | in current | in legacy | exactIn drain in |
|---|---|---|---|---|---|
| depGt 6e18, r 1183746519283746519 | 7102479115702479114 | 7102479115702479114 | 6069801516926199140 | 6069801516926199140 | 6069801516926199140 |
| depGt 6e18+1 | 7102479115702479115 | 7102479115702479116 | 6069801516926199140 | 7102479115702479116 | 6069801516926199140 |
| depGt 6e18+7 | 7102479115702479122 | 7102479115702479123 | 6069801516926199140 | 7102479115702479123 | 6069801516926199140 |
| depGt 6e18+123456789 | 7102479115848620658 | 7102479115848620659 | 6069801516926199140 | 7102479115848620659 | 6069801516926199140 |
| depGt 6.5e18 | 7694352375344352373 | 7694352375344352374 | 6069801516926199140 | 7694352375344352374 | 6069801516926199140 |

On these over-valued pools (the wstETH side holds more value than the ETH side, and the anchors
were taken from those deposits) the old gate charged the value floor only when the product was
fractional, so the full-reserve exactOut cost 1.0327 to 1.6246 ETH more than the exactIn drain of
the same reserve. Now both paths charge `6069801516926199140`, the curve price. That price
is below the output's value (about 6.07e18 in for 7.10e18 or more out, in value units). This is
not new: the exact-product row was charged the same under the old gate. The anchors put the curve's
centre where the maker's deposits are (§2 Claim 3), not at equal value.

On value-balanced pools (wstETH-side deposit `6e18 × 1e18 / rOut + 7` wei, output rates 0.3e18,
0.999e18, 1e18, 1183746519283746519, 1.2e18, 3e18) both gates give the same
`6069801516926199140`, and value in ≥ value out holds in every row.

### 4e. Overflow (4e)

All arithmetic is checked (Solidity 0.8), so an overflow reverts; it never misprices. Measured
limits for 1e18-scale rates (1e18 and 1244787728742679575), widths 0 / 50 / 300 / 5000, pool at
its centre:

- 1% exactIn and exactOut in both directions: fine up to **1.1464e+50 value units per side**
  (1.146e+32 ETH-side tokens); the first failure is `u1*x0_init` (`:249`).
- a full drain with an exactIn of 10× the balance: fine up to **1.0527e+49** per side; the first
  failure is `x1*ONE` (`:192`). The limit here is the requested amount, since
  `(balance + amount)` in value units must stay below `(2**256−1)/1e27 = 1.1579e+50`.
- the raw product `balance × rate` (`:175`) at rate 1244787728742679575 allows up to 9.3022e+58 wei.

These are far beyond any real token balance. The upstream comments' "x ≤ 1e30" bounds
(`PeggedSwapMath.sol:55`) are documentation, not the real limit.

### 4f. Large anchors (owner-accepted edge) (4f)

With anchors above about `ONE = 1e27` value units per side, one wei of output moves `v` by less
than one unit of the 1e27 scale. So a tiny exactOut can round to "costs 0" on the curve and pay
the 1-wei minimum. Pool at its centre, rate 1.2e18, A = 50:

| anchor S (value units per side) | largest k charged 1 wei | max (k·1.2 − in), wei of value | exactIn(1 wei) → out |
|---|---|---|---|
| 1.0e24 | 0 | 0.0 | 0 |
| 1.0e27 | 0 | 0.8 | 0 |
| 1.0e28 | 15 | 18.8 | 15 |
| 1.2e30 | 1000 | 1200.0 | 0 |
| 1.0e33 | 1666665 | 1999997.0 | 1666665 |

(k scanned 1..200, 1..3000 at 1.2e30; at 1.0e33 only the plateau end.) So the leak per trade is
about `S / 1e27` wei of value. At 1.2e30 that is 1200 wei, far below gas.
Off-centre, large anchors can also make a small exactOut revert
(Panic at `:253`, `x1 − x0` underflow): 6 of 3000 random quotes at S = 1.2e30, 0 of 3000 at 6e18
and at 1e27. Decision 2026-09-25: accepted, same maths as upstream,
unreachable for WETH/wstETH (more than ~1e9 tokens per side).

---

## 5. Assumptions and limits

1. **stETH ≈ ETH.** The WETH/wstETH demo prices wstETH at `stEthPerToken()` ETH, i.e. it treats
   1 stETH as 1 ETH (README "Demo pair"). If stETH trades below ETH, the pool sells wstETH too
   cheaply by that discount. Nothing here measures or hedges that.
2. **The rate must not be movable inside a block by a trader**, and the maker is exposed to
   predictable updates. §3d: whoever trades just before a known report takes up to
   `inventory × step` from the pool, whatever the width. The fee stops it only below ≈10.05 bps
   per report (§3e Part 3). This document does NOT measure the real per-report step of
   `stEthPerToken()`. The only live fact used is one reading, `1244787728742679575` at block
   26052660. Measuring the step is an open item.
3. **Band.** Owner values: 500 bps per order, hard cap 1000 bps (`:28`, checked at build `:88`
   and again at exec `:159`).
   An order stops trading once the live rate is more than the band away from the order's reference
   rate (§3c). A long-lived order therefore needs re-shipping as the rate drifts.
4. **Value-balanced anchors are the maker's job.** §2 Claim 3: if they are not balanced at ship,
   the centre is off by `x0_init/y0_init`.
5. **Two guards were tightened after the first internal review.**
   - `exec` re-checks the 1000-bps cap right after `parse` (`:159`). Before, only `build` checked
     it (`:88`), so order bytes encoded by hand could carry any `uint16` band into `exec`.
   - the exactOut dust value floor gate (`:262`) changed from `c > y0` to `y0 == 0`, the same
     gate as the drain floor (`:215`). §4d shows where the two gates differ.
   Re-running every script after the change printed the same numbers as before for all of
   §1-§3 and §4b, 4c, 4e, 4f; only §4a and §4d gained rows. Headline numbers, quoted from that
   run: §3a at A = 50, step 1.20 → 1.25, ours `0.010206` bps vs frozen `157.015569` bps; §3d (M)
   `0.050000000000` / `0.250000000000` ETH at every width; §3e break-even `r0 + 1 wei` without
   the fee and `r0 + 1206113946104793 wei (= 10.0509 bps of r0)` with it; §4e `1.1464e+50` value
   units.

---

## 6. Reproduce

Python 3 standard library only; no installs; no network. From `packages/contracts/analysis`:

```
python3 s1_upstream_curve.py    # 'cases=2000  bit-identical=2000 ... mismatches=0'; price '= 1.200000000'; 1e EQUAL x4
python3 s2_moving_centre.py     # 2a table; 2b 'rescaled anchors 1.2000000010' for every r(t)
python3 s3a_arb_step.py         # 3a tables (ours vs frozen, 1.21 and 1.25)
python3 s3b_path.py             # 3b table (N = 1, 10, 100)
python3 s3c_rate_drop.py        # 3c table; 'r1 = 1139999999999999999: reverts (MovingPegSwapRateOutOfBand)'
python3 s3d_sandwich.py         # 3d tables (~1 min); (M) '0.050000000000' / '0.250000000000'
python3 s3e_fee_roundtrip.py    # 'all four equal: True'; '= 10.0509 bps of r0'
python3 s4_safety.py            # 4a-4f; 'ok up to 1.1464e+50 value units per side'; 4a hand-encoded band rows; 4d gate comparison table
python3 gen_parity.py --check   # 'MovingPegSwap rows: 109 (4 expect revert); band rows: 18 (12 expect
                                #  MovingPegSwapInvalidMaxDeviation); PeggedSwap rows: 16'
                                # 'test/ModelParity.t.sol tables match the model: True'
```

From `packages/contracts`:

```
forge test --match-path test/ModelParity.t.sol   # 3 tests pass: 109 + 18 + 16 rows, exact wei equality
forge test                                       # full suite
```

The parity test (`test/ModelParity.t.sol`) runs `MovingPegSwap.exec` and upstream `PeggedSwap.exec`
through a direct harness (exact balances, no router), with a `MockRateProvider` for the live
rate. Its rows cover both directions, exactIn and exactOut, widths 0 / 50e27 / 300e27, rates 1e18,
1.2e18, 1244787728742679575, 1183746519283746519 and 0.3e18, the provider on either side, a live rate
different from the reference, band edges, a zero rate, pools from 1 wei to 1e45 value units,
drains, clamps, both dust floors, the large-anchor 1-wei exactOut, an off-centre underflow revert,
the gate cases of §4d (full-reserve exactOut and exactIn drain on over-valued and
value-balanced pools), and order bytes with a hand-encoded band (0, 1001, 65535 revert with
`MovingPegSwapInvalidMaxDeviation(band)`, asserted by selector and argument, in both directions and
both modes; 1 and 1000 trade, and their patched bytes equal `build`'s).
