"""MATH.md section 3e: the 0.05% input fee (FeeFlatIn feeBps 5000 on its 1e7 scale, placed
before MovingPegSwap exactly as test/MovingPegSwap.t.sol:181-183) against a small rate step.
Round trip: trade 1, provider rate steps by s bps, trade 2 sells everything received back.
Part 1 reproduces test_M_Fee_RateStepRoundTrip (MovingPegSwap.t.sol:1053-1082) bit-exactly:
  demo order 6e18 ETH-side + 5e18 wstETH-side at 1.2e18, width 50e27, band 500;
  exactIn 1e18 ETH-side -> wstETH; rate = 1.2e18 + 1.2e18*bps/10000; exactIn all of it back.
Part 2 extends to -1bp / -3bp (reverse order: wstETH first, P&L in wstETH, shown in ETH at r1)
and to the best trade size for each step (integer search over 1 .. 40e18 wei).
Run: python3 s3e_fee_roundtrip.py
"""
from fractions import Fraction as F
from swapvm_math import ONE, Revert
from moving_peg_model import Order
from arb import best_int
from common import X_ETH, Y_WST, R0, PROVIDER, moving_args, rate_frac, eth

E = 10**18
COMMITTED = {(1, 0): 99444698259675, (1, 5000): -899622604228900,
             (3, 5000): -700931903607749, (3, 0): 298333992743292}


def round_trip(bps, fee, size):
    """Returns taker P&L: + steps in ETH-side wei (ETH->wst->ETH), - steps in wst wei."""
    o = Order(moving_args(50 * ONE), X_ETH, Y_WST, fee)
    r1 = R0 + R0 * bps // 10000
    if bps >= 0:
        _, out1 = o.swap("lt", True, size, {PROVIDER: R0})
        _, out2 = o.swap("gt", True, out1, {PROVIDER: r1})
    else:
        _, out1 = o.swap("gt", True, size, {PROVIDER: R0})
        _, out2 = o.swap("lt", True, out1, {PROVIDER: r1})
    return out2 - size, r1


print("=== Part 1: reproduce test_M_Fee_RateStepRoundTrip (1e18 trade, P&L in ETH-side wei)")
ok = True
for (bps, fee), want in COMMITTED.items():
    got, _ = round_trip(bps, fee, 10**18)
    ok &= got == want
    print(f"  +{bps}bp fee={fee:>4}: model {got:>20}   forge log {want:>20}   {'EQUAL' if got == want else 'DIFFERENT'}")
print(f"  all four equal: {ok}")

print("\n=== Part 2: +/-1bp and +/-3bp, fixed 1e18 trade and best trade size")
print(f"  {'step':>5} {'fee':>5} | {'P&L @1e18 (token wei)':>22} {'in ETH':>16} | {'best size (wei)':>22} {'best P&L ETH':>16}")
for bps in (1, 3, -1, -3):
    for fee in (0, 5000):
        p, r1 = round_trip(bps, fee, 10**18)
        pe = p if bps >= 0 else p * rate_frac(r1)

        def f(t):
            try:
                v, _ = round_trip(bps, fee, t)
            except Revert:
                return None
            return F(v) if bps >= 0 else v * rate_frac(r1)
        t, v = best_int(f, 1, 40 * E, window=64)
        if v <= 0:
            t, v = 0, F(0)
        print(f"  {bps:>+5} {fee:>5} | {p:>22} {eth(pe):>16} | {t:>22} {eth(v):>16}")
print("  best P&L 0 with size 0 = no size makes the round trip taker-positive.")


# ---------------------------------------------------------------- Part 3: break-even step
def best_rt_up(r1, fee):
    """Best taker P&L (ETH-side wei) over size for ETH->wst at R0, then all back at r1."""
    def f(t):
        o = Order(moving_args(50 * ONE), X_ETH, Y_WST, fee)
        try:
            _, out1 = o.swap("lt", True, t, {PROVIDER: R0})
            _, out2 = o.swap("gt", True, out1, {PROVIDER: r1})
        except Revert:
            return None
        return F(out2 - t)
    return best_int(f, 1, 40 * E, window=64)


print("\n=== Part 3: smallest upward rate step that makes the best-size round trip taker-positive")
print("    (A=50, band 500; this is also the 'buy the wstETH side before a rate report' trade)")
for fee in (0, 5000):
    lo, hi = 0, R0 * 500 // 10000          # search the step d (wei of rate) within the band
    if best_rt_up(R0 + hi, fee)[1] <= 0:
        print(f"  fee={fee}: never positive within the band")
        continue
    while lo + 1 < hi:
        mid = (lo + hi) // 2
        if best_rt_up(R0 + mid, fee)[1] > 0:
            hi = mid
        else:
            lo = mid
    t, v = best_rt_up(R0 + hi, fee)
    print(f"  fee={fee:>4}: first positive at r1 = r0 + {hi} wei  (= {hi / R0 * 1e4:.4f} bps of r0),"
          f" best size {t} wei, P&L {v} wei")
