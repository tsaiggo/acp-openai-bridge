#!/usr/bin/env bash
# test-v2.sh — Validates the v2 milestone of acp-openai-bridge.
# Covers: streaming chat completions (SSE) + non-streaming regression.
# Usage: bash scripts/test-v2.sh  (from repo root)

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

BASE_URL="http://localhost:4000"
BRIDGE_CMD="bun run src/index.ts"
MAX_RETRIES=30
RETRY_INTERVAL=1

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

BRIDGE_PID=""
PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Cleanup — kill bridge on exit (even on error/interrupt)
# ---------------------------------------------------------------------------

cleanup() {
  if [[ -n "$BRIDGE_PID" ]] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo ""
    echo "==> Stopping bridge (PID $BRIDGE_PID) ..."
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() {
  echo "[PASS] $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "[FAIL] $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert() {
  local description="$1"
  local expression="$2"

  if eval "$expression" > /dev/null 2>&1; then
    pass "$description"
  else
    fail "$description"
  fi
}

# ===========================================================================
# Phase 1: v0 Regression Tests (standalone — starts/stops its own bridge)
# ===========================================================================

echo "==> Running v0 regression tests ..."
if ! bash scripts/test-v0.sh; then
  echo "==> ERROR: v0 regression tests failed"
  exit 1
fi
echo "==> v0 regression tests passed"
echo ""

# ===========================================================================
# Phase 2: v2-specific tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Start bridge server
# ---------------------------------------------------------------------------

echo "==> Starting bridge server ..."
$BRIDGE_CMD &
BRIDGE_PID=$!
echo "==> Bridge PID: $BRIDGE_PID"

# ---------------------------------------------------------------------------
# Wait for readiness — poll health endpoint
# ---------------------------------------------------------------------------

echo "==> Waiting for bridge to be ready (max ${MAX_RETRIES}s) ..."

ready=false
for i in $(seq 1 "$MAX_RETRIES"); do
  if curl -sf "${BASE_URL}/v1/health" > /dev/null 2>&1; then
    # Health responded — check if Copilot is connected
    health_status=$(curl -sf "${BASE_URL}/v1/health" | jq -r '.copilot // empty' 2>/dev/null || echo "")
    if [[ "$health_status" == "connected" ]]; then
      echo "==> Bridge ready after ${i}s (Copilot connected)"
      ready=true
      break
    fi
  fi
  sleep "$RETRY_INTERVAL"
done

if [[ "$ready" != "true" ]]; then
  echo "==> ERROR: Bridge did not become ready within ${MAX_RETRIES}s"
  exit 1
fi

# ---------------------------------------------------------------------------
# Test 1: Non-streaming chat completion (regression from v1)
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Non-streaming chat completion (regression) ---"

CHAT_BODY='{"model":"claude-sonnet-4","messages":[{"role":"user","content":"Say exactly: pong"}]}'

CHAT_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$CHAT_BODY")

CHAT_RESPONSE=$(curl -sf -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$CHAT_BODY")

assert "Non-streaming chat returns HTTP 200" \
  "[[ '$CHAT_HTTP_CODE' == '200' ]]"

assert "Non-streaming response object is chat.completion" \
  "echo '$CHAT_RESPONSE' | jq -e '.object == \"chat.completion\"'"

assert "Non-streaming response has assistant message" \
  "echo '$CHAT_RESPONSE' | jq -e '.choices[0].message.role == \"assistant\"'"

assert "Non-streaming response has non-empty content" \
  "echo '$CHAT_RESPONSE' | jq -e '(.choices[0].message.content | length) > 0'"

assert "Non-streaming response has finish_reason" \
  "echo '$CHAT_RESPONSE' | jq -e '.choices[0] | has(\"finish_reason\")'"

# ---------------------------------------------------------------------------
# Test 2: Streaming — Content-Type and SSE format
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Streaming — Content-Type and SSE format ---"

STREAM_BODY='{"model":"claude-sonnet-4","messages":[{"role":"user","content":"Say exactly: hello world"}],"stream":true}'

# Check that streaming returns text/event-stream content type
STREAM_CONTENT_TYPE=$(timeout 60 curl -N -s -o /dev/null -w "%{content_type}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$STREAM_BODY" 2>/dev/null || echo "")

assert "Streaming returns text/event-stream content type" \
  "[[ '$STREAM_CONTENT_TYPE' == *'text/event-stream'* ]]"

# Capture the full SSE stream output
STREAM_OUTPUT=$(timeout 60 curl -N -s -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$STREAM_BODY" 2>/dev/null || true)

# Verify data: prefix on lines
assert "SSE chunks have data: prefix" \
  "echo '$STREAM_OUTPUT' | grep -q '^data: '"

# ---------------------------------------------------------------------------
# Test 3: Streaming — First chunk has delta.role
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Streaming — First chunk has delta.role ---"

# Extract first data line (skip empty lines)
FIRST_DATA=$(echo "$STREAM_OUTPUT" | grep '^data: ' | head -n1 | sed 's/^data: //')

assert "First SSE chunk has delta.role = assistant" \
  "echo '$FIRST_DATA' | jq -e '.choices[0].delta.role == \"assistant\"'"

# ---------------------------------------------------------------------------
# Test 4: Streaming — Content chunks have delta.content
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Streaming — Content chunks ---"

# Find at least one chunk with non-null delta.content
HAS_CONTENT=$(echo "$STREAM_OUTPUT" | grep '^data: ' | grep -v '^\data: \[DONE\]' | while IFS= read -r line; do
  json="${line#data: }"
  content=$(echo "$json" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
  if [[ -n "$content" ]]; then
    echo "found"
    break
  fi
done)

assert "At least one chunk has delta.content with non-null content" \
  "[[ '$HAS_CONTENT' == 'found' ]]"

# ---------------------------------------------------------------------------
# Test 5: Streaming — Final chunk has finish_reason
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Streaming — Final chunk has finish_reason ---"

# Get all data lines except [DONE], take the last one
LAST_DATA=$(echo "$STREAM_OUTPUT" | grep '^data: ' | grep -v '^data: \[DONE\]' | tail -n1 | sed 's/^data: //')

assert "Final SSE chunk has non-null finish_reason" \
  "echo '$LAST_DATA' | jq -e '.choices[0].finish_reason != null'"

# ---------------------------------------------------------------------------
# Test 6: Streaming — Stream ends with [DONE]
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Streaming — Stream ends with [DONE] ---"

# Check that the last data line is [DONE]
LAST_LINE=$(echo "$STREAM_OUTPUT" | grep '^data: ' | tail -n1)

assert "Stream ends with data: [DONE]" \
  "[[ '$LAST_LINE' == 'data: [DONE]' ]]"

# ---------------------------------------------------------------------------
# Test 7: Streaming — HTTP status is 200
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Streaming — HTTP status ---"

STREAM_HTTP_CODE=$(timeout 60 curl -N -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$STREAM_BODY" 2>/dev/null || echo "")

assert "Streaming returns HTTP 200" \
  "[[ '$STREAM_HTTP_CODE' == '200' ]]"

# ---------------------------------------------------------------------------
# Test 8: Non-streaming still works after streaming (regression)
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Non-streaming after streaming (regression) ---"

REGRESSION_BODY='{"model":"claude-sonnet-4","messages":[{"role":"user","content":"Say exactly: pong"}]}'

REGRESSION_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$REGRESSION_BODY")

REGRESSION_RESPONSE=$(curl -sf -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$REGRESSION_BODY")

assert "Non-streaming still returns HTTP 200 after streaming" \
  "[[ '$REGRESSION_HTTP' == '200' ]]"

assert "Non-streaming still returns valid response after streaming" \
  "echo '$REGRESSION_RESPONSE' | jq -e '.choices[0].message.content | length > 0'"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

TOTAL=$((PASS_COUNT + FAIL_COUNT))

echo ""
echo "==========================================="
echo "  v2 Results: $PASS_COUNT/$TOTAL passed"
echo "==========================================="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "  $FAIL_COUNT test(s) FAILED"
  exit 1
else
  echo "  All tests passed!"
  exit 0
fi
