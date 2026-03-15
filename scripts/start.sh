#!/usr/bin/env bash
# Start acp-openai-bridge as a background daemon.
# Logs go to ~/.acp-openai-bridge.log
# PID saved to ~/.acp-openai-bridge.pid

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PID_FILE="$HOME/.acp-openai-bridge.pid"
LOG_FILE="$HOME/.acp-openai-bridge.log"
PORT=4000

# Check if already running
if [[ -f "$PID_FILE" ]]; then
  PID=$(cat "$PID_FILE")
  if kill -0 "$PID" 2>/dev/null; then
    echo "acp-openai-bridge is already running (PID $PID)"
    echo "  Logs: $LOG_FILE"
    echo "  Stop: $(dirname "$0")/stop.sh"
    exit 0
  else
    rm -f "$PID_FILE"
  fi
fi

# Check prerequisites
if ! command -v bun &>/dev/null; then
  echo "Error: bun is not installed. Install it from https://bun.sh/"
  exit 1
fi

if ! command -v copilot &>/dev/null; then
  echo "Error: copilot CLI is not installed."
  echo "  Run: gh extension install github/gh-copilot"
  exit 1
fi

if ! gh auth status &>/dev/null 2>&1; then
  echo "Error: GitHub CLI is not authenticated."
  echo "  Run: gh auth login"
  exit 1
fi

# Start
echo "Starting acp-openai-bridge ..."
cd "$PROJECT_DIR"
nohup bun run src/index.ts > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"

echo "  PID:  $(cat "$PID_FILE")"
echo "  URL:  http://localhost:$PORT/v1"
echo "  Logs: $LOG_FILE"
echo "  Stop: $(dirname "$0")/stop.sh"

# Wait briefly and verify it's alive
sleep 1
if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "  Status: running ✓"
else
  echo "  Status: FAILED — check $LOG_FILE"
  rm -f "$PID_FILE"
  exit 1
fi
