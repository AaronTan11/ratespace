"""MATH.md section 3d: trading around an oracle report (our design).
The provider rate jumps r0 -> r1 in one transaction (a rate report). Someone who can order
trades around it (e.g. one atomic bundle) does:
  leg1 BEFORE the report, pool sees r0: one exactIn of size T in either direction
  leg2 AFTER  the report, pool sees r1: the best single exactIn arbitrage from there
Two measures are printed, each maximised over T separately:
  (L) 'live-marked': leg1 valued at r0, leg2 at r1. Excludes the gain from simply holding
      wstETH across the report.
  (M) 'maker loss': pool value at r1 versus just holding the deposit at r1
      (= leg1 and leg2 both valued at r1). This is what the maker actually loses, and it
      INCLUDES buying the pool's wstETH at r0 just before a known rise.
'plain' = leg2 alone on the untouched pool (a back-run only; (L) and (M) agree there).
Search: 120-point log grid of T per direction (1e12 .. 40e18 wei), then integer ternary
search between the best grid point's neighbours. Every trade is the exact-integer model.
Run: python3 s3d_sandwich.py      (about two minutes)
"""
from fractions import Fraction as F
from functools import lru_cache
from swapvm_math import ONE, Revert
from moving_peg_model import mps_exec, fee_flat_in
from arb import max_arb, best_int
from common import X_ETH, Y_WST, R0, PROVIDER, moving_args, rate_frac, eth

E = 10**18
NEG = F(-10**80)


def make_q(args, x, y, r, fee):
    live = {PROVIDER: r}

    def q(d, amt):
        if d == "eth->wst":
            inner = lambda a: mps_exec(True, True, x, y, a, args, live)
        else:
            inner = lambda a: mps_exec(False, True, y, x, a, args, live)
        return fee_flat_in(fee, True, amt, inner) if fee else inner(amt)
    return q


def study(A, r1, fee=0):
    args = moving_args(A * ONE)
    rt0, rt1 = rate_frac(R0), rate_frac(r1)
    plain = max_arb(make_q(args, X_ETH, Y_WST, r1, fee), rt1, window=64)[0]

    @lru_cache(maxsize=None)
    def legs(d, T):
        try:
            ai, ao = make_q(args, X_ETH, Y_WST, R0, fee)(d, T)
        except Revert:
            return None
        if d == "eth->wst":
            x1, y1 = X_ETH + ai, Y_WST - ao
            l1_r0, l1_r1 = ao * rt0 - ai, ao * rt1 - ai
        else:
            x1, y1 = X_ETH - ao, Y_WST + ai
            l1_r0, l1_r1 = ao - ai * rt0, ao - ai * rt1
        leg2 = max_arb(make_q(args, x1, y1, r1, fee), rt1, window=64)[0]
        return l1_r0 + leg2, l1_r1 + leg2

    out = {}
    for k in (0, 1):  # 0 = live-marked (L), 1 = maker loss (M)
        best = (plain, "none", 0)
        for d in ("eth->wst", "wst->eth"):
            f = lambda t: (lambda v: None if v is None else v[k])(legs(d, t))
            grid = [int(10**12 * (40 * E / 10**12) ** (i / 119)) for i in range(120)]
            vals = [f(T) for T in grid]
            i = max(range(120), key=lambda j: NEG if vals[j] is None else vals[j])
            T, v = best_int(f, grid[max(0, i - 1)], grid[min(119, i + 1)], window=64)
            if v > best[0]:
                best = (v, d, T)
        out[k] = best
    return plain, out[0], out[1]


for r1 in (121 * 10**16, 125 * 10**16):
    hold = X_ETH + Y_WST * rate_frac(r1)
    print(f"=== report r0=1.20 -> r1={r1 / 1e18:.2f}   pool value at r1 = {eth(hold)} ETH")
    print(f"  {'A':>4} {'fee':>5} | {'plain ETH':>15} {'bps':>8} | {'(L) live-marked':>15} {'bps':>8} {'leg1 dir, T':>32} | {'(M) maker loss':>15} {'bps':>9} {'leg1 dir, T':>32}")
    for A, fee in ((0, 0), (20, 0), (50, 0), (100, 0), (300, 0), (50, 5000)):
        pl, (lv, ld, lt), (mv, md, mt) = study(A, r1, fee)
        print(f"  {A:>4} {fee:>5} | {eth(pl):>15} {float(pl / hold) * 1e4:>8.4f} | {eth(lv):>15} {float(lv / hold) * 1e4:>8.4f} {ld + ' ' + str(lt):>32} |"
              f" {eth(mv):>15} {float(mv / hold) * 1e4:>9.4f} {md + ' ' + str(mt):>32}")
    print()
