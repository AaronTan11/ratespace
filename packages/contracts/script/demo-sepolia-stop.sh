#!/usr/bin/env bash
# Stop the Sepolia-fork anvil started by script/demo-sepolia-fork.sh (port 8546)
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -d /tmp/claude-501 ]; then LOGDIR=/tmp/claude-501; else LOGDIR=.; fi
PIDFILE="$LOGDIR/anvil-sepolia.pid"
if [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "stopped anvil (Sepolia fork) pid $(cat "$PIDFILE")"
else
  echo "no running anvil from $PIDFILE"
fi
rm -f "$PIDFILE"
