#!/usr/bin/env bash
# Stop the anvil started by script/demo.sh
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -d /tmp/claude-501 ]; then LOGDIR=/tmp/claude-501; else LOGDIR=.; fi
PIDFILE="$LOGDIR/anvil.pid"
if [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "stopped anvil pid $(cat "$PIDFILE")"
else
  echo "no running anvil from $PIDFILE"
fi
rm -f "$PIDFILE"
