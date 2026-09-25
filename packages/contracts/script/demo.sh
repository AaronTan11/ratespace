#!/usr/bin/env bash
# Local demo: start anvil (chain 31337), deploy 1inch Aqua 0.1.0 + AquaSwapVMRouter v1.0.2 + RateSpace
# contracts and demo tokens, seed maker (anvil #0) and taker (anvil #1). Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=http://127.0.0.1:8545
# anvil's public default test key #0 (printed by anvil at startup; not a secret)
export DEMO_MAKER_PK="${DEMO_MAKER_PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
if [ -d /tmp/claude-501 ]; then LOGDIR=/tmp/claude-501; else LOGDIR=.; fi
LOG="$LOGDIR/anvil.log"
PIDFILE="$LOGDIR/anvil.pid"

if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "error: something already answers on $RPC; run script/demo-stop.sh first" >&2
  exit 1
fi

anvil --chain-id 31337 --port 8545 --block-time 1 >"$LOG" 2>&1 &
echo $! >"$PIDFILE"
echo "anvil pid $(cat "$PIDFILE"), log $LOG"

for _ in $(seq 1 60); do
  if [ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null || true)" = "31337" ]; then break; fi
  sleep 0.5
done
if [ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null || true)" != "31337" ]; then
  echo "error: anvil did not come up on $RPC (see $LOG)" >&2
  exit 1
fi

# Separate out/cache and --skip test: tests import BOTH AquaSwapVMRouter versions (lib/swap-vm and
# lib/swap-vm-v1). With both artifacts in out/, forge 1.8.1 script aborted with "Failed to decode
# constructor arguments contract=AquaSwapVMRouter" (observed 2026-09-26). Compiling without tests leaves
# only the v1.0.2 artifact, and the script then runs.
FOUNDRY_OUT=out-demo FOUNDRY_CACHE_PATH=cache-demo \
  forge script script/DeployDemo.s.sol --rpc-url "$RPC" --broadcast --skip test
bun run scripts/build-demo-abi.ts

echo "deployments: $(pwd)/deployments/31337.json"
echo "abis:        $(pwd)/deployments/31337.abi.json"
