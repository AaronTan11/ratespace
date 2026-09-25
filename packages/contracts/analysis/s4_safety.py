"""MATH.md section 4: safety properties of MovingPegSwap (current revision), measured on the model.
  4a guards (build and exec), band edges
  4b rounding: invariant never decreases; fixed-rate round trips never pay the taker;
     exactOut vs exactIn consistency
  4c drain / capacity: output never exceeds the live balance
  4d dust floors, and the current exactOut floor gate (y0 == 0) vs the legacy gate (c > y0)
  4e overflow: the real balance limit with 1e18-scale rates
  4f the owner-accepted large-anchor edge (> ~1e27 value units per side)
Run: python3 s4_safety.py     (about a minute)
"""
import random
from fractions import Fraction as F
from swapvm_math import ONE, Revert, invariant_from_reserves
from moving_peg_model import RATE_ONE, anchor_for, mps_build, mps_exec

E = 10**18
R0 = 12 * 10**17
RLIVE = 1244787728742679575


def tryrun(f, *a):
    try:
        return f(*a)
    except Revert as e:
        return f"REVERT {e}"


print("=== 4a GUARDS")
S = 6 * E
print("  build(x0=0)            ->", tryrun(mps_build, 0, S, 50 * ONE, RATE_ONE, R0, None, "P", 500))
print("  build(width=5000e27+1) ->", tryrun(mps_build, S, S, 5000 * ONE + 1, RATE_ONE, R0, None, "P", 500))
print("  build(refRateGt=0)     ->", tryrun(mps_build, S, S, 50 * ONE, RATE_ONE, 0, None, "P", 500))
print("  build(band=0)          ->", tryrun(mps_build, S, S, 50 * ONE, RATE_ONE, R0, None, "P", 0))
print("  build(band=1000)       ->", "ok" if isinstance(tryrun(mps_build, S, S, 50 * ONE, RATE_ONE, R0, None, "P", 1000), tuple) else "REVERT")
print("  build(band=1001)       ->", tryrun(mps_build, S, S, 50 * ONE, RATE_ONE, R0, None, "P", 1001))
args = mps_build(S, S, 50 * ONE, RATE_ONE, R0, None, "P", 500)
for label, r in (("live rate 0", 0), ("band floor 1.14e18 (inclusive)", 114 * 10**16),
                 ("band floor - 1 wei", 114 * 10**16 - 1), ("band ceiling 1.26e18 (inclusive)", 126 * 10**16),
                 ("band ceiling + 1 wei", 126 * 10**16 + 1)):
    res = tryrun(mps_exec, True, True, 6 * E, 5 * E, 10**15, args, {"P": r})
    print(f"  exec, {label:<32} -> {res if isinstance(res, str) else 'ok ' + str(res)}")
# exec-time band cap (:159): order bytes that never went through build(), band hand-encoded
for band in (0, 1, 1000, 1001, 65535):
    hand = (S, S, 50 * ONE, RATE_ONE, R0, None, "P", band)
    res = [tryrun(mps_exec, lt, ei, 6 * E, 5 * E, 10**15, hand, {"P": R0}) for lt in (True, False) for ei in (True, False)]
    same = all(r == res[0] for r in res) if isinstance(res[0], str) else all(not isinstance(r, str) for r in res)
    print(f"  exec, hand-encoded band {band:>5} (4 direction/mode combos) -> "
          f"{res[0] if isinstance(res[0], str) else 'ok'}{'' if same else '  MIXED ' + str(res)}")

print("\n=== 4b ROUNDING (random fuzz; one live rate per case, anchors/balances/sizes random)")
print("       dC = invariant(after) - invariant(before), both from the normalized balances exec reads")
from pegged_model import pegged_build, pegged_exec


