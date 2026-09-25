"""Every exchange-rate change of rETH, cbETH and weETH on Ethereum mainnet over the last 365 days.

Rate functions (1e18-scaled, read with eth_call):
  rETH  0xae78736Cd615f374D3085123A210448E74Fc6393  getExchangeRate()  selector 0xe6aa216c
  cbETH 0xBe9895146f7AF43049ca1c1AE358B0541Ea49704  exchangeRate()     selector 0x3ba0b9a9
  weETH 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee  getRate()          selector 0x679aefce

Method (--fetch), per token:
  1. range: first block whose timestamp >= head timestamp - 365 days, up to the head seen at the
     first --fetch run (both kept in the cache so a resumed run scans the same range).
  2. read the rate every GRID blocks; wherever two neighbouring samples differ, bisect down to
     single blocks (recursively, so several changes inside one grid step are all found).
     A change is block b with rate(b-1) != rate(b); preRate = rate(b-1), postRate = rate(b).
  3. read every update event in the range (below). An event block that step 2 did not list is
     checked with rate(b-1) vs rate(b) and added if it differs (catches a change that step 2
     cannot see because the rate returned to the same value inside one grid step).
  4. per change: block timestamp, and the tx hash + event-implied rate of any update event in
     that block.
  Update events (topic0 checked with `cast sig-event` / `cast 4byte-event`):
    rETH  BalancesUpdated(uint256 indexed block, uint256 slotTimestamp, uint256 totalEth,
          uint256 stakingEth, uint256 rethSupply, uint256 blockTimestamp) on RocketNetworkBalances
          (RocketStorage getAddress(keccak256("contract.addressrocketNetworkBalances")):
          0x6Cc65bF618F55ce2433f9D8d827Fc44117D81399 at block 24474719, its last event;
          0x1D9F14C6Bfd8358b589964baD8665AdD248E9473 at block 24481884, its first event). Implied rate
          totalEth * 1e18 // rethSupply.
    cbETH ExchangeRateUpdated(address indexed oracle, uint256 newExchangeRate) on cbETH itself.
          Implied rate newExchangeRate.
    weETH Rebase(uint256 totalEthLocked, uint256 totalEEthShares) on the ether.fi LiquidityPool
          0x308861A430be4cce5502d0A12724771Fc6DaF216. Implied rate
          totalEthLocked * 1e18 // totalEEthShares.
  move_bps = (postRate - preRate) / preRate * 1e4   (exact Fraction; CSV keeps 6 dp)
  A change is per block: preRate is the rate before the block, postRate after all its txs. If
  another rate-moving tx follows the update event in the same block, event_rate != postRate;
  the summary lists every such block with both rates (weETH has one, block 25632424: the
  Rebase tx at index 391, then a redeemWeEth tx at index 432 that burns eETH shares).
  weETH's rate also moves outside Rebase blocks (ordinary pool / redemption transactions);
  the summary reports the Rebase-block subset and the rest separately.

Threshold: the smallest upward step at which the 0.05% fee no longer blocks the buy-before /
sell-after round trip, re-derived by s3e_fee_roundtrip.py Part 3 for the demo order (A=50,
band 500, r0 = 1.2e18): r0 + 1206113946104793 wei. It is specific to that order.

Run from packages/contracts/analysis:
  python3 s6_lst_rates.py --offline               # summaries from data/lst_rates_<token>.csv
  python3 s6_lst_rates.py --fetch [TOKEN ...]     # (re)collect; resumable, see below
  python3 s6_lst_rates.py --offline --crosscheck  # eth_call at block-1 / block for sampled changes
  python3 s6_lst_rates.py --rewrite               # rewrite the CSVs from a complete cache (no network)
--fetch works in pieces of about FETCH_BUDGET_S seconds and keeps its progress in a cache
directory (S6_CACHE, default: <system temp dir>/s6_lst_cache). Re-run it until it prints
"COMPLETE" for every token; the CSV is written only then. Delete the cache to start over.
--fetch and --crosscheck read the RPC endpoint from the MAINNET_RPC_URL environment variable
(e.g. `set -a; . ../.env; set +a`). The URL is never printed or written.
"""
import csv
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
from fractions import Fraction as F

