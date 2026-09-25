"""Generates the expected-value tables for test/ModelParity.t.sol from the Python model.
  python3 gen_parity.py            prints the three Solidity tables (paste into the test)
  python3 gen_parity.py --gates    also prints (stderr) the gate rows: amountIn with the current gate vs the legacy gate
  python3 gen_parity.py --check    re-generates and checks test/ModelParity.t.sol contains
                                   exactly these rows (exit 1 on any difference)
Row layout, MovingPegSwap (uint256[16]):
  [0] tokenIn is Lt  [1] exactIn  [2] balanceIn  [3] balanceOut  [4] amount
  [5] x0 (Lt anchor) [6] y0 (Gt anchor) [7] linearWidth [8] refRateLt [9] refRateGt
  [10] provider side (0 none, 1 Lt, 2 Gt) [11] live provider rate [12] maxDeviationBps
  [13] expect revert [14] expected amountIn [15] expected amountOut
Row layout, MovingPegSwap hand-encoded band (uint256[16]); order bytes are build(..., band 1000) with the
  trailing uint16 band patched, so exec sees a band build() would reject:
  [0]-[12] as the MovingPegSwap layout ([12] = the patched band)
  [13] expect revert  [14] amountIn, or for a revert the expected MovingPegSwapInvalidMaxDeviation argument
  [15] amountOut (0 for a revert)
Row layout, upstream PeggedSwap (uint256[13]):
  [0] tokenIn is Lt [1] exactIn [2] balanceIn [3] balanceOut [4] amount
  [5] x0 [6] y0 [7] linearWidth [8] rateA [9] rateB [10] expect revert [11] amountIn [12] amountOut
"""
import os
import random
import sys
from swapvm_math import ONE, Revert
from moving_peg_model import RATE_ONE, anchor_for, mps_build, mps_exec
from pegged_model import pegged_build, pegged_exec

E = 10**18
RATES = [10**18, 12 * 10**17, 1244787728742679575, 1183746519283746519, 3 * 10**17]
WIDTHS = [0, 50 * ONE, 300 * ONE]
AMT_IN = 123400000000000000     # 0.1234e18
AMT_OUT = 98700000000000000     # 0.0987e18

mps_rows = []   # (comment, row)


def mps_case(comment, lt_in, exact_in, bal_lt, bal_gt, amount, x0, y0, width, ref_lt, ref_gt, prov, live, band=500):
    args = mps_build(x0, y0, width, ref_lt, ref_gt,
                     "P" if prov == 1 else None, "P" if prov == 2 else None, band)
    bi, bo = (bal_lt, bal_gt) if lt_in else (bal_gt, bal_lt)
    try:
        ai, ao = mps_exec(lt_in, exact_in, bi, bo, amount, args, {"P": live})
        rev = 0
    except Revert:
        ai, ao, rev = 0, 0, 1
    mps_rows.append((comment, [int(lt_in), int(exact_in), bi, bo, amount, x0, y0, width, ref_lt, ref_gt,
                               prov, live if prov else 0, band, rev, ai, ao]))


def four(comment, bal_lt, bal_gt, x0, y0, width, ref_lt, ref_gt, prov, live, band=500, a_in=AMT_IN, a_out=AMT_OUT):
    for lt_in in (True, False):
        for exact_in in (True, False):
            mps_case(f"{comment} {'Lt->Gt' if lt_in else 'Gt->Lt'} {'exactIn' if exact_in else 'exactOut'}",
                     lt_in, exact_in, bal_lt, bal_gt, a_in if exact_in else a_out, x0, y0, width, ref_lt, ref_gt,
                     prov, live, band)


# A: value-balanced demo-size pools (6e18 value per side), ETH side = Lt (static 1e18), provider on Gt
for r in RATES:
    dep_gt = 6 * E * RATE_ONE // r
    for w in WIDTHS:
        four(f"A r={r} w={w // ONE}e27", 6 * E, dep_gt, anchor_for(6 * E, RATE_ONE), anchor_for(dep_gt, r),
             w, RATE_ONE, r, 2, r)
