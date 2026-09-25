"""Shared fixtures: the demo order (6 ETH-side + 5 wstETH-side at ship rate 1.2e18,
value-balanced anchors 6e18 each, as in test/MovingPegSwap.t.sol:33-38) for our design,
and the same deposit as an upstream PeggedSwap order (the frozen peg)."""
from fractions import Fraction as F
from swapvm_math import ONE
from moving_peg_model import RATE_ONE, anchor_for, mps_build, mps_exec
from pegged_model import pegged_build, pegged_exec

E = 10**18
X_ETH = 6 * E          # ETH-side deposit (lower address, static rate 1e18)
Y_WST = 5 * E          # wstETH-side deposit (greater address, live rate)
R0 = 12 * 10**17       # ship-time rate 1.2e18
BAND = 500             # owner-approved band (bps)
PROVIDER = "wstETH"


def moving_args(a, ref=R0, x=X_ETH, y=Y_WST, band=BAND):
    return mps_build(anchor_for(x, RATE_ONE), anchor_for(y, ref), a, RATE_ONE, ref,
                     None, PROVIDER, band)


def moving_q(args, bal_eth, bal_wst, live_rate):
    """exactIn quote function for arb.py, ETH side = lt, wstETH side = gt."""
    live = {PROVIDER: live_rate}

    def q(d, amt):
        if d == "eth->wst":
            return mps_exec(True, True, bal_eth, bal_wst, amt, args, live)
        return mps_exec(False, True, bal_wst, bal_eth, amt, args, live)
    return q


def frozen_args(a, x=X_ETH, y=Y_WST):
    """Upstream PeggedSwap, anchors = raw deposits, rates 1/1 (the rates cancel anyway, see
    s1_upstream_curve.py), so the peg is frozen at x/y = 1.2 ETH per wstETH."""
    return pegged_build(x, y, a, 1, 1)


def frozen_q(args, bal_eth, bal_wst):
    def q(d, amt):
        if d == "eth->wst":
            return pegged_exec(True, True, bal_eth, bal_wst, amt, args)
        return pegged_exec(False, True, bal_wst, bal_eth, amt, args)
    return q


def rate_frac(rate_raw):
    return F(rate_raw, RATE_ONE)


def eth(w):
    return f"{float(w) / 1e18:.12f}"
