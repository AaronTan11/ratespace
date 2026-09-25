"""MATH.md section 3b: path dependence. The rate moves 1.20 -> 1.25 in N equal integer
steps; after EVERY step an arbitrageur makes the best single exactIn trade (valued at that
step's rate) and the trade is applied to the pool balances. Total = sum of the arb profits.
Our design only (the frozen peg never re-centres).
Run: python3 s3b_path.py
"""
from fractions import Fraction as F
from swapvm_math import ONE
from moving_peg_model import mps_exec
from arb import max_arb
from common import X_ETH, Y_WST, R0, PROVIDER, moving_args, moving_q, rate_frac, eth

R1 = 125 * 10**16
print("=== path 1.20 -> 1.25, arb after each step (ours)")
print(f"  {'A':>4} | {'N steps':>7} | {'total arb profit ETH':>22} | {'bps of value@1.25':>18} | {'final ETH-side':>22} {'final wst-side':>22}")
for A in (0, 50, 300):
    args = moving_args(A * ONE)
    for N in (1, 10, 100):
        x, y, total = X_ETH, Y_WST, F(0)
        for i in range(1, N + 1):
            r = R0 + (R1 - R0) * i // N
            p, d, sz = max_arb(moving_q(args, x, y, r), rate_frac(r))
            if sz:
                live = {PROVIDER: r}
                if d == "eth->wst":
                    ai, ao = mps_exec(True, True, x, y, sz, args, live); x += ai; y -= ao
                else:
                    ai, ao = mps_exec(False, True, y, x, sz, args, live); y += ai; x -= ao
                total += p
        hold = X_ETH + Y_WST * rate_frac(R1)
        print(f"  {A:>4} | {N:>7} | {eth(total):>22} | {float(total / hold) * 1e4:>18.6f} | {x:>22} {y:>22}")
print("  -> N small steps leak ~1/N of one jump's arb (the loss is ~quadratic in step size).")
