"""Per-report moves of wstETH.stEthPerToken() from Lido's mainnet history.

Source: every stETH `TokenRebased` log (Lido V2+ accounting oracle report).
  event TokenRebased(uint256 indexed reportTimestamp, uint256 timeElapsed,
                     uint256 preTotalShares, uint256 preTotalEther,
                     uint256 postTotalShares, uint256 postTotalEther,
                     uint256 sharesMintedAsFees)
  topic0 = keccak256 of the signature above (checked against the log in tx
  0x4732fc5c...ec95, block 26047293, which has exactly 1 indexed topic and 6 data words).
Rate per report (stEthPerToken = getPooledEthByShares(1e18), floor division):
  preRate  = preTotalEther  * 1e18 // preTotalShares
  postRate = postTotalEther * 1e18 // postTotalShares
  move_bps = (postRate - preRate) / preRate * 1e4        (exact Fraction)
Threshold: the smallest upward step at which the 0.05% fee no longer blocks the
buy-before / sell-after round trip, re-derived by s3e_fee_roundtrip.py Part 3 for the demo
order (A=50, band 500, r0 = 1.2e18): r0 + 1206113946104793 wei. It is specific to that order.

Run from packages/contracts/analysis:
  python3 s5_lido_reports.py --offline        # summary from data/lido_reports.csv (no network)
  python3 s5_lido_reports.py --fetch          # re-collect logs from RPC, rewrite the CSV, summary
  python3 s5_lido_reports.py --crosscheck     # eth_call stEthPerToken() at block-1 / block
--fetch and --crosscheck read the RPC endpoint from the MAINNET_RPC_URL environment variable
(e.g. `set -a; . ../.env; set +a`). The URL is never printed or written.
"""
import csv
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from fractions import Fraction as F

STETH = "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84"
WSTETH = "0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0"
TOKEN_REBASED = "0xff08c3ef606d198e316ef5b822193c489965899eb4e3c248cea1a4626c3eda50"
ST_ETH_PER_TOKEN = "0x035faf82"                 # cast sig 'stEthPerToken()'
E18 = 10**18
S3E_R0 = 12 * 10**17                            # common.py R0
S3E_STEP_WEI = 1206113946104793                 # s3e Part 3, fee=5000: first positive step
THRESHOLD_BPS = F(S3E_STEP_WEI, S3E_R0) * 10**4
CSV_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "lido_reports.csv")
FIELDS = ["block", "tx_hash", "report_timestamp", "time_elapsed", "preRate", "postRate", "move_bps"]


# ------------------------------------------------------------------------------ RPC
def _scrub(s):
    return re.sub(r"https?://[^\s\"']+", "<RPC>", str(s))


class RPC:
    def __init__(self):
        self._url = os.environ.get("MAINNET_RPC_URL", "")
        if not self._url:
            sys.exit("MAINNET_RPC_URL is not set (load packages/contracts/.env into the environment)")
        self._id = 0

    def call(self, method, params, retries=6):
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}).encode()
        for attempt in range(retries):
            try:
                req = urllib.request.Request(self._url, data=body, headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=60) as r:
                    resp = json.loads(r.read())
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                if attempt == retries - 1:
                    raise RuntimeError(f"{method}: transport error {_scrub(e)}") from None
                time.sleep(1.5 * (attempt + 1))
                continue
            if "error" in resp:
                err = resp["error"]
                code, msg = err.get("code"), _scrub(err.get("message", ""))
                if code == 429 or "rate" in msg.lower() and "limit" in msg.lower():
                    time.sleep(2.0 * (attempt + 1))
                    continue
                raise RuntimeError(f"{method}: rpc error {code} {msg}")
            time.sleep(0.05)
            return resp["result"]
        raise RuntimeError(f"{method}: gave up after {retries} attempts")


