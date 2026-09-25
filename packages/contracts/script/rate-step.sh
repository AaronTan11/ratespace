#!/usr/bin/env bash
# Usage: script/rate-step.sh <wstETH|rETH|weETH> <bps>
# Bumps that demo rate feed by +bps (new = old * (10000 + bps) / 10000, rounded down) from the maker key.
# Simulates an oracle report (e.g. a Lido rebase) on the local demo chain.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -eq 2 ] || { echo "usage: $0 <wstETH|rETH|weETH> <bps>" >&2; exit 2; }
case "$1" in
  wstETH) KEY=RateFeedWstETH ;;
  rETH) KEY=RateFeedRETH ;;
  weETH) KEY=RateFeedWeETH ;;
  *) echo "unknown feed $1 (wstETH|rETH|weETH)" >&2; exit 2 ;;
esac
RPC=http://127.0.0.1:8545
DEMO_MAKER_PK="${DEMO_MAKER_PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
FEED=$(bun -e "console.log((await Bun.file('deployments/31337.json').json())['$KEY'])")
OLD=$(cast call "$FEED" "rate()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
NEW=$(bun -e "console.log((BigInt('$OLD') * (10000n + BigInt('$2')) / 10000n).toString())")
cast send "$FEED" "set(uint256)" "$NEW" --private-key "$DEMO_MAKER_PK" --rpc-url "$RPC" >/dev/null
echo "$1 feed $FEED: $OLD -> $(cast call "$FEED" "rate()(uint256)" --rpc-url "$RPC" | awk '{print $1}')"