def fuzz(kind, N=20000, seed=4242):
    random.seed(seed)
    st = dict(n=0, rev=0, negC=0, minC=None, minCrel=None, rt_pos=0, rt_max=None, asym_neg=0, asym_min=None)
    for _ in range(N):
        A = random.choice([0, 20, 50, 300]) * ONE
        rl = random.choice([10**18, R0, RLIVE, 1183746519283746519, 3 * 10**17])
        rate_ok = rl * random.randrange(9600, 10400) // 10000
        Sx = random.randrange(10**15, 10**24); Sy = random.randrange(10**15, 10**24)
        lt = random.random() < 0.5
        exact_in = random.random() < 0.5
        bx = random.randrange(Sx // 3, 2 * Sx)
        by = random.randrange(Sy * RATE_ONE // rl // 3, 2 * Sy * RATE_ONE // rl)
        bi, bo = (bx, by) if lt else (by, bx)
        if kind == "ours":
            args = mps_build(Sx, Sy, A, RATE_ONE, rl, None, "P", 500)
            live = {"P": rate_ok}
            ex = lambda l, e, i, o, a: mps_exec(l, e, i, o, a, args, live)
            ri, ro = (RATE_ONE, rate_ok) if lt else (rate_ok, RATE_ONE)
            norm = lambda b, r: b * r // RATE_ONE
        else:  # upstream PeggedSwap, integer rates 1 / 3 (its own normalization)
            ra, rb = 1, 3
            args = pegged_build(Sx, Sy * rb, A, ra, rb)
            ex = lambda l, e, i, o, a: pegged_exec(l, e, i, o, a, args)
            ri, ro = (ra, rb) if lt else (rb, ra)
            norm = lambda b, r: b * r
        xi, yi = (args[0], args[1]) if lt else (args[1], args[0])
        amt = random.randrange(1, max(2, (bi if exact_in else bo) // 2))
        st["n"] += 1
        try:
            ai, ao = ex(lt, exact_in, bi, bo, amt)
            C0 = invariant_from_reserves(norm(bi, ri), norm(bo, ro), xi, yi, A)
            C1 = invariant_from_reserves(norm(bi + ai, ri), norm(bo - ao, ro), xi, yi, A)
            d = C1 - C0
            if d < 0:
                st["negC"] += 1
                rel = -d / C0
                st["minCrel"] = rel if st["minCrel"] is None else max(st["minCrel"], rel)
            st["minC"] = d if st["minC"] is None else min(st["minC"], d)
            if exact_in and ao > 0 and ao < bo:
                _, back = ex(not lt, True, bo - ao, bi + ai, ao)
                g = back - ai
                st["rt_pos"] += g > 0
                st["rt_max"] = g if st["rt_max"] is None else max(st["rt_max"], g)
                need, _ = ex(lt, False, bi, bo, ao)
                st["asym_neg"] += need < ai
                st["asym_min"] = need - ai if st["asym_min"] is None else min(st["asym_min"], need - ai)
                rel = (need - ai) / ai
                st["asym_rel"] = rel if st.get("asym_rel") is None else min(st["asym_rel"], rel)
        except Revert:
            st["rev"] += 1
    return st


for kind in ("ours", "upstream"):
    s = fuzz(kind)
    print(f"  [{kind:<8}] cases={s['n']} reverted={s['rev']} | dC min={s['minC']}, dC<0 in {s['negC']} cases,"
          f" worst -dC/C = {float(s['minCrel'] or 0):.2e}")
    print(f"  [{kind:<8}] exactIn round trip at the same rate: max taker gain {s['rt_max']} wei, positive in {s['rt_pos']}")
    print(f"  [{kind:<8}] exactOut(out) cost - exactIn amount that gave out: min {s['asym_min']} wei, negative in {s['asym_neg']},"
          f" min relative {s.get('asym_rel', 0):.1e}  (exactIn floors its output; the taker, not the maker, pays it)")

print("\n=== 4c DRAIN / CAPACITY (demo pool 6e18 + 5e18 at 1.2e18, A=50)")
args = mps_build(S, S, 50 * ONE, RATE_ONE, R0, None, "P", 500)
for r in (R0, RLIVE):
    ai, ao = mps_exec(True, True, 6 * E, 5 * E, 10**30, args, {"P": r})
    bi, bo = mps_exec(True, False, 6 * E, 5 * E, 10**30, args, {"P": r})
    print(f"  r={r}: exactIn 1e30 -> in {ai}, out {ao} (= balance 5e18: {ao == 5 * E});"
          f" exactOut 1e30 -> clamped out {bo}, in {bi}")

print("\n=== 4d DUST FLOORS (MovingPegSwap.sol:209-217 drain, :256-264 exactOut)")
dust = mps_build(6 * E, 6 * E, 50 * ONE, RATE_ONE, 3 * 10**17, None, None, 500)
for bo in (1, 2, 3):
    ai, ao = mps_exec(True, True, 7 * E, bo, E, dust, {})
    print(f"  drain, output-side rate 0.3e18, balanceOut {bo} wei: in {ai}, out {ao}")
ai, ao = mps_exec(True, False, 7 * E, 3, 3, dust, {})
print(f"  exactOut 3 of balanceOut 3 wei (rate 0.3e18): in {ai}, out {ao}")
lowin = mps_build(6 * E, 6 * E, 50 * ONE, 5 * 10**16, 999 * 10**15, None, None, 500)
ai, ao = mps_exec(True, False, 6 * E * RATE_ONE // (5 * 10**16), 1, 1, lowin, {})
print(f"  exactOut 1 of balanceOut 1 wei, rateIn 0.05e18, rateOut 0.999e18: in {ai} (value in {ai * 5 * 10**16} >= value out {ao * 999 * 10**15})")
print("  gate comparison: full-reserve exactOut, current (floor iff y0 == 0) vs legacy (floor iff c > y0)")
print("    rIn = 1e18 (Lt, no provider), provider on Gt, A = 50, anchors = anchorFor(deposit, rate)")
print(f"    {'case':<34} {'y0':>22} {'c':>22} {'in current':>22} {'in legacy':>22} {'exactIn drain in':>22} {'value in >= out':>15}")
R4 = 1183746519283746519
gate_cases = [(f"over-valued depGt={d}", 6 * E, d, R4) for d in (6 * E, 6 * E + 1, 6 * E + 7, 6 * E + 123456789, 65 * 10**17)]
gate_cases += [(f"balanced+7 rOut={r}", 6 * E, 6 * E * RATE_ONE // r + 7, r)
               for r in (3 * 10**17, 999 * 10**15, 10**18, R4, R0, 3 * 10**18)]
for label, dl, dg, r in gate_cases:
    a = mps_build(anchor_for(dl, RATE_ONE), anchor_for(dg, r), 50 * ONE, RATE_ONE, r, None, "P", 500)
    new_in, out = mps_exec(True, False, dl, dg, dg, a, {"P": r})
    old_in, _ = mps_exec(True, False, dl, dg, dg, a, {"P": r}, legacy_gate=True)
    ei_in, ei_out = mps_exec(True, True, dl, dg, 1000 * E, a, {"P": r})
    y0 = dg * r // RATE_ONE
    c = -(-dg * r // RATE_ONE)
    assert out == dg and ei_out == dg
    print(f"    {label:<34} {y0:>22} {c:>22} {new_in:>22} {old_in:>22} {ei_in:>22} {str(new_in * RATE_ONE >= out * r):>15}")

print("\n=== 4e OVERFLOW: largest value-balanced pool size (value units per side) that still trades")
print("       pool at the centre, anchors = balances in value units; binary search on the size")


def trades_ok(K, A, r, drain):
    x = K; y = K * RATE_ONE // r
    if y == 0:
        return True, ""
    try:
        a = mps_build(anchor_for(x, RATE_ONE), max(1, anchor_for(y, r)), A, RATE_ONE, r, None, None, 500)
        if drain:  # exactIn of 10x the balance in both directions: the drain branch (:200-220)
            mps_exec(True, True, x, y, 10 * x, a, {})
            mps_exec(False, True, y, x, 10 * y, a, {})
        else:
            mps_exec(True, True, x, y, x // 100 + 1, a, {})
            mps_exec(False, True, y, x, y // 100 + 1, a, {})
            mps_exec(True, False, x, y, y // 100 + 1, a, {})
            mps_exec(False, False, y, x, x // 100 + 1, a, {})
        return True, ""
    except Revert as e:
        return False, str(e)


for drain in (False, True):
    print(f"  probe: {'full drain (exactIn 10x balance), both directions' if drain else '1% exactIn and 1% exactOut, both directions'}")
    for r in (RATE_ONE, RLIVE):
        for A in (0, 50, 300, 5000):
            lo, hi = 10**18, 2**256
            while lo + 1 < hi:
                mid = (lo + hi) // 2
                if trades_ok(mid, A, r, drain)[0]:
                    lo = mid
                else:
                    hi = mid
            why = trades_ok(hi, A, r, drain)[1]
            print(f"    rate {r:>20} A={A:>4}: ok up to {lo:.4e} value units per side (ETH side: {lo / 1e18:.3e} tokens); first failure: {why}")

print(f"  bound from x1*ONE (:192) and x*ONE (PeggedSwapMath.sol:56): value units < (2**256-1)//1e27 = {(2**256 - 1) // ONE:.4e}")
print(f"  bound from x0_raw*rateIn (:175) at rate 1244787728742679575: raw balance < {(2**256 - 1) // RLIVE:.4e} wei")

print("\n=== 4f LARGE ANCHORS (owner-accepted edge): pool at the centre, rate 1.2e18, A=50")
print("       exactOut(k wei of the wstETH side) charges in(k) wei of the ETH side; fair = k*1.2")
print(f"  {'anchor S':>10} | {'largest k charged 1 wei':>24} | {'max (k*1.2 - in) over k scanned, wei':>37} | {'k scanned':>10} | exactIn(1 wei) out")
for S in (10**24, 10**27, 10**28, 12 * 10**29, 10**33):
    a = mps_build(S, S, 50 * ONE, RATE_ONE, R0, None, "P", 500)
    x, y, live = S, S * RATE_ONE // R0, {"P": R0}
    cost = lambda k: mps_exec(True, False, x, y, k, a, live)[0]
    if cost(1) > 1:
        first = 0
    else:  # binary search the end of the 1-wei plateau (cost is non-decreasing in k)
        lo, hi = 1, 2
        while cost(hi) <= 1:
            hi *= 2
        while lo + 1 < hi:
            m = (lo + hi) // 2
            lo, hi = (m, hi) if cost(m) <= 1 else (lo, m)
        first = lo
    K = max(200, 3 * first) if first <= 2000 else first
    ks = range(1, K + 1) if first <= 2000 else [first]
    worst = max(F(k * R0, RATE_ONE) - cost(k) for k in ks)
    print(f"  {S:>10.1e} | {first:>24} | {float(worst):>37.1f} | {K if first <= 2000 else 'k=' + str(first):>10} | {mps_exec(True, True, x, y, 1, a, live)[1]}")
print("  (value in wei of the ETH side; <= 0 means never undercharged over the k scanned)")
print("  off-centre small exactOut quotes that revert, random states (reason = the failing operation):")
for S in (6 * E, 10**27, 12 * 10**29):
    random.seed(7)
    a = mps_build(S, S, 50 * ONE, RATE_ONE, R0, None, "P", 500)
    n = bad = 0
    why = set()
    for _ in range(3000):
        x = random.randrange(S // 10, 2 * S); y = random.randrange(S // 10 * RATE_ONE // R0, 2 * S * RATE_ONE // R0)
        k = random.randrange(1, 10**6)
        try:
            if random.random() < 0.5:
                mps_exec(True, False, x, y, k, a, {"P": R0})
            else:
                mps_exec(False, False, y, x, k, a, {"P": R0})
        except Revert as e:
            bad += 1
            why.add(str(e))
        n += 1
    print(f"    S={S:.1e}: {bad} of {n} revert {sorted(why)}")
