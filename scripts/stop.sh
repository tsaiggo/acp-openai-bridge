#!/usr/bin/env bash
# Stop acp-openai-bridge daemon.

set -euo pipefail

PID_FILE="$HOME/.acp-openai-bridge.pid"

if [[ ! -f "$PID_FILE" ]]; then
  echo "acp-openai-bridge is not running (no PID file)"
  exit 0
fi

PID=$(cat "$PID_FILE")

if ! kill -0 "$PID" 2>/dev/null; then
  echo "acp-openai-bridge is not running (stale PID $PID)"
  rm -f "$PID_FILE"
  exit 0
fi

echo "Stopping acp-openai-bridge (PID $PID) ..."
kill "$PID"

# Wait up to 5s for graceful shutdown
for i in {1..10}; do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "Stopped ✓"
    rm -f "$PID_FILE"
    exit 0
  fi
  sleep 0.5
done

# Force kill
echo "Graceful shutdown timed out, force killing ..."
kill -9 "$PID" 2>/dev/null || true
rm -f "$PID_FILE"
echo "Killed ✓"