# B: live rate differs from the reference (ref 1.2e18), off-centre pool
four("B live=1244787728742679575 ref=1.2e18", 6 * E, 5 * E, 6 * E, 6 * E, 50 * ONE, RATE_ONE, 12 * 10**17, 2, 1244787728742679575)
mps_case("B band floor 1.14e18 inclusive", True, True, 6 * E, 5 * E, AMT_IN, 6 * E, 6 * E, 50 * ONE, RATE_ONE, 12 * 10**17, 2, 114 * 10**16)
mps_case("B band floor - 1 wei reverts", True, True, 6 * E, 5 * E, AMT_IN, 6 * E, 6 * E, 50 * ONE, RATE_ONE, 12 * 10**17, 2, 114 * 10**16 - 1)
mps_case("B band ceiling + 1 wei reverts", False, False, 6 * E, 5 * E, AMT_OUT, 6 * E, 6 * E, 50 * ONE, RATE_ONE, 12 * 10**17, 2, 126 * 10**16 + 1)
mps_case("B live rate 0 reverts", True, True, 6 * E, 5 * E, AMT_IN, 6 * E, 6 * E, 50 * ONE, RATE_ONE, 12 * 10**17, 2, 0)
mps_case("B band 1000 bps, live +9.99%", True, True, 6 * E, 5 * E, AMT_IN, 6 * E, 6 * E, 50 * ONE, RATE_ONE, 12 * 10**17, 2, 12 * 10**17 * 10999 // 10000, 1000)
# C: provider on the Lt side (wstETH-like is the lower address)
dep = 6 * E * RATE_ONE // 1183746519283746519
four("C provider on Lt ref=1183746519283746519 live=1.2e18", dep, 6 * E, anchor_for(dep, 1183746519283746519),
     anchor_for(6 * E, RATE_ONE), 300 * ONE, 1183746519283746519, RATE_ONE, 1, 12 * 10**17)
# D: large balances (1e30 and 1e45 value units per side)
for V in (10**30, 10**45):
    r = 1244787728742679575
    dg = V * RATE_ONE // r
    four(f"D large V={V:.0e}", V, dg, anchor_for(V, RATE_ONE), anchor_for(dg, r), 50 * ONE, RATE_ONE, r, 2, r,
         a_in=V // 1000 + 7, a_out=dg // 1000 + 7)
S = 12 * 10**29
mps_case("D large-anchor edge: exactOut 1000 wei at S=1.2e30", True, False, S, S * RATE_ONE // (12 * 10**17), 1000,
         S, S, 50 * ONE, RATE_ONE, 12 * 10**17, 2, 12 * 10**17)
# E: drain / clamp on the demo pool, live rate 1244787728742679575
for lt_in in (True, False):
    mps_case(f"E drain exactIn 1e30 {'Lt->Gt' if lt_in else 'Gt->Lt'}", lt_in, True, 6 * E, 5 * E, 10**30,
             6 * E, 6 * E, 50 * ONE, RATE_ONE, 12 * 10**17, 2, 1244787728742679575)
    mps_case(f"E exactOut above balance clamps {'Lt->Gt' if lt_in else 'Gt->Lt'}", lt_in, False, 6 * E, 5 * E, 10**30,
             6 * E, 6 * E, 50 * ONE, RATE_ONE, 12 * 10**17, 2, 1244787728742679575)
# F: dust floors (static rates, no provider), as in test_M_DrainDust_MinAmountIn / test_M_DustValueFloor
for bo in (1, 2, 3):
    mps_case(f"F dust drain balanceOut={bo}", True, True, 7 * E, bo, E, 6 * E, 6 * E, 50 * ONE, RATE_ONE, 3 * 10**17, 0, 0)
mps_case("F dust exactOut 3 of 3", True, False, 7 * E, 3, 3, 6 * E, 6 * E, 50 * ONE, RATE_ONE, 3 * 10**17, 0, 0)
mps_case("F value floor rateIn 0.05e18 rateOut 0.999e18", True, False, 6 * E * RATE_ONE // (5 * 10**16), 1, 1,
         6 * E, 6 * E, 50 * ONE, 5 * 10**16, 999 * 10**15, 0, 0)
mps_case("F non-saturated 1e30 anchor, output rate 0.3e18", True, True, 7 * E, 40, E, 6 * E, 10**30, 50 * ONE, RATE_ONE, 3 * 10**17, 0, 0)
# G: an off-centre exactOut that panics (x1 < x0 underflow, MovingPegSwap.sol:253) at S=1.2e30
random.seed(7)
found = None
while found is None:
    x = random.randrange(S // 10, 2 * S); y = random.randrange(S // 10 * RATE_ONE // (12 * 10**17), 2 * S * RATE_ONE // (12 * 10**17))
    k = random.randrange(1, 10**6)
    a = mps_build(S, S, 50 * ONE, RATE_ONE, 12 * 10**17, None, "P", 500)
    try:
        mps_exec(True, False, x, y, k, a, {"P": 12 * 10**17})
    except Revert:
        found = (x, y, k)
mps_case("G off-centre exactOut underflow panic at S=1.2e30", True, False, found[0], found[1], found[2], S, S, 50 * ONE,
         RATE_ONE, 12 * 10**17, 2, 12 * 10**17)

# H: exactOut value-floor gate (:262 `y0 == 0`; the legacy gate was `c > y0`).
#    ETH side = Lt (1e18, no provider), provider on Gt, anchors = anchorFor(deposit, rate), as
#    test_M_FullDrainOverValued_EqualInput / test_M_FullReserveExactOut_BalancedValue. Full-reserve
#    exactOut (amount = the whole Gt reserve) and, for the over-valued pools, the exactIn drain.
R4 = 1183746519283746519
R0 = 12 * 10**17
gate_rows = []   # (label, new amountIn, legacy amountIn) for the report


def gate_case(comment, dl, dg, r, exact_in):
    x0, y0 = anchor_for(dl, RATE_ONE), anchor_for(dg, r)
    amt = 1000 * E if exact_in else dg
    if not exact_in:
        a = mps_build(x0, y0, 50 * ONE, RATE_ONE, r, None, "P", 500)
        old_in, _ = mps_exec(True, False, dl, dg, amt, a, {"P": r}, legacy_gate=True)
        new_in, _ = mps_exec(True, False, dl, dg, amt, a, {"P": r})
        gate_rows.append((comment, new_in, old_in))
        comment += f" (legacy gate c > y0 would charge {old_in})"
    mps_case(comment, True, exact_in, dl, dg, amt, x0, y0, 50 * ONE, RATE_ONE, r, 2, r)


for dg in (6 * E, 6 * E + 1, 6 * E + 7, 6 * E + 123456789, 65 * 10**17):
    gate_case(f"H over-valued depLt=6e18 depGt={dg} r={R4} full-reserve exactOut", 6 * E, dg, R4, False)
    gate_case(f"H over-valued depLt=6e18 depGt={dg} r={R4} exactIn drain 1000e18", 6 * E, dg, R4, True)
for r in (3 * 10**17, 999 * 10**15, 10**18, R4, R0, 3 * 10**18):
    dg = 6 * E * RATE_ONE // r + 7
    gate_case(f"H balanced+7 depGt={dg} rOut={r} full-reserve exactOut", 6 * E, dg, r, False)

# I: exec-time band cap (:159) on hand-encoded order bytes (build() would reject the band)
raw_rows = []   # (comment, row)


def raw_case(comment, lt_in, exact_in, band):
    bal_lt, bal_gt, amount = 6 * E, 5 * E, AMT_IN if exact_in else AMT_OUT
    x0, y0, width, ref_lt, ref_gt, live = 6 * E, 6 * E, 50 * ONE, RATE_ONE, R0, R0
    args = (x0, y0, width, ref_lt, ref_gt, None, "P", band)     # parse() output; no build() check
    bi, bo = (bal_lt, bal_gt) if lt_in else (bal_gt, bal_lt)
    try:
        ai, ao = mps_exec(lt_in, exact_in, bi, bo, amount, args, {"P": live})
        rev = 0
    except Revert as e:
        if str(e) != f"MovingPegSwapInvalidMaxDeviation({band})":
            raise SystemExit(f"unexpected model revert for band {band}: {e}")
        ai, ao, rev = band, 0, 1
    raw_rows.append((comment, [int(lt_in), int(exact_in), bi, bo, amount, x0, y0, width, ref_lt, ref_gt,
                               2, live, band, rev, ai, ao]))


for band in (0, 1001, 65535, 1000, 1):
    for lt_in in (True, False):
        for exact_in in (True, False):
            if band == 1 and not exact_in:
                continue
            raw_case(f"I hand-encoded band {band} {'Lt->Gt' if lt_in else 'Gt->Lt'} {'exactIn' if exact_in else 'exactOut'}"
                     + (" (control: legal band)" if band in (1, 1000) else ""), lt_in, exact_in, band)

# ---------------------------------------------------------------- upstream PeggedSwap rows
ps_rows = []


def ps_case(comment, lt_in, exact_in, bal_lt, bal_gt, amount, x0, y0, width, ra, rb):
    args = pegged_build(x0, y0, width, ra, rb)
    bi, bo = (bal_lt, bal_gt) if lt_in else (bal_gt, bal_lt)
    try:
        ai, ao = pegged_exec(lt_in, exact_in, bi, bo, amount, args)
        rev = 0
    except Revert:
        ai, ao, rev = 0, 0, 1
    ps_rows.append((comment, [int(lt_in), int(exact_in), bi, bo, amount, x0, y0, width, ra, rb, rev, ai, ao]))


for w in WIDTHS:
    for lt_in in (True, False):
        for exact_in in (True, False):
            ps_case(f"P demo 6e18/5e18 w={w // ONE}e27 {'Lt->Gt' if lt_in else 'Gt->Lt'} {'exactIn' if exact_in else 'exactOut'}",
                    lt_in, exact_in, 6 * E, 5 * E, AMT_IN if exact_in else AMT_OUT, 6 * E, 5 * E, w, 1, 1)
ps_case("P drain exactIn 1e30", True, True, 6 * E, 5 * E, 10**30, 6 * E, 5 * E, 50 * ONE, 1, 1)
ps_case("P exactOut above balance clamps", False, False, 6 * E, 5 * E, 10**30, 6 * E, 5 * E, 50 * ONE, 1, 1)
ps_case("P rates 1e18/1.25e18, anchors balance*rate (rates cancel)", True, True, 6 * E, 5 * E, AMT_IN,
        6 * E * 10**18, 5 * E * 125 * 10**16, 50 * ONE, 10**18, 125 * 10**16)
ps_case("P rates 1/1 same deposit (compare with the row above)", True, True, 6 * E, 5 * E, AMT_IN, 6 * E, 5 * E, 50 * ONE, 1, 1)


def render():
    out = ["        // BEGIN GENERATED MovingPegSwap TABLE (analysis/gen_parity.py)"]
    for c, r in mps_rows:
        out.append(f"        // {c}")
        out.append("        _mps([uint256(" + str(r[0]) + "), " + ", ".join(str(v) for v in r[1:]) + "]);")
    out.append("        // END GENERATED MovingPegSwap TABLE")
    out3 = ["        // BEGIN GENERATED MovingPegSwap BAND TABLE (analysis/gen_parity.py)"]
    for c, r in raw_rows:
        out3.append(f"        // {c}")
        out3.append("        _mpsBand([uint256(" + str(r[0]) + "), " + ", ".join(str(v) for v in r[1:]) + "]);")
    out3.append("        // END GENERATED MovingPegSwap BAND TABLE")
    out2 = ["        // BEGIN GENERATED PeggedSwap TABLE (analysis/gen_parity.py)"]
    for c, r in ps_rows:
        out2.append(f"        // {c}")
        out2.append("        _ps([uint256(" + str(r[0]) + "), " + ", ".join(str(v) for v in r[1:]) + "]);")
    out2.append("        // END GENERATED PeggedSwap TABLE")
    return "\n".join(out), "\n".join(out2), "\n".join(out3)


if __name__ == "__main__":
    t1, t2, t3 = render()
    n_rev = sum(r[13] for _, r in mps_rows)
    n_raw_rev = sum(r[13] for _, r in raw_rows)
    counts = (f"MovingPegSwap rows: {len(mps_rows)} ({n_rev} expect revert); band rows: {len(raw_rows)}"
              f" ({n_raw_rev} expect MovingPegSwapInvalidMaxDeviation); PeggedSwap rows: {len(ps_rows)}")
    if "--check" in sys.argv:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "test", "ModelParity.t.sol")
        src = open(path).read()
        ok = t1 in src and t2 in src and t3 in src
        print(counts)
        print("test/ModelParity.t.sol tables match the model:", ok)
        sys.exit(0 if ok else 1)
    print(t1)
    print()
    print(t3)
    print()
    print(t2)
    print("// " + counts, file=sys.stderr)
    if "--gates" in sys.argv:
        for c, new_in, old_in in gate_rows:
            print(f"// {c}: amountIn current {new_in} | legacy {old_in} | {'differs' if new_in != old_in else 'same'}",
                  file=sys.stderr)