def fetch_logs(rpc, start, end):
    """All TokenRebased logs of stETH in [start, end]; shrinks the range on provider limits."""
    out, lo, step = [], start, 500_000
    while lo <= end:
        hi = min(end, lo + step - 1)
        try:
            logs = rpc.call("eth_getLogs", [{"address": STETH, "topics": [TOKEN_REBASED],
                                             "fromBlock": hex(lo), "toBlock": hex(hi)}])
        except RuntimeError as e:
            if step > 1 and re.search(r"range|limit|too (many|large)|exceed|10000|response size", str(e), re.I):
                step = max(1, step // 4)
                continue
            raise
        out.extend(logs)
        print(f"  getLogs {lo}..{hi}: {len(logs)} logs (total {len(out)})", file=sys.stderr)
        lo = hi + 1
    return out


def decode(log):
    assert log["topics"][0].lower() == TOKEN_REBASED and len(log["topics"]) == 2, log["transactionHash"]
    d = log["data"][2:]
    assert len(d) == 64 * 6, log["transactionHash"]
    w = [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]
    time_elapsed, pre_sh, pre_eth, post_sh, post_eth, _fees = w
    pre, post = pre_eth * E18 // pre_sh, post_eth * E18 // post_sh
    return {"block": int(log["blockNumber"], 16), "log_index": int(log["logIndex"], 16),
            "tx_hash": log["transactionHash"], "report_timestamp": int(log["topics"][1], 16),
            "time_elapsed": time_elapsed, "preRate": pre, "postRate": post}


def fmt_bps(x):
    return f"{float(x):.6f}" if abs(x) < 10**6 else str(x)


def exact_bps(pre, post):
    return F(post - pre, pre) * 10**4


def write_csv(rows):
    os.makedirs(os.path.dirname(CSV_PATH), exist_ok=True)
    with open(CSV_PATH, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(FIELDS)
        for r in rows:
            w.writerow([r["block"], r["tx_hash"], r["report_timestamp"], r["time_elapsed"],
                        r["preRate"], r["postRate"], fmt_bps(exact_bps(r["preRate"], r["postRate"]))])


def read_csv():
    rows = []
    with open(CSV_PATH, newline="") as f:
        for r in csv.DictReader(f):
            rows.append({"block": int(r["block"]), "tx_hash": r["tx_hash"],
                         "report_timestamp": int(r["report_timestamp"]),
                         "time_elapsed": int(r["time_elapsed"]),
                         "preRate": int(r["preRate"]), "postRate": int(r["postRate"])})
    return rows


# -------------------------------------------------------------------------- summary
def dur(s):
    return f"{s} s = {s / 86400:.4f} d"


def summary(rows, source):
    rows = sorted(rows, key=lambda r: (r["block"], r.get("log_index", 0)))
    n = len(rows)
    mv = [exact_bps(r["preRate"], r["postRate"]) for r in rows]
    srt = sorted(mv)
    mean = sum(mv, F(0)) / n
    median = srt[n // 2] if n % 2 else (srt[n // 2 - 1] + srt[n // 2]) / 2
    k = -(-99 * n // 100)                      # nearest-rank p99: ceil(0.99 n)-th smallest
    p99 = srt[k - 1]
    drops = [(r, m) for r, m in zip(rows, mv) if r["postRate"] < r["preRate"]]
    flat = sum(1 for r in rows if r["postRate"] == r["preRate"])
    at_thr = [(r, m) for r, m in zip(rows, mv) if abs(m) >= THRESHOLD_BPS]
    gaps = [(rows[i]["report_timestamp"] - rows[i - 1]["report_timestamp"], rows[i - 1], rows[i])
            for i in range(1, n)]
    g, ga, gb = max(gaps, key=lambda t: t[0])
    gmin = min(gaps, key=lambda t: t[0])
    imax = max(range(n), key=lambda i: abs(mv[i]))
    # between reports: next report's preRate vs previous report's postRate
    between = [(rows[i - 1], rows[i], exact_bps(rows[i - 1]["postRate"], rows[i]["preRate"]))
               for i in range(1, n)]
    bdrops = [b for b in between if b[1]["preRate"] < b[0]["postRate"]]
    bmax = max(between, key=lambda b: abs(b[2]))

    print(f"=== s5: Lido TokenRebased reports ({source})")
    print(f"  events: {n}   blocks {rows[0]['block']} .. {rows[-1]['block']}"
          f"   report_timestamp {rows[0]['report_timestamp']} .. {rows[-1]['report_timestamp']}")
    print(f"  move_bps = (postRate - preRate) / preRate * 1e4, exact, shown to 6 dp")
    print(f"  min    {fmt_bps(srt[0])}")
    print(f"  max    {fmt_bps(srt[-1])}")
    print(f"  mean   {fmt_bps(mean)}")
    print(f"  median {fmt_bps(median)}")
    print(f"  p99    {fmt_bps(p99)}   (nearest rank: {k}-th smallest of {n})")
    print(f"  largest |move|: {fmt_bps(mv[imax])} bps at block {rows[imax]['block']} tx {rows[imax]['tx_hash']}")
    print(f"  drops (postRate < preRate): {len(drops)}   unchanged (postRate == preRate): {flat}")
    for r, m in drops:
        print(f"    DROP block {r['block']} tx {r['tx_hash']} {r['preRate']} -> {r['postRate']} ({fmt_bps(m)} bps)")
    print(f"  threshold (s3e Part 3, fee 5000, A=50 demo order): {S3E_STEP_WEI} / {S3E_R0} * 1e4"
          f" = {fmt_bps(THRESHOLD_BPS)} bps")
    print(f"  reports with |move| >= threshold: {len(at_thr)}")
    for r, m in at_thr:
        print(f"    block {r['block']} tx {r['tx_hash']} {fmt_bps(m)} bps")
    print(f"  time between consecutive reports (report_timestamp diff):"
          f" longest {dur(g)} (block {ga['block']} -> {gb['block']}); shortest {dur(gmin[0])}")
    bg = max(range(1, n), key=lambda i: rows[i]["block"] - rows[i - 1]["block"])
    print(f"  longest gap in blocks: {rows[bg]['block'] - rows[bg - 1]['block']}"
          f" (block {rows[bg - 1]['block']} -> {rows[bg]['block']})")
    print(f"  time_elapsed field: min {min(r['time_elapsed'] for r in rows)} s,"
          f" max {max(r['time_elapsed'] for r in rows)} s")
    print(f"  between reports (next preRate vs previous postRate): max |move| {fmt_bps(bmax[2])} bps"
          f" (block {bmax[0]['block']} -> {bmax[1]['block']}); drops: {len(bdrops)}")
    for a, b, m in bdrops:
        print(f"    BETWEEN-DROP {a['block']} -> {b['block']}: {a['postRate']} -> {b['preRate']} ({fmt_bps(m)} bps)")
    return rows, mv


# ---------------------------------------------------------------------- cross-check
def st_eth_per_token(rpc, block):
    return int(rpc.call("eth_call", [{"to": WSTETH, "data": ST_ETH_PER_TOKEN}, hex(block)]), 16)


def crosscheck(rpc, rows, mv):
    n = len(rows)
    pick = {0, n - 1, max(range(n), key=lambda i: abs(mv[i])), min(range(n), key=lambda i: mv[i])}
    pick |= {round(i * (n - 1) / 9) for i in range(10)}
    pick |= {i for i, r in enumerate(rows) if r["block"] == 26047293}
    per_block = {}
    for r in rows:
        per_block[r["block"]] = per_block.get(r["block"], 0) + 1
    print(f"\n=== cross-check: wstETH.stEthPerToken() at block-1 and block vs event pre/post rate")
    print(f"  {'block':>9} {'preRate(event)':>20} {'call@block-1':>20} {'postRate(event)':>20} {'call@block':>20}  result")
    allok = True
    for i in sorted(pick):
        r = rows[i]
        a, b = st_eth_per_token(rpc, r["block"] - 1), st_eth_per_token(rpc, r["block"])
        ok = a == r["preRate"] and b == r["postRate"]
        note = "MATCH" if ok else f"DIFF pre {a - r['preRate']:+d} post {b - r['postRate']:+d}"
        if per_block[r["block"]] > 1:
            note += f" ({per_block[r['block']]} reports in block)"
        allok &= ok
        print(f"  {r['block']:>9} {r['preRate']:>20} {a:>20} {r['postRate']:>20} {b:>20}  {note}")
    print(f"  all match: {allok}")


def main():
    args = set(sys.argv[1:])
    if not args or not args <= {"--offline", "--fetch", "--crosscheck"} or {"--offline", "--fetch"} <= args:
        sys.exit(__doc__)
    if "--fetch" in args:
        rpc = RPC()
        head = int(rpc.call("eth_blockNumber", []), 16)
        print(f"  latest block {head}", file=sys.stderr)
        rows = [decode(l) for l in fetch_logs(rpc, 0, head)]
        rows.sort(key=lambda r: (r["block"], r["log_index"]))
        write_csv(rows)
        print(f"  wrote {len(rows)} rows (scanned blocks 0..{head})", file=sys.stderr)
        rows = read_csv()                      # summarise exactly what was committed
        source = f"fetched, scanned blocks 0..{head}"
    else:
        rows = read_csv()
        source = f"offline, {os.path.relpath(CSV_PATH)}"
    rows, mv = summary(rows, source)
    if "--crosscheck" in args:
        crosscheck(RPC(), rows, mv)


if __name__ == "__main__":
    main()
