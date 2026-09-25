"""Line-by-line port of upstream lib/swap-vm/contracts/instructions/PeggedSwap.sol
exec() (swap-vm pinned at 3b3da7d). Line numbers in comments refer to that file.

pegged_exec(token_in_is_lt, is_exact_in, bal_in, bal_out, amount, args)
  args = (x0, y0, linearWidth, rateA, rateB)  exactly as encoded in the order (:17)
  returns (amountIn, amountOut) as left in ctx.swap after exec.
"""
from swapvm_math import (ONE, MAX_LINEAR_WIDTH, Revert, mul, add, sub, div, ceil_div,
                         sqrt, invariant_from_reserves, solve)


def pegged_build(x0, y0, linearWidth, rateA, rateB):
    """PeggedSwap.sol:63-71 build-time requires."""
    if not (x0 > 0 and y0 > 0):
        raise Revert("PeggedSwapInvalidInitialBalances")
    if linearWidth > MAX_LINEAR_WIDTH:
        raise Revert("PeggedSwapInvalidLinearWidth")
    if not (rateA > 0 and rateB > 0):
        raise Revert("PeggedSwapInvalidRates")
    return (x0, y0, linearWidth, rateA, rateB)


def pegged_exec(token_in_is_lt, is_exact_in, bal_in, bal_out, amount, args):
    x0a, y0a, linearWidth, rateA, rateB = args
    if token_in_is_lt:                                             # :116
        x0_init, y0_init, rateIn, rateOut = x0a, y0a, rateA, rateB
    else:                                                          # :117
        x0_init, y0_init, rateIn, rateOut = y0a, x0a, rateB, rateA

    x0_raw, y0_raw = bal_in, bal_out                               # :119-120
    x0 = mul(x0_raw, rateIn, "x0_raw*rateIn")                      # :123
    y0 = mul(y0_raw, rateOut, "y0_raw*rateOut")                    # :124
    target = invariant_from_reserves(x0, y0, x0_init, y0_init, linearWidth)  # :127

    if is_exact_in:
        amountIn = amount
        x1 = add(x0, mul(amountIn, rateIn, "amountIn*rateIn"))     # :137
        u1 = div(mul(x1, ONE, "x1*ONE"), x0_init)                  # :141 floor
        invU1 = add(sqrt(mul(u1, ONE, "u1*ONE")), div(mul(linearWidth, u1, "a*u1"), ONE))  # :145
        if invU1 >= target:                                        # :151 drain
            uMax = solve(target, linearWidth)                      # :154
            x1Capped = ceil_div(mul(uMax, x0_init, "uMax*x0_init"), ONE)  # :155
            amountIn = ceil_div(sub(x1Capped, x0, "x1Capped-x0"), rateIn)  # :157
            amountOut = y0_raw                                     # :158
        else:
            rightSide = target - invU1                             # :160
            v1 = solve(rightSide, linearWidth)                     # :161
            y1 = ceil_div(mul(v1, y0_init, "v1*y0_init"), ONE)     # :165 ceil
            amountOut = div(sub(y0, y1, "y0-y1"), rateOut)         # :169 floor
        return amountIn, amountOut
    else:
        amountOut = amount
        if amountOut > y0_raw:                                     # :172
            amountOut = y0_raw
        y1 = sub(y0, mul(amountOut, rateOut, "amountOut*rateOut"), "y0-out*rate")  # :175
        v1 = div(mul(y1, ONE, "y1*ONE"), y0_init)                  # :179 floor
        invV1 = add(sqrt(mul(v1, ONE, "v1*ONE")), div(mul(linearWidth, v1, "a*v1"), ONE))  # :181
        if not (target >= invV1):                                  # :182
            raise Revert("PeggedSwapMathInvalidInput")
        u1 = solve(target - invV1, linearWidth)                    # :183
        x1 = ceil_div(mul(u1, x0_init, "u1*x0_init"), ONE)         # :187 ceil
        amountIn = ceil_div(sub(x1, x0, "x1-x0"), rateIn)          # :191 ceil
        if amountIn == 0 and amountOut != 0:                       # :194
            amountIn = 1
        return amountIn, amountOut
