"""Line-by-line port of src/instructions/MovingPegSwap.sol exec() (current revision),
plus upstream FeeFlatIn (lib/swap-vm/contracts/instructions/FeeFlat.sol:49-66) and a
minimal Aqua balance book for multi-trade scenarios. Line numbers = MovingPegSwap.sol.

Public API
  mps_build(x0, y0, linearWidth, refRateLt, refRateGt, providerLt, providerGt, band)
      -> args tuple (build-time requires :85-88 enforced)
  anchor_for(balance, rate)                          :120-122
  mps_exec(token_in_is_lt, is_exact_in, bal_in, bal_out, amount, args, live, legacy_gate=False)
      live = {provider_name: rate}; provider None means "address(0)" (use refRate)
      -> (amountIn, amountOut)
      legacy_gate=True reproduces two earlier lines, for comparison only:
      no exec-time band-cap check and the exactOut value floor gated on
      `c > y0` instead of `y0 == 0` (:262).
  fee_flat_in(feeBps, is_exact_in, amount, inner) -> (amountIn, amountOut)
"""
from swapvm_math import (ONE, MAX_LINEAR_WIDTH, Revert, mul, add, sub, div, ceil_div,
                         sqrt, invariant_from_reserves, solve)

RATE_ONE = 10**18                 # :25
BPS = 10000                       # :26
MAX_DEVIATION_BPS_CAP = 1000      # :28


def anchor_for(balance, rate):
    """:120-122  balance * rate / RATE_ONE (floor)."""
    return div(mul(balance, rate, "balance*rate"), RATE_ONE)


def mps_build(x0, y0, linearWidth, refRateLt, refRateGt, providerLt, providerGt, band):
    """:85-88 build-time requires."""
    if not (x0 > 0 and y0 > 0):
        raise Revert("MovingPegSwapInvalidInitialBalances")
    if linearWidth > MAX_LINEAR_WIDTH:
        raise Revert("MovingPegSwapInvalidLinearWidth")
    if not (refRateLt > 0 and refRateGt > 0):
        raise Revert("MovingPegSwapInvalidRefRates")
    if not (band > 0 and band <= MAX_DEVIATION_BPS_CAP):
        raise Revert("MovingPegSwapInvalidMaxDeviation")
    if not (0 <= band < 2**16):
        raise Revert("uint16")
    return (x0, y0, linearWidth, refRateLt, refRateGt, providerLt, providerGt, band)


def resolve_rate(provider, refRate, band, live):
    """:126-132 fail-closed live-rate resolution."""
    rate = refRate if provider is None else live[provider]                  # :127
    if rate == 0:                                                           # :128
        raise Revert("MovingPegSwapZeroRate")
    if (mul(rate, BPS, "rate*BPS") < mul(refRate, sub(BPS, band, "BPS-dev"), "ref*(BPS-dev)")
            or mul(rate, BPS, "rate*BPS") > mul(refRate, add(BPS, band, "BPS+dev"), "ref*(BPS+dev)")):  # :129
        raise Revert("MovingPegSwapRateOutOfBand")
    return rate


