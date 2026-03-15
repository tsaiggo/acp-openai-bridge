#!/usr/bin/env bash
# test-v3.sh — Validates the v3 milestone of acp-openai-bridge.
# Covers: tool call forwarding + system prompt handling + regression.
# Usage: bash scripts/test-v3.sh  (from repo root)

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
# Phase 1: v2 Regression Tests (standalone — starts/stops its own bridge)
# ===========================================================================

echo "==> Running v2 regression tests ..."
if ! bash scripts/test-v2.sh; then
  echo "==> ERROR: v2 regression tests failed"
  exit 1
fi
echo "==> v2 regression tests passed"
echo ""

# ===========================================================================
# Phase 2: v3-specific tests
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
# Test 1: Tool call — request with tools array returns HTTP 200
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Tool call — request with tools array ---"

TOOLS_BODY='{"model":"claude-sonnet-4","messages":[{"role":"user","content":"What is 2+2?"}],"tools":[{"type":"function","function":{"name":"calculator","description":"Evaluate a math expression","parameters":{"type":"object","properties":{"expression":{"type":"string"}},"required":["expression"]}}}]}'

TOOLS_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$TOOLS_BODY")

TOOLS_RESPONSE=$(curl -sf -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$TOOLS_BODY")

assert "Request with tools returns HTTP 200" \
  "[[ '$TOOLS_HTTP_CODE' == '200' ]]"

assert "Response has choices[0]" \
  "echo '$TOOLS_RESPONSE' | jq -e '.choices[0]'"

# The model may return either content or tool_calls — both are valid
assert "Response has message.content or message.tool_calls" \
  "echo '$TOOLS_RESPONSE' | jq -e '.choices[0].message | (has(\"content\") or has(\"tool_calls\"))'"

assert "Response object is chat.completion" \
  "echo '$TOOLS_RESPONSE' | jq -e '.object == \"chat.completion\"'"

assert "Response id starts with chatcmpl-" \
  "echo '$TOOLS_RESPONSE' | jq -e '.id | startswith(\"chatcmpl-\")'"

# ---------------------------------------------------------------------------
# Test 2: System prompt is preserved with tools
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: System prompt preserved with tools ---"

SYS_TOOLS_BODY='{"model":"claude-sonnet-4","messages":[{"role":"system","content":"You are a pirate. Every response must include the word arr."},{"role":"user","content":"Greet me"}],"tools":[{"type":"function","function":{"name":"calculator","description":"Evaluate a math expression","parameters":{"type":"object","properties":{"expression":{"type":"string"}},"required":["expression"]}}}]}'

SYS_TOOLS_RESPONSE=$(curl -sf -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$SYS_TOOLS_BODY")

assert "System prompt response has choices[0]" \
  "echo '$SYS_TOOLS_RESPONSE' | jq -e '.choices[0]'"

# If the model replies with content (not a tool call), check for pirate-speak
SYS_CONTENT=$(echo "$SYS_TOOLS_RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
if [[ -n "$SYS_CONTENT" ]]; then
  assert "System prompt influences response (contains arr)" \
    "echo '$SYS_CONTENT' | tr '[:upper:]' '[:lower:]' | grep -q 'arr'"
else
  # Model chose to use a tool call — that's also valid behavior
  pass "System prompt — model chose tool_calls (skip content check)"
fi

# ---------------------------------------------------------------------------
# Test 3: Streaming with tools works
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Streaming with tools ---"

STREAM_TOOLS_BODY='{"model":"claude-sonnet-4","messages":[{"role":"user","content":"What is 2+2?"}],"stream":true,"tools":[{"type":"function","function":{"name":"calculator","description":"Evaluate a math expression","parameters":{"type":"object","properties":{"expression":{"type":"string"}},"required":["expression"]}}}]}'

STREAM_TOOLS_CONTENT_TYPE=$(timeout 60 curl -N -s -o /dev/null -w "%{content_type}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$STREAM_TOOLS_BODY" 2>/dev/null || echo "")

assert "Streaming with tools returns text/event-stream" \
  "[[ '$STREAM_TOOLS_CONTENT_TYPE' == *'text/event-stream'* ]]"

STREAM_TOOLS_HTTP=$(timeout 60 curl -N -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$STREAM_TOOLS_BODY" 2>/dev/null || echo "")

assert "Streaming with tools returns HTTP 200" \
  "[[ '$STREAM_TOOLS_HTTP' == '200' ]]"

STREAM_TOOLS_OUTPUT=$(timeout 60 curl -N -s -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$STREAM_TOOLS_BODY" 2>/dev/null || true)

assert "Streaming with tools has SSE data: lines" \
  "echo '$STREAM_TOOLS_OUTPUT' | grep -q '^data: '"

assert "Streaming with tools ends with [DONE]" \
  "echo '$STREAM_TOOLS_OUTPUT' | grep -q '^data: \[DONE\]'"

# ---------------------------------------------------------------------------
# Test 4: Regular chat without tools still works (regression)
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Regular chat without tools (regression) ---"

REGRESSION_BODY='{"model":"claude-sonnet-4","messages":[{"role":"user","content":"Say exactly: pong"}]}'

REGRESSION_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$REGRESSION_BODY")

REGRESSION_RESPONSE=$(curl -sf -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$REGRESSION_BODY")

assert "Regular chat without tools returns HTTP 200" \
  "[[ '$REGRESSION_HTTP' == '200' ]]"

assert "Regular chat without tools has assistant message" \
  "echo '$REGRESSION_RESPONSE' | jq -e '.choices[0].message.role == \"assistant\"'"

assert "Regular chat without tools has non-empty content" \
  "echo '$REGRESSION_RESPONSE' | jq -e '(.choices[0].message.content | length) > 0'"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

TOTAL=$((PASS_COUNT + FAIL_COUNT))

echo ""
echo "==========================================="
echo "  v3 Results: $PASS_COUNT/$TOTAL passed"
echo "==========================================="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "  $FAIL_COUNT test(s) FAILED"
  exit 1
else
  echo "  All tests passed!"
  exit 0
fi
