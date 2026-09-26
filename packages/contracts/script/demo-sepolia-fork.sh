#!/usr/bin/env bash
# LOCAL FORK OF SEPOLIA (chain 11155111) on port 8546, so the 31337 demo (script/demo.sh, port 8545) can keep
# running. Deploys the RateSpace contracts with DeploySepolia, funds the maker (anvil #0) and taker (anvil #1)
# along the real Sepolia path (stETH.submit -> approve -> wstETH.wrap, WETH.deposit), ships with ShipSepolia,
# and writes deployments/11155111.fork.json (gitignored) + 11155111.abi.json. Nothing is sent to any real network.
# The fork record never touches deployments/11155111.json (the real Sepolia deployment record the app reads):
# this rehearsal checks the scripts, not the app.
#
# Needs SEPOLIA_RPC_URL in the environment (a Sepolia archive/full node). It is passed only to anvil; anvil's
# output is scrubbed of URLs before it reaches the log. Stop with script/demo-sepolia-stop.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${SEPOLIA_RPC_URL:-}" ]; then
  echo "error: export SEPOLIA_RPC_URL first (it is never printed)" >&2
  exit 1
fi

RPC=http://127.0.0.1:8546
# DeploySepolia / ShipSepolia read and write this path instead of deployments/11155111.json. A fresh fork has
# none of the old record's contracts, so the previous rehearsal's file is removed before DeploySepolia runs.
export DEPLOYMENTS_PATH=deployments/11155111.fork.json
# anvil's public default test keys #0 / #1 (printed by anvil at startup; not secrets). FORK ONLY: never use
# these on real Sepolia (see script/SEPOLIA.md for the owner's real-network commands).
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
K1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
MAKER=$(cast wallet address --private-key "$K0")
TAKER=$(cast wallet address --private-key "$K1")

WETH=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14
WSTETH=0xB82381A3fBD3FaFA77B3a7bE693342618240067b
STETH=0x3e3FE7dBc6B4C189E7128855dD526361c49b40Af
# Fork-only funding per account (not an owner number; the owner's deposits are ShipSepolia's SHIP_* env vars)
FUND=1ether

if [ -d /tmp/claude-501 ]; then LOGDIR=/tmp/claude-501; else LOGDIR=.; fi
LOG="$LOGDIR/anvil-sepolia.log"
PIDFILE="$LOGDIR/anvil-sepolia.pid"

if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "error: something already answers on $RPC; run script/demo-sepolia-stop.sh first" >&2
  exit 1
fi

# Line-buffered URL scrub (BSD sed: -l, GNU sed: -u). anvil prints the fork endpoint at startup. The scrubber
# writes only to $LOG (stdout and stderr), so it does not hold this script's stdout open after exit.
if sed --version >/dev/null 2>&1; then SEDBUF=-u; else SEDBUF=-l; fi
anvil --fork-url "$SEPOLIA_RPC_URL" --chain-id 11155111 --port 8546 </dev/null \
  > >(exec sed "$SEDBUF" -E 's#https?://[^ "]+#<RPC>#g' >"$LOG" 2>&1) 2>&1 &
echo $! >"$PIDFILE"
echo "anvil (Sepolia fork) pid $(cat "$PIDFILE"), log $LOG"

for _ in $(seq 1 120); do
  if [ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null || true)" = "11155111" ]; then break; fi
  sleep 0.5
done
if [ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null || true)" != "11155111" ]; then
  echo "error: anvil did not come up on $RPC (see $LOG)" >&2
  exit 1
fi
echo "fork block $(cast block-number --rpc-url "$RPC")"

# On real Sepolia both anvil default accounts carry EIP-7702 delegations (code 0xef0100...; observed
# 2026-09-26). Clear them ON THE FORK so maker and taker behave as plain EOAs, and give each 100 ETH.
for a in "$MAKER" "$TAKER"; do
  cast rpc --rpc-url "$RPC" anvil_setCode "$a" 0x >/dev/null
  cast rpc --rpc-url "$RPC" anvil_setBalance "$a" 0x56bc75e2d63100000 >/dev/null
done

send() { cast send --rpc-url "$RPC" "$@" >/dev/null; }

# Real-path funding: ETH -> stETH (Lido submit) -> wstETH (wrap); ETH -> WETH (deposit)
fund() {
  local key=$1 who=$2
  send --private-key "$key" "$STETH" "submit(address)" 0x0000000000000000000000000000000000000000 --value "$FUND"
  local st
  st=$(cast call --rpc-url "$RPC" "$STETH" "balanceOf(address)(uint256)" "$who" | awk '{print $1}')
  send --private-key "$key" "$STETH" "approve(address,uint256)" "$WSTETH" "$st"
  send --private-key "$key" "$WSTETH" "wrap(uint256)" "$st"
  send --private-key "$key" "$WETH" "deposit()" --value "$FUND"
  echo "$who wstETH $(cast call --rpc-url "$RPC" "$WSTETH" "balanceOf(address)(uint256)" "$who") WETH $(cast call --rpc-url "$RPC" "$WETH" "balanceOf(address)(uint256)" "$who")"
}

rm -f "$DEPLOYMENTS_PATH"

# Separate out/cache and --skip test: tests import BOTH AquaSwapVMRouter versions, which made forge 1.8.1
# script fail to decode constructor args (see script/demo.sh). out-demo/ and cache-demo/ are gitignored.
FOUNDRY_OUT=out-demo FOUNDRY_CACHE_PATH=cache-demo \
  forge script script/DeploySepolia.s.sol --rpc-url "$RPC" --broadcast --skip test --private-key "$K0"

fund "$K0" "$MAKER"
FOUNDRY_OUT=out-demo FOUNDRY_CACHE_PATH=cache-demo \
  forge script script/ShipSepolia.s.sol --rpc-url "$RPC" --broadcast --skip test --private-key "$K0"

fund "$K1" "$TAKER"
for r in $(bun -e 'const d = await Bun.file(process.env.DEPLOYMENTS_PATH).json(); console.log(d.AquaSwapVMRouter, d.RateSpaceAquaRouter)'); do
  send --private-key "$K1" "$WETH" "approve(address,uint256)" "$r" "$(cast max-uint)"
  send --private-key "$K1" "$WSTETH" "approve(address,uint256)" "$r" "$(cast max-uint)"
done

bun run scripts/build-demo-abi.ts 11155111

echo "maker (anvil #0): $MAKER"
echo "taker (anvil #1): $TAKER"
echo "deployments: $(pwd)/$DEPLOYMENTS_PATH (fork only; deployments/11155111.json untouched)"
echo "abis:        $(pwd)/deployments/11155111.abi.json"