E18 = 10**18
DAYS = 365
FETCH_BUDGET_S = 150
CHUNK = 20_000                                  # blocks per resumable scan piece
S3E_R0 = 12 * 10**17                            # common.py R0
S3E_STEP_WEI = 1206113946104793                 # s3e Part 3, fee=5000: first positive step
THRESHOLD_BPS = F(S3E_STEP_WEI, S3E_R0) * 10**4
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.environ.get("S6_CACHE", os.path.join(tempfile.gettempdir(), "s6_lst_cache"))


def _rate_reth(w):
    return w[1] * E18 // w[3]                  # data: slotTimestamp, totalEth, stakingEth, rethSupply, blockTimestamp


def _rate_cbeth(w):
    return w[0]                                # data: newExchangeRate


def _rate_weeth(w):
    return w[0] * E18 // w[1]                  # data: totalEthLocked, totalEEthShares


TOKENS = {
    "rETH": {"addr": "0xae78736Cd615f374D3085123A210448E74Fc6393", "sel": "0xe6aa216c",
             "fn": "getExchangeRate()", "grid": 256,
             "event": "BalancesUpdated", "topic0": "0xdd27295717c4fbd48b1840f846e18be6f0b7bd6b55608e697e53b15848cecdf9",
             "emitters": ["0x6cc65bf618f55ce2433f9d8d827fc44117d81399", "0x1d9f14c6bfd8358b589964bad8665add248e9473"],
             "words": 5, "implied": _rate_reth},
    "cbETH": {"addr": "0xBe9895146f7AF43049ca1c1AE358B0541Ea49704", "sel": "0x3ba0b9a9",
              "fn": "exchangeRate()", "grid": 256,
              "event": "ExchangeRateUpdated", "topic0": "0x0b4e9390054347e2a16d95fd8376311b0d2deedecba526e9742bcaa40b059f0b",
              "emitters": ["0xbe9895146f7af43049ca1c1ae358b0541ea49704"],
              "words": 1, "implied": _rate_cbeth},
    "weETH": {"addr": "0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee", "sel": "0x679aefce",
              "fn": "getRate()", "grid": 64,
              "event": "Rebase", "topic0": "0x11c6bf55864ff83827df712625d7a80e5583eef0264921025e7cd22003a21511",
              "emitters": ["0x308861a430be4cce5502d0a12724771fc6daf216"],
              "words": 2, "implied": _rate_weeth},
}
FIELDS = ["block", "timestamp", "gap_s", "preRate", "postRate", "move_bps", "update_event_tx", "event_rate"]


def csv_path(tok):
    return os.path.join(HERE, "data", f"lst_rates_{tok}.csv")


# ------------------------------------------------------------------------------ RPC
def _scrub(s):
    return re.sub(r"https?://[^\s\"']+", "<RPC>", str(s))


class RPC:
    def __init__(self):
        self._url = os.environ.get("MAINNET_RPC_URL", "")
        if not self._url:
            sys.exit("MAINNET_RPC_URL is not set (load packages/contracts/.env into the environment)")
        self.n = 0

    def batch(self, reqs, retries=8):
        """reqs: [(method, params)]; returns results in order. Raises on any per-item error."""
        body = json.dumps([{"jsonrpc": "2.0", "id": i, "method": m, "params": p}
                           for i, (m, p) in enumerate(reqs)]).encode()
        last = None
        for attempt in range(retries):
            try:
                req = urllib.request.Request(self._url, data=body, headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=120) as r:
                    resp = json.loads(r.read())
                if isinstance(resp, dict):
                    raise RuntimeError(f"batch error {_scrub(resp.get('error', resp))[:300]}")
                resp = sorted(resp, key=lambda x: x["id"])
                errs = [x["error"] for x in resp if "error" in x]
                if errs:
                    raise RuntimeError(f"item error {_scrub(errs[0])[:300]}")
                if len(resp) != len(reqs):
                    raise RuntimeError(f"batch returned {len(resp)} of {len(reqs)}")
                self.n += len(reqs)
                return [x["result"] for x in resp]
            except Exception as e:             # transport, rate limit, partial read: back off
                last = _scrub(e)
                if re.search(r"range|too (many|large)|exceed|response size|10000", last, re.I) and \
                        reqs[0][0] == "eth_getLogs":
                    raise RuntimeError(last) from None
                time.sleep(2.0 * (attempt + 1))
        raise RuntimeError(f"gave up after {retries} attempts: {last}")

    def call(self, method, params):
        return self.batch([(method, params)])[0]

    def rates(self, tok, blocks):
        t = TOKENS[tok]
        out = []
        for i in range(0, len(blocks), 100):
            part = blocks[i:i + 100]
            out += [int(x, 16) for x in self.batch([("eth_call", [{"to": t["addr"], "data": t["sel"]}, hex(b)])
                                                     for b in part])]
        return out

    def timestamps(self, blocks):
        out = []
        for i in range(0, len(blocks), 25):
            part = blocks[i:i + 25]
            time.sleep(0.2)
            out += [int(x["timestamp"], 16) for x in self.batch([("eth_getBlockByNumber", [hex(b), False])
                                                                  for b in part])]
        return out


