#!/usr/bin/env bash
# E2E-only anvil: reproduces packages/contracts/script/demo.sh on port 8547 (demo.sh hard-codes 8545, which
# the owner's demo may be using). Writes the deployments to packages/contracts/deployments/test-e2e-31337.json
# (DeployDemo honours DEPLOYMENTS_PATH; forge fs_permissions only allow ./deployments).
#   e2e/anvil-8547.sh start   start anvil on 8547 + deploy the demo
#   e2e/anvil-8547.sh stop    kill the anvil this script started, remove the test deployments file
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CONTRACTS="$(cd "$HERE/../../../packages/contracts" && pwd)"
RPC=http://127.0.0.1:8547
RUN="$HERE/.run"
PIDFILE="$RUN/anvil-8547.pid"
LOG="$RUN/anvil-8547.log"
DEPLOY_REL=deployments/test-e2e-31337.json

stop() {
  if [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; then echo "stopped anvil pid $(cat "$PIDFILE") (8547)"; fi
  rm -f "$PIDFILE" "$CONTRACTS/$DEPLOY_REL"
}

start() {
  mkdir -p "$RUN"
  if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
    echo "error: something already answers on $RPC; run e2e/anvil-8547.sh stop first" >&2
    exit 1
  fi
  anvil --chain-id 31337 --port 8547 --block-time 1 >"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  echo "anvil pid $(cat "$PIDFILE") on 8547, log $LOG"
  for _ in $(seq 1 60); do
    if [ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null || true)" = "31337" ]; then break; fi
    sleep 0.5
  done
  [ "$(cast chain-id --rpc-url "$RPC" 2>/dev/null || true)" = "31337" ] || { echo "error: anvil did not come up" >&2; exit 1; }
  # anvil's public default test key #0 (printed by anvil at startup; not a secret)
  (cd "$CONTRACTS" && DEPLOYMENTS_PATH="$DEPLOY_REL" \
    DEMO_MAKER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
    FOUNDRY_OUT=out-demo FOUNDRY_CACHE_PATH=cache-demo \
    forge script script/DeployDemo.s.sol --rpc-url "$RPC" --broadcast --skip test >"$RUN/deploy.log" 2>&1) \
    || { echo "error: deploy failed, see $RUN/deploy.log" >&2; exit 1; }
  echo "deployments: $CONTRACTS/$DEPLOY_REL"
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