def mps_exec(token_in_is_lt, is_exact_in, bal_in, bal_out, amount, args, live=None, legacy_gate=False):
    live = live or {}
    x0_init, y0_init, linearWidth, refLt, refGt, pLt, pGt, band = args     # :157
    if not legacy_gate:                                                  # :159 exec-time band cap
        if not (band > 0 and band <= MAX_DEVIATION_BPS_CAP):
            raise Revert(f"MovingPegSwapInvalidMaxDeviation({band})")
    if token_in_is_lt:                                                      # :161
        rateIn = resolve_rate(pLt, refLt, band, live)                       # :162
        rateOut = resolve_rate(pGt, refGt, band, live)                      # :163
    else:
        x0_init, y0_init = y0_init, x0_init                                 # :165
        rateIn = resolve_rate(pGt, refGt, band, live)                       # :166
        rateOut = resolve_rate(pLt, refLt, band, live)                      # :167

    x0_raw, y0_raw = bal_in, bal_out                                        # :171-172
    x0 = div(mul(x0_raw, rateIn, "x0_raw*rateIn"), RATE_ONE)                # :175 floor
    y0 = div(mul(y0_raw, rateOut, "y0_raw*rateOut"), RATE_ONE)              # :176 floor
    target = invariant_from_reserves(x0, y0, x0_init, y0_init, linearWidth) # :179

    if is_exact_in:
        amountIn = amount
        x1 = add(x0, div(mul(amountIn, rateIn, "amountIn*rateIn"), RATE_ONE), "x0+in")  # :189
        u1 = div(mul(x1, ONE, "x1*ONE"), x0_init)                           # :192 floor
        invU1 = add(sqrt(mul(u1, ONE, "u1*ONE")), div(mul(linearWidth, u1, "a*u1"), ONE))  # :195
        if invU1 >= target:                                                 # :200 drain
            uMax = solve(target, linearWidth)                               # :203
            x1Capped = ceil_div(mul(uMax, x0_init, "uMax*x0_init"), ONE)    # :204 ceil
            drainIn = ceil_div(mul(sub(x1Capped, x0, "x1Capped-x0"), RATE_ONE, "(..)*RATE_ONE"), rateIn)  # :206 ceil
            if drainIn == 0 and y0_raw != 0:                                # :209
                drainIn = 1
            if y0 == 0:                                                     # :215 dust value floor
                drainIn = max(drainIn, ceil_div(mul(y0_raw, rateOut, "y0_raw*rateOut"), rateIn))  # :216
            return drainIn, y0_raw                                          # :219-220
        rightSide = target - invU1                                          # :222
        v1 = solve(rightSide, linearWidth)                                  # :223
        y1 = ceil_div(mul(v1, y0_init, "v1*y0_init"), ONE)                  # :226 ceil
        amountOut = div(mul(sub(y0, y1, "y0-y1"), RATE_ONE, "(y0-y1)*RATE_ONE"), rateOut)  # :230 floor
        return amountIn, amountOut
    else:
        amountOut = amount
        if amountOut > y0_raw:                                              # :233
            amountOut = y0_raw
        c = ceil_div(mul(amountOut, rateOut, "out*rateOut"), RATE_ONE)      # :238 ceil
        y1 = y0 - c if y0 > c else 0                                        # :239 saturate
        v1 = div(mul(y1, ONE, "y1*ONE"), y0_init)                           # :242 floor
        invV1 = add(sqrt(mul(v1, ONE, "v1*ONE")), div(mul(linearWidth, v1, "a*v1"), ONE))  # :244
        if not (target >= invV1):                                           # :245
            raise Revert("PeggedSwapMathInvalidInput")
        u1 = solve(target - invV1, linearWidth)                             # :246
        x1 = ceil_div(mul(u1, x0_init, "u1*x0_init"), ONE)                  # :249 ceil
        amountIn = ceil_div(mul(sub(x1, x0, "x1-x0"), RATE_ONE, "(x1-x0)*RATE_ONE"), rateIn)  # :253 ceil
        if amountIn == 0 and amountOut != 0:                                # :256
            amountIn = 1
        floor_gate = (c > y0) if legacy_gate else (y0 == 0)             # :262 (legacy gate was c > y0)
        if floor_gate:                                                      # :262 dust value floor
            amountIn = max(amountIn, ceil_div(mul(amountOut, rateOut, "out*rateOut"), rateIn))  # :263
        return amountIn, amountOut


# ---------------------------------------------------------------- FeeFlatIn (upstream)
FEE_BPS_SCALE = 10**7             # FeeFlat.sol:27


def fee_flat_in(feeBps, is_exact_in, amount, inner):
    """FeeFlat.sol:49-66. `inner(amountIn_or_amountOut) -> (amountIn, amountOut)` runs the rest
    of the program (ctx.runLoop()). Returns the final (amountIn, amountOut)."""
    if is_exact_in:
        amountIn = amount
        fee = ceil_div(mul(amountIn, feeBps), FEE_BPS_SCALE)               # :53
        amountIn = sub(amountIn, fee)                                       # :54
        reduction = amountIn                                                # :56
        amountIn, amountOut = inner(amountIn)                               # :57
        reduction = sub(reduction, amountIn)                                # :58
        if reduction == 0:                                                  # :60
            amountIn = add(amountIn, fee)
        else:                                                               # :61
            amountIn = add(amountIn, ceil_div(mul(amountIn, feeBps), FEE_BPS_SCALE - feeBps))
        return amountIn, amountOut
    amountIn, amountOut = inner(amount)                                     # :63
    amountIn = add(amountIn, ceil_div(mul(amountIn, feeBps), FEE_BPS_SCALE - feeBps))  # :64
    return amountIn, amountOut


# ---------------------------------------------------------------- order + Aqua book
class Order:
    """One shipped MovingPegSwap order with Aqua-style balances (balances are the order's
    reserves; a swap adds amountIn to the in-side and removes amountOut from the out-side,
    as SwapVM.sol:163/217 read them via AQUA.safeBalances). Tokens: 'lt' and 'gt'."""

    def __init__(self, args, bal_lt, bal_gt, fee_bps=0):
        self.args = args
        self.bal = {"lt": bal_lt, "gt": bal_gt}
        self.fee_bps = fee_bps

    def quote(self, token_in, is_exact_in, amount, live):
        lt_in = token_in == "lt"
        bi = self.bal["lt" if lt_in else "gt"]
        bo = self.bal["gt" if lt_in else "lt"]

        def inner(a):
            return mps_exec(lt_in, is_exact_in, bi, bo, a, self.args, live)
        if self.fee_bps:
            return fee_flat_in(self.fee_bps, is_exact_in, amount, inner)
        return inner(amount)

    def swap(self, token_in, is_exact_in, amount, live):
        ai, ao = self.quote(token_in, is_exact_in, amount, live)
        tout = "gt" if token_in == "lt" else "lt"
        self.bal[token_in] += ai
        self.bal[tout] = sub(self.bal[tout], ao, "balance-out")
        return ai, ao
