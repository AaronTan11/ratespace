"""Solidity-faithful integer primitives and a line-by-line port of upstream
lib/swap-vm/contracts/libs/PeggedSwapMath.sol (swap-vm pinned at 3b3da7d).

Rules mirrored from Solidity 0.8 (checked arithmetic) and OpenZeppelin Math:
  a * b, a + b  -> exact; any result > 2**256-1 raises Revert("overflow ...")  (Panic 0x11)
  a - b         -> raises Revert("underflow ...") if b > a                    (Panic 0x11)
  a / b         -> floor; b == 0 raises Revert("div by zero")                 (Panic 0x12)
  Math.sqrt(a)  -> floor integer square root
  Math.ceilDiv  -> ceil; b == 0 raises Revert("div by zero")
Only the Python standard library is used.
"""
from math import isqrt

UINT256_MAX = 2**256 - 1
ONE = 10**27                      # PeggedSwapMath.sol:22
MAX_LINEAR_WIDTH = 5000 * ONE     # PeggedSwapMath.sol:24


class Revert(Exception):
    """Any Solidity revert / panic. The message names the failing operation."""


def mul(a, b, what="mul"):
    r = a * b
    if r > UINT256_MAX:
        raise Revert(f"overflow in {what}")
    return r


def add(a, b, what="add"):
    r = a + b
    if r > UINT256_MAX:
        raise Revert(f"overflow in {what}")
    return r


def sub(a, b, what="sub"):
    if b > a:
        raise Revert(f"underflow in {what}")
    return a - b


def div(a, b, what="div"):
    if b == 0:
        raise Revert(f"div by zero in {what}")
    return a // b


def ceil_div(a, b, what="ceilDiv"):
    if b == 0:
        raise Revert(f"div by zero in {what}")
    return 0 if a == 0 else (a - 1) // b + 1


def sqrt(a):
    """OpenZeppelin Math.sqrt(uint256): floor."""
    return isqrt(a)


# ---------------------------------------------------------------- PeggedSwapMath.sol

def invariant(u, v, a):
    """PeggedSwapMath.sol:33-39  sqrt(u*ONE) + sqrt(v*ONE) + a*(u+v)/ONE."""
    sqrtU = sqrt(mul(u, ONE, "u*ONE"))
    sqrtV = sqrt(mul(v, ONE, "v*ONE"))
    linearTerm = div(mul(a, add(u, v, "u+v"), "a*(u+v)"), ONE)
    return add(add(sqrtU, sqrtV), linearTerm)


def invariant_from_reserves(x, y, x0, y0, a):
    """PeggedSwapMath.sol:48-59  u = x*ONE/x0 (floor), v = y*ONE/y0 (floor)."""
    u = div(mul(x, ONE, "x*ONE"), x0, "x*ONE/x0")
    v = div(mul(y, ONE, "y*ONE"), y0, "y*ONE/y0")
    return invariant(u, v, a)


def solve(rightSide, a):
    """PeggedSwapMath.sol:72-112. Returns v with sqrt(v)+a*v = rightSide (scaled)."""
    if a == 0:
        return div(mul(rightSide, rightSide, "R*R"), ONE)          # :75
    fourARightSide = div(mul(mul(4, a, "4*a"), rightSide, "4a*R"), ONE)   # :96
    discriminant = add(ONE, fourARightSide, "ONE+4aR")             # :98
    sqrtDiscriminant = sqrt(mul(discriminant, ONE, "D*ONE"))       # :103 floor
    denominator = add(ONE, sqrtDiscriminant)                       # :105
    w = div(mul(mul(2, rightSide, "2*R"), ONE, "2R*ONE"), denominator)  # :108
    return div(mul(w, w, "w*w"), ONE)                              # :111
