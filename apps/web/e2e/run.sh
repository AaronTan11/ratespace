#!/usr/bin/env bash
# bun run test:e2e: fresh anvil on 8547 + demo deploy, Playwright (starts its own dev server on 3002), teardown.
set -euo pipefail
cd "$(dirname "$0")/.."
e2e/anvil-8547.sh start
trap 'e2e/anvil-8547.sh stop' EXIT
bun run playwright test "$@"
