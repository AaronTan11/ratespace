"""MATH.md section 3c: the rate goes DOWN (e.g. a slashing event) r0=1.20 -> r1.
Same pool and method as s3a. 1.14e18 is the band floor (1.2e18 * 9500/10000, inclusive);
one wei lower the order reverts (fail-closed, MovingPegSwap.sol:129).
Run: python3 s3c_rate_drop.py
"""
from fractions import Fraction as F
from swapvm_math import ONE, Revert
from moving_peg_model import mps_exec
from arb import max_arb, cont_moving, cont_frozen
from common import X_ETH, Y_WST, R0, PROVIDER, moving_args, moving_q, frozen_args, frozen_q, rate_frac, eth

print(f"  {'r1':>20} | {'A':>4} | {'ours profit ETH':>18} {'bps':>9} {'dir':<8} | {'frozen profit ETH':>18} {'bps':>9}")
for r1 in (119 * 10**16, 115 * 10**16, 114 * 10**16):
    rt = rate_frac(r1); hold = X_ETH + Y_WST * rt
    for A in (0, 50, 300):
        p, d, _ = max_arb(moving_q(moving_args(A * ONE), X_ETH, Y_WST, r1), rt)
        pf, _, _ = max_arb(frozen_q(frozen_args(A * ONE), X_ETH, Y_WST), rt)
        assert abs(float(p) / 1e18 - float(cont_moving(F(r1, R0), A, 6))) < 1e-12
        assert abs(float(pf) / 1e18 - float(cont_frozen(F(r1, R0), A, 6))) < 1e-12
        print(f"  {r1:>20} | {A:>4} | {eth(p):>18} {float(p / hold) * 1e4:>9.5f} {d:<8} | {eth(pf):>18} {float(pf / hold) * 1e4:>9.5f}")
r_bad = 114 * 10**16 - 1
try:
    mps_exec(True, True, X_ETH, Y_WST, 10**18, moving_args(50 * ONE), {PROVIDER: r_bad})
    print("  r1 = 1.14e18 - 1: NO REVERT (unexpected)")
except Revert as e:
    print(f"  r1 = {r_bad}: reverts ({e})  -> below the 5% band the order stops trading")
print("  (continuous cross-check asserted equal to 1e-12 ETH for every row)")
