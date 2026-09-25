"""MATH.md section 3a: arbitrage after one rate step r0 -> r1, our design vs the frozen peg.
Pool: 6 ETH-side + 5 wstETH-side, shipped at r0 = 1.2e18 (value-balanced anchors 6e18).
  ours   = MovingPegSwap, provider now reports r1 (in band: |r1/r0-1| <= 5%)
  frozen = upstream PeggedSwap on the same deposit (peg fixed at 6/5 = 1.2)
Profit = best single exactIn trade, valued at the true rate r1, searched over integer sizes
with the exact-integer model; 'cont.' is the real-number optimum of the same curve (arb.py),
an independent cross-check. bps = profit / pool value at r1 (6 + 5*r1 ETH).
Run: python3 s3a_arb_step.py
"""
from fractions import Fraction as F
from swapvm_math import ONE
from arb import max_arb, cont_moving, cont_frozen
from common import (X_ETH, Y_WST, R0, moving_args, moving_q, frozen_args, frozen_q, rate_frac, eth)

WIDTHS = (0, 20, 50, 100, 300)
STEPS = (121 * 10**16, 125 * 10**16)

for r1 in STEPS:
    rt = rate_frac(r1)
    hold = X_ETH + Y_WST * rt
    print(f"=== step r0=1.20 -> r1={r1 / 1e18:.2f}   pool value at r1 = {eth(hold)} ETH")
    print(f"  {'A':>4} | {'design':<6} | {'dir':<8} | {'size (wei)':>22} | {'profit ETH (model)':>20} | {'bps':>10} | {'cont. ETH':>20}")
    for A in WIDTHS:
        a = A * ONE
        p, d, sz = max_arb(moving_q(moving_args(a), X_ETH, Y_WST, r1), rt)
        c = cont_moving(F(r1, R0), A, 6)
        print(f"  {A:>4} | {'ours':<6} | {d:<8} | {sz:>22} | {eth(p):>20} | {float(p / hold) * 1e4:>10.6f} | {float(c):>20.12f}")
        p, d, sz = max_arb(frozen_q(frozen_args(a), X_ETH, Y_WST), rt)
        c = cont_frozen(F(r1, R0), A, 6)
        print(f"  {A:>4} | {'frozen':<6} | {d:<8} | {sz:>22} | {eth(p):>20} | {float(p / hold) * 1e4:>10.6f} | {float(c):>20.12f}")
    print()