# ------------------------------------------------------------------------------ fetch
def changes_in(rpc, tok, lo, hi, grid):
    """All blocks b in (lo, hi] with rate(b-1) != rate(b) that grid sampling + bisection sees."""
    pts = list(range(lo, hi, grid)) + [hi]
    vals = dict(zip(pts, rpc.rates(tok, pts)))
    todo = [(pts[i], pts[i + 1]) for i in range(len(pts) - 1) if vals[pts[i]] != vals[pts[i + 1]]]
    found = []
    while todo:
        nxt, mids = [], []
        for a, b in todo:
            if b - a == 1:
                found.append([b, vals[a], vals[b]])
            else:
                mids.append((a, (a + b) // 2, b))
        if mids:
            for (a, m, b), v in zip(mids, rpc.rates(tok, [m for _, m, _ in mids])):
                vals[m] = v
                if vals[a] != v:
                    nxt.append((a, m))
                if v != vals[b]:
                    nxt.append((m, b))
        todo = nxt
    return sorted(found)


def block_at_or_after(rpc, ts, lo, hi):
    """Smallest block in [lo, hi] with timestamp >= ts."""
    while lo < hi:
        mid = (lo + hi) // 2
        if rpc.timestamps([mid])[0] >= ts:
            hi = mid
        else:
            lo = mid + 1
    return lo


def fetch_logs(rpc, tok, start, end):
    t = TOKENS[tok]
    out, lo, step = [], start, 100_000
    while lo <= end:
        hi = min(end, lo + step - 1)
        try:
            logs = rpc.call("eth_getLogs", [{"address": t["emitters"], "topics": [t["topic0"]],
                                             "fromBlock": hex(lo), "toBlock": hex(hi)}])
        except RuntimeError:
            if step > 1:
                step = max(1, step // 4)
                continue
            raise
        out.extend(logs)
        lo = hi + 1
    return out


def fetch(rpc, tok):
    """Advance the resumable scan for one token; returns True when the CSV has been written."""
    t0 = time.time()
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, f"{tok}.json")
    st = json.load(open(path)) if os.path.exists(path) else {}

    def save():
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, path)

    if "head" not in st:
        head = int(rpc.call("eth_blockNumber", []), 16)
        hts = rpc.timestamps([head])[0]
        start = block_at_or_after(rpc, hts - DAYS * 86400, head - 3_500_000, head)
        sts = rpc.timestamps([start])[0]
        st = {"head": head, "head_ts": hts, "start": start, "start_ts": sts,
              "grid": TOKENS[tok]["grid"], "next": start, "changes": []}
        save()
    head, start, grid = st["head"], st["start"], st["grid"]
    while st["next"] < head:
        if time.time() - t0 > FETCH_BUDGET_S:
            print(f"  {tok}: scanned {start}..{st['next']} of ..{head}, {len(st['changes'])} changes so far;"
                  f" INCOMPLETE, run --fetch again", file=sys.stderr)
            return False
        lo, hi = st["next"], min(head, st["next"] + CHUNK)
        st["changes"] += changes_in(rpc, tok, lo, hi, grid)
        st["next"] = hi
        save()
    if "events" not in st:
        spec = TOKENS[tok]
        evs = []
        for lg in fetch_logs(rpc, tok, start + 1, head):
            d = lg["data"][2:]
            assert lg["topics"][0].lower() == spec["topic0"] and len(d) == 64 * spec["words"], lg["transactionHash"]
            w = [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]
            evs.append([int(lg["blockNumber"], 16), int(lg["logIndex"], 16), lg["transactionHash"],
                        lg["address"].lower(), spec["implied"](w)])
        st["events"] = sorted(evs)
        save()
    if "event_only" not in st:
        seen = {c[0] for c in st["changes"]}
        extra = sorted({e[0] for e in st["events"]} - seen)
        added, flat = [], []
        for b in extra:
            a, c = rpc.rates(tok, [b - 1, b])
            (added if a != c else flat).append([b, a, c])
        st["event_only"] = added
        st["event_flat_blocks"] = [x[0] for x in flat]
        save()
    st.setdefault("ts", {})
    todo = [c[0] for c in sorted(st["changes"] + st["event_only"]) if str(c[0]) not in st["ts"]]
    for i in range(0, len(todo), 500):
        if time.time() - t0 > FETCH_BUDGET_S:
            print(f"  {tok}: {len(todo) - i} block timestamps left; INCOMPLETE, run --fetch again", file=sys.stderr)
            return False
        part = todo[i:i + 500]
        st["ts"].update(zip(map(str, part), rpc.timestamps(part)))
        save()
    write_csv(tok, st)
    print(f"  {tok}: COMPLETE, wrote {csv_path(tok)} ({time.time() - t0:.0f} s this run,"
          f" {rpc.n} rpc items)", file=sys.stderr)
    return True


# ------------------------------------------------------------------------------ CSV
def exact_bps(pre, post):
    return F(post - pre, pre) * 10**4


def fmt_bps(x):
    return f"{float(x):+.6f}"


def write_csv(tok, st):
    ev_by_block = {}
    for b, _li, tx, _addr, rate in st["events"]:
        ev_by_block.setdefault(b, []).append((tx, rate))
    allc = sorted(st["changes"] + st["event_only"])
    os.makedirs(os.path.dirname(csv_path(tok)), exist_ok=True)
    t = TOKENS[tok]
    with open(csv_path(tok), "w", newline="") as f:
        f.write(f"# token {tok} {t['addr']} rate {t['fn']}\n")
        f.write(f"# scanned blocks {st['start']}..{st['head']} (timestamps {st['start_ts']}..{st['head_ts']}),"
                f" grid {st['grid']} blocks + bisection\n")
        f.write(f"# {t['event']} events in range: {len(st['events'])} in {len(ev_by_block)} blocks;"
                f" changes found only via an event block: {len(st['event_only'])};"
                f" event blocks with no rate change: {len(st['event_flat_blocks'])}"
                f" {' '.join(map(str, st['event_flat_blocks']))}\n")
        w = csv.writer(f)
        w.writerow(FIELDS)
        prev = None
        for b, pre, post in allc:
            evs = ev_by_block.get(b, [])
            ts = st["ts"][str(b)]
            w.writerow([b, ts, "" if prev is None else ts - prev, pre, post, fmt_bps(exact_bps(pre, post)),
                        ";".join(e[0] for e in evs), ";".join(str(e[1]) for e in evs)])
            prev = ts


def read_csv(tok):
    meta, lines = [], []
    with open(csv_path(tok), newline="") as f:
        for line in f:
            (meta if line.startswith("#") else lines).append(line)
    rows = []
    for r in csv.DictReader(lines):
        rows.append({"block": int(r["block"]), "timestamp": int(r["timestamp"]),
                     "preRate": int(r["preRate"]), "postRate": int(r["postRate"]),
                     "tx": r["update_event_tx"],
                     "event_rate": [int(x) for x in r["event_rate"].split(";")] if r["event_rate"] else []})
    return [m[2:].rstrip("\n") for m in meta], rows


# -------------------------------------------------------------------------- summary
def dur(s):
    return f"{s} s = {s / 86400:.4f} d"


def nearest_rank(srt, pct):
    k = -(-pct * len(srt) // 100)
    return srt[k - 1], k


def summary(tok, meta, rows):
    n = len(rows)
    mv = [exact_bps(r["preRate"], r["postRate"]) for r in rows]
    srt = sorted(mv)
    mean = sum(mv, F(0)) / n
    median = srt[n // 2] if n % 2 else (srt[n // 2 - 1] + srt[n // 2]) / 2
    p99, k = nearest_rank(srt, 99)
    chain_bad = [rows[i]["block"] for i in range(1, n) if rows[i]["preRate"] != rows[i - 1]["postRate"]]
    drops = [(r, m) for r, m in zip(rows, mv) if r["postRate"] < r["preRate"]]
    at_thr = [(r, m) for r, m in zip(rows, mv) if abs(m) >= THRESHOLD_BPS]
    gaps = sorted(rows[i]["timestamp"] - rows[i - 1]["timestamp"] for i in range(1, n))
    gmed = gaps[len(gaps) // 2] if len(gaps) % 2 else F(gaps[len(gaps) // 2 - 1] + gaps[len(gaps) // 2], 2)
    gi = max(range(1, n), key=lambda i: rows[i]["timestamp"] - rows[i - 1]["timestamp"])
    imax = max(range(n), key=lambda i: abs(mv[i]))
    with_ev = [(r, m) for r, m in zip(rows, mv) if r["tx"]]
    no_ev = [(r, m) for r, m in zip(rows, mv) if not r["tx"]]
    ev_diff = [r for r, _ in with_ev if r["event_rate"][-1] != r["postRate"]]
    ev_match = len(with_ev) - len(ev_diff)

    print(f"=== s6: {tok}")
    for m in meta:
        print(f"  {m}")
    print(f"  rate changes: {n}   blocks {rows[0]['block']} .. {rows[-1]['block']}")
    print(f"  chain check (each preRate == previous postRate): {'OK' if not chain_bad else chain_bad}")
    print(f"  move_bps = (postRate - preRate) / preRate * 1e4, exact, shown to 6 dp")
    print(f"  threshold (s3e Part 3, fee 5000, A=50 demo order): {S3E_STEP_WEI} / {S3E_R0} * 1e4"
          f" = {float(THRESHOLD_BPS):.6f} bps")
    print(f"  min    {fmt_bps(srt[0])}")
    print(f"  max    {fmt_bps(srt[-1])}")
    print(f"  mean   {fmt_bps(mean)}")
    print(f"  median {fmt_bps(median)}")
    print(f"  p99    {fmt_bps(p99)}   (nearest rank: {k}-th smallest of {n})")
    print(f"  largest |move|: {fmt_bps(mv[imax])} bps at block {rows[imax]['block']}")
    ev = TOKENS[tok]["event"]
    print(f"  changes in a block with a {ev} event: {len(with_ev)}"
          f" (last event's implied rate == postRate in {ev_match}, differs in {len(ev_diff)});"
          f"  without: {len(no_ev)}")
    for r in ev_diff:
        e = r["event_rate"][-1]
        print(f"    EVENT != POST block {r['block']} tx {r['tx']}: preRate {r['preRate']} -> event rate {e}"
              f" ({fmt_bps(exact_bps(r['preRate'], e))} bps) -> postRate {r['postRate']}"
              f" ({fmt_bps(exact_bps(e, r['postRate']))} bps from event to end of block;"
              f" {r['postRate'] - e:+d} wei): another rate-moving tx later in the same block")
    for label, grp in ((f"blocks with a {ev} event", with_ev), (f"blocks without a {ev} event", no_ev)):
        if not grp:
            continue
        s2 = sorted(m for _, m in grp)
        k2 = len(s2)
        med2 = s2[k2 // 2] if k2 % 2 else (s2[k2 // 2 - 1] + s2[k2 // 2]) / 2
        p2, kk = nearest_rank(s2, 99)
        print(f"  subset, {label}: {k2} changes; move_bps min {fmt_bps(s2[0])}  max {fmt_bps(s2[-1])}"
              f"  mean {fmt_bps(sum(s2, F(0)) / k2)}  median {fmt_bps(med2)}  p99 {fmt_bps(p2)} ({kk}-th)"
              f"  sum {fmt_bps(sum(s2, F(0)))}  drops {sum(1 for m in s2 if m < 0)}"
              f"  |move| >= threshold {sum(1 for m in s2 if abs(m) >= THRESHOLD_BPS)}")
    print(f"  drops (postRate < preRate): {len(drops)}")
    for r, m in drops:
        print(f"    DROP block {r['block']} ts {r['timestamp']} {r['preRate']} -> {r['postRate']}"
              f" ({fmt_bps(m)} bps){' event tx ' + r['tx'] if r['tx'] else ''}")
    print(f"  changes with |move| >= threshold: {len(at_thr)}")
    for r, m in at_thr:
        print(f"    block {r['block']} ts {r['timestamp']} {r['preRate']} -> {r['postRate']} ({fmt_bps(m)} bps)"
              f"{' event tx ' + r['tx'] if r['tx'] else ''}")
    print(f"  time between consecutive changes (block timestamp diff): median {dur(gmed)};"
          f" shortest {dur(gaps[0])}; longest {dur(gaps[-1])}"
          f" (block {rows[gi - 1]['block']} -> {rows[gi]['block']})")
    if with_ev and len(with_ev) > 1:
        eg = sorted(with_ev[i][0]["timestamp"] - with_ev[i - 1][0]["timestamp"] for i in range(1, len(with_ev)))
        print(f"  between changes that carry an update event: median {dur(eg[len(eg) // 2])};"
              f" longest {dur(eg[-1])}")
    return mv


# ---------------------------------------------------------------------- cross-check
def crosscheck(rpc, tok, rows, mv):
    n = len(rows)
    pick = {0, n - 1, max(range(n), key=lambda i: abs(mv[i])), min(range(n), key=lambda i: mv[i])}
    drops = [i for i in range(n) if rows[i]["postRate"] < rows[i]["preRate"]]
    pick |= set(drops)
    pick |= {round(i * (n - 1) / 9) for i in range(10)}
    no_ev = [i for i in range(n) if not rows[i]["tx"]]
    pick |= {no_ev[round(i * (len(no_ev) - 1) / 3)] for i in range(4)} if no_ev else set()
    pick |= {i for i in range(n) if rows[i]["tx"] and rows[i]["event_rate"][-1] != rows[i]["postRate"]}
    t = TOKENS[tok]
    print(f"\n=== cross-check {tok}: single eth_call {t['fn']} at block-1 and block vs CSV")
    print(f"  {'block':>9} {'preRate(csv)':>20} {'call@block-1':>20} {'postRate(csv)':>20} {'call@block':>20}  result")
    allok = True
    for i in sorted(pick):
        r = rows[i]
        a = int(rpc.call("eth_call", [{"to": t["addr"], "data": t["sel"]}, hex(r["block"] - 1)]), 16)
        b = int(rpc.call("eth_call", [{"to": t["addr"], "data": t["sel"]}, hex(r["block"])]), 16)
        ok = a == r["preRate"] and b == r["postRate"]
        allok &= ok
        tag = "MATCH" if ok else f"DIFF pre {a - r['preRate']:+d} post {b - r['postRate']:+d}"
        tag += " (drop)" if r["postRate"] < r["preRate"] else ""
        tag += (" (event != post)" if r["event_rate"][-1] != r["postRate"] else " (event)") if r["tx"] else " (no event)"
        print(f"  {r['block']:>9} {r['preRate']:>20} {a:>20} {r['postRate']:>20} {b:>20}  {tag}")
    print(f"  {len(pick)} checked, all match: {allok}")
    return allok


def main():
    args = sys.argv[1:]
    flags = {a for a in args if a.startswith("--")}
    toks = [a for a in args if not a.startswith("--")] or list(TOKENS)
    if not flags or not flags <= {"--offline", "--fetch", "--crosscheck", "--rewrite"} or {"--offline", "--fetch"} <= flags \
            or not set(toks) <= set(TOKENS):
        sys.exit(__doc__)
    if "--rewrite" in flags:
        for tok in toks:
            write_csv(tok, json.load(open(os.path.join(CACHE, f"{tok}.json"))))
    if "--fetch" in flags:
        rpc = RPC()
        done = [fetch(rpc, tok) for tok in toks]
        if not all(done):
            sys.exit(1)
    rpc = RPC() if "--crosscheck" in flags else None
    ok = True
    for tok in toks:
        meta, rows = read_csv(tok)
        mv = summary(tok, meta, rows)
        if rpc:
            ok &= crosscheck(rpc, tok, rows, mv)
        print()
    if rpc:
        print(f"all cross-checks match: {ok}")


if __name__ == "__main__":
    main()
