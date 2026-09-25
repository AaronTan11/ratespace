"""Arbitrage engine used by the economics scripts.

A pool is described by a quote function q(dir, amountIn) -> (amountIn_charged, amountOut)
for exactIn trades, where dir is "eth->wst" (pay the ETH-side token, get wstETH) or
"wst->eth". Profit is valued at the TRUE rate r_true (ETH per wstETH, a Fraction):
    eth->wst : amountOut * r_true - amountIn_charged
    wst->eth : amountOut - amountIn_charged * r_true
max_arb() searches integer trade sizes exactly (every evaluation is the exact-integer
model), then a continuous Decimal solution of the same curve is provided as an
independent cross-check (cont_moving, cont_frozen).
"""
from fractions import Fraction as F
from decimal import Decimal, getcontext
from swapvm_math import Revert

getcontext().prec = 80
E = 10**18


def _profit(q, d, amt, r_true):
    try:
        ai, ao = q(d, amt)
    except Revert:
        return None
    return ao * r_true - ai if d == "eth->wst" else ao - ai * r_true


def best_int(f, lo, hi, window=256):
    """Integer maximiser of a unimodal-with-plateaus f on [lo, hi]; None = revert (-inf).
    Ternary search, then an exact scan of the last window."""
    NEG = F(-10**80)

    def g(a):
        v = f(a)
        return NEG if v is None else v
    while hi - lo > window:
        m1 = lo + (hi - lo) // 3
        m2 = hi - (hi - lo) // 3
        if g(m1) < g(m2):
            lo = m1 + 1
        else:
            hi = m2
    best_a, best_v = lo, g(lo)
    for a in range(lo, hi + 1):
        v = g(a)
        if v > best_v:
            best_a, best_v = a, v
    return best_a, best_v


def max_arb(q, r_true, hi=40 * E, window=256):
    """Best single exactIn arbitrage trade. Returns (profit_wei_Fraction, dir, size)."""
    best = (F(0), "none", 0)
    for d in ("eth->wst", "wst->eth"):
        a, p = best_int(lambda x: _profit(q, d, x, r_true), 1, hi, window)
        if p > best[0]:
            best = (p, d, a)
    return best


# ---------------------------------------------------------------- continuous cross-checks
def _D(x):
    if isinstance(x, F):
        return Decimal(x.numerator) / Decimal(x.denominator)
    return Decimal(x)


def cont_moving(k, A, S):
    """Our design, real numbers. Pool at u=1, v=k (value-balanced anchors S, live rate
    applied). Arb moves along sqrt(u)+sqrt(v)+A(u+v)=C to u=v=m. Profit = S*(1+k-2m)."""
    k, A, S = _D(k), _D(A), _D(S)
    C = 1 + k.sqrt() + A * (1 + k)
    if A == 0:
        m = (C / 2) ** 2
    else:
        w = (-1 + (1 + 2 * A * C).sqrt()) / (2 * A)
        m = w * w
    return S * (1 + k - 2 * m)


def cont_frozen(kappa, A, S):
    """Frozen peg, real numbers. Curve state u=v=1 (C=2+2A) but wstETH is truly worth
    kappa times what the curve assumes. Arb minimises u + kappa*v on the curve.
    FOC: kappa*(1/(2 sqrt u)+A) = 1/(2 sqrt v)+A. Profit = S*((1+kappa) - (u+kappa v))."""
    kappa, A, S = _D(kappa), _D(A), _D(S)
    C = 2 + 2 * A

    def sv_of(su):
        d = kappa * (1 / (2 * su) + A) - A
        return None if d <= 0 else 1 / (2 * d)

    def resid(su):
        sv = sv_of(su)
        if sv is None:
            return None
        return su + sv + A * (su * su + sv * sv) - C
    lo, hi = Decimal("1e-30"), C
    for _ in range(400):
        mid = (lo + hi) / 2
        r = resid(mid)
        if r is not None and r < 0:
            lo = mid
        else:  # past the curve, or past the FOC pole (sv -> infinity): move down
            hi = mid
    su = (lo + hi) / 2
    sv = sv_of(su)
    return S * ((1 + kappa) - (su * su + kappa * sv * sv))
