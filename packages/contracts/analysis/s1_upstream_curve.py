"""MATH.md section 1: the upstream PeggedSwap curve.
  1a finite reserves: the most one side can pay out, per width (hard boundary)
  1b drain branch: an exactIn past capacity pays out exactly the whole balance
  1c the rates cancel: two parameterizations give bit-identical trades
  1d the peg is the ship-time balance ratio, whatever rateA/rateB say
Run: python3 s1_upstream_curve.py
"""
import random
from fractions import Fraction as F
from decimal import Decimal, getcontext
from swapvm_math import ONE, Revert, solve, invariant
from pegged_model import pegged_build, pegged_exec

getcontext().prec = 60
E = 10**18

print("=== 1a FINITE RESERVES: centre u=v=1 gives C = 2 + 2A; with the other side at 0,")
print("       a side can grow to at most u* where sqrt(u*) + A u* = C (PeggedSwapMath.solve(C, a))")
print(f"  {'A (width/1e27)':>15} | {'C/ONE':>8} | {'u* (integer solve, 1e27-scaled)':>32} | {'u* real':>14}")
for A in (0, 20, 50, 100, 300):
    a = A * ONE
    C = invariant(ONE, ONE, a)
    ustar = solve(C, a)
    Ad = Decimal(A)
    real = (Decimal(2 + 2 * A)) ** 2 if A == 0 else ((-1 + (1 + 4 * Ad * (2 + 2 * Ad)).sqrt()) / (2 * Ad)) ** 2
    print(f"  {A:>15} | {C / 10**27:>8.0f} | {ustar:>32} | {float(real):>14.10f}")
print("  -> the paying side can grow to at most u* x its anchor; the other side reaches 0 only there.")

print("\n=== 1b DRAIN BRANCH (PeggedSwap.sol:151-158), pool X=6e18, Y=5e18, rates 1/1, A=50")
args = pegged_build(6 * E, 5 * E, 50 * ONE, 1, 1)
for amt in (10**18, 10 * E, 10**24):
    ai, ao = pegged_exec(True, True, 6 * E, 5 * E, amt, args)
    print(f"  exactIn request {amt:>26} -> amountIn charged {ai:>22}, amountOut {ao:>20}"
          f"{'  (= whole balance 5e18: drained)' if ao == 5 * E else ''}")
ai, ao = pegged_exec(True, False, 6 * E, 5 * E, 7 * E, args)
print(f"  exactOut request 7e18 (> balance) -> clamped amountOut {ao}, amountIn {ai}")

print("\n=== 1c THE RATES CANCEL: P_raw (anchors X,Y; rates 1,1) vs P_rate (anchors X*ra, Y*rb;")
print("       rates ra, rb) on the same balances and amount. Bit-exact comparison.")
random.seed(20260925)
n = same = rev_both = 0
mism = []
for _ in range(2000):
    X = random.randrange(10**15, 10**24); Y = random.randrange(10**15, 10**24)
    ra = random.choice([1, 3, 7919, 10**6, 10**12, 10**18, 1244787728742679575])
    rb = random.choice([1, 3, 7919, 10**6, 10**12, 10**18, 1183746519283746519])
    A = random.choice([0, 1, 20, 50, 100, 300, 5000]) * ONE
    bi = random.randrange(max(1, X // 4), 3 * X); bo = random.randrange(max(1, Y // 4), 3 * Y)
    exact_in = random.random() < 0.5
    lt_in = random.random() < 0.5
    amt = random.randrange(1, max(2, (bi if exact_in else bo) // 3))
    if random.random() < 0.1:
        amt = 10 * bi  # push into the drain / clamp paths
    def run(args):
        try:
            return pegged_exec(lt_in, exact_in, bi, bo, amt, args)
        except Revert as e:
            return "revert"
    o1 = run(pegged_build(X, Y, A, 1, 1))
    try:
        o2 = run(pegged_build(X * ra, Y * rb, A, ra, rb))
    except Revert:
        o2 = "build-revert"
    n += 1
    if o1 == o2:
        same += 1
        rev_both += o1 == "revert"
    else:
        mism.append((X, Y, ra, rb, A, bi, bo, amt, exact_in, lt_in, o1, o2))
print(f"  cases={n}  bit-identical={same}  (of which both revert: {rev_both})  mismatches={len(mism)}")
for m in mism[:5]:
    print("   MISMATCH", m)

print("\n=== 1d THE PEG IS THE SHIP-TIME BALANCE RATIO X/Y = 1.2, whatever the rates say")
print("       deposit X=6e18 (tokenA), Y=5e18 (tokenB); anchors = balance*rate as PeggedSwap.sol:32-33 says")
print(f"  {'rateA':>20} {'rateB':>22} | {'A':>4} | price at rest, tokenA per tokenB (1e9-wei probe)")
for ra, rb in ((1, 1), (10**18, 12 * 10**17), (10**18, 125 * 10**16), (10**18, 1244787728742679575)):
    for A in (0, 50):
        args = pegged_build(6 * E * ra, 5 * E * rb, A * ONE, ra, rb)
        ai, ao = pegged_exec(True, True, 6 * E, 5 * E, 10**9, args)
        print(f"  {ra:>20} {rb:>22} | {A:>4} | {ai}/{ao} = {ai / ao:.9f}")
print("  -> setting rateB to 1.25e18 or 1.2448e18 does not move the price: it stays X/Y = 1.2.")

print("\n=== 1e ROUTER CROSS-CHECK: the committed PeggedSwapBaseline B2 tests (real Aqua router,")
print("       forge test --match-test test_B2 -vv) against this model; world rate 1.25e18")
FORGE = {"B2 amountOut tokenB": 104155923072964493, "B2 takerGain": 5194903841205616,
         "B2 exactOut amountIn tokenA": 6069801516926199140, "B2 shortfall": 180198483073800860}
args = pegged_build(6 * E, 5 * E, 50 * ONE, 1, 1)
_, out = pegged_exec(True, True, 6 * E, 5 * E, 125 * 10**15, args)
gain = out * 125 * 10**16 // E - 125 * 10**15
cost, _ = pegged_exec(True, False, 6 * E, 5 * E, 5 * E, args)
short = 5 * E * 125 * 10**16 // E - cost
for k, v in zip(FORGE, (out, gain, cost, short)):
    print(f"  {k:<28} model {v:>22}  forge log {FORGE[k]:>22}  {'EQUAL' if v == FORGE[k] else 'DIFFERENT'}")
