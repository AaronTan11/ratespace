"""MATH.md section 2: our change (MovingPegSwap.sol, current revision).
  2a value-balanced anchors: the centre u = v sits at x = y * r(t) for every live r(t),
     and the marginal price there is r(t) ETH per wstETH (same order, only the rate moved)
  2b the frozen-price mistake: rescaling BOTH anchors by r(t) cancels r(t) -> price frozen
  2c anchors that are NOT value-balanced put the centre at the wrong price
Run: python3 s2_moving_centre.py
"""
from fractions import Fraction as F
from swapvm_math import ONE
from moving_peg_model import RATE_ONE, anchor_for, mps_build, mps_exec

E = 10**18
R0 = 12 * 10**17
S = anchor_for(6 * E, RATE_ONE)          # 6e18 value units, ETH side
assert S == anchor_for(5 * E, R0)        # wstETH side: 5e18 * 1.2 = 6e18 value units
PROBE = 10**12                           # probe trade size (wei)
LIVE = [114 * 10**16, R0, 1244787728742679575, 125 * 10**16, 126 * 10**16]


def price(args, x, y, r_live, lt_in=True):
    """ETH-side paid per wstETH received (lt_in) or ETH received per wstETH paid (not lt_in)."""
    live = {"P": r_live}
    if lt_in:
        ai, ao = mps_exec(True, True, x, y, PROBE, args, live)
        return F(ai, ao)
    ai, ao = mps_exec(False, True, y, x, PROBE, args, live)
    return F(ao, ai)


print("=== 2a VALUE-BALANCED ANCHORS x0_init = y0_init = S = 6e18 (fixed at ship, rate 1.2e18)")
print("       balances put at the live centre: y = 5e18 wstETH, x = y * r(t) / 1e18 ETH")
print(f"  {'live r(t)':>20} | {'A':>3} | {'u (x*r_in/S)':>14} {'v (y*r/S)':>14} | {'buy price':>14} {'sell price':>14} | r(t)")
for r in LIVE:
    y = 5 * E
    x = y * r // RATE_ONE
    for A in (0, 50, 300):
        args = mps_build(S, S, A * ONE, RATE_ONE, R0, None, "P", 500)
        u = F(x * RATE_ONE // RATE_ONE, S); v = F(y * r // RATE_ONE, S)
        pb = price(args, x, y, r, True); ps = price(args, x, y, r, False)
        print(f"  {r:>20} | {A:>3} | {float(u):>14.10f} {float(v):>14.10f} | {float(pb):>14.10f} {float(ps):>14.10f} | {r / 1e18:.10f}")
print("  -> buy/sell straddle r(t) within the 1e12-wei probe's slippage + rounding, for every r(t),")
print("     with the anchors never changed.")

print("\n=== 2b THE FROZEN-PRICE MISTAKE: rescale BOTH anchors with the live rate every trade")
print("       (x0_init = X*1, y0_init = Y*r(t)): then v = y*r(t)/(Y*r(t)) = y/Y and r(t) cancels.")
print("       Probe at the balances where the rescaled curve is at its centre (x/X = y/Y):")
print(f"  {'live r(t)':>20} | {'our design (fixed S)':>22} | {'rescaled anchors':>18}")
X, Y = 6 * E, 5 * E
for r in LIVE:
    ours = mps_build(S, S, 50 * ONE, RATE_ONE, R0, None, "P", 500)
    resc = mps_build(anchor_for(X, RATE_ONE), anchor_for(Y, r), 50 * ONE, RATE_ONE, R0, None, "P", 500)
    y = 5 * E; x_ours = y * r // RATE_ONE; x_resc = 6 * E
    print(f"  {r:>20} | {float(price(ours, x_ours, y, r)):>22.10f} | {float(price(resc, x_resc, y, r)):>18.10f}")
print("  -> ours follows r(t); the rescaled variant stays at X/Y = 1.2 (frozen).")

print("\n=== 2c NOT value-balanced: anchors = the raw deposits' values but deposit is 6 ETH + 6 wstETH")
print("       (value 6 vs 7.2 at 1.2): the centre u=v is at x/S_x = y*r/S_y, so price = r * S_x/S_y")
Sx, Sy = anchor_for(6 * E, RATE_ONE), anchor_for(6 * E, R0)
args = mps_build(Sx, Sy, 50 * ONE, RATE_ONE, R0, None, "P", 500)
for r in (R0, 125 * 10**16):
    y = 6 * E; x = y * r // RATE_ONE * Sx // Sy
    print(f"  r(t)={r / 1e18:.4f}: centre price {float(price(args, x, y, r)):.10f} vs r*Sx/Sy = {float(F(r, RATE_ONE) * F(Sx, Sy)):.10f}")
