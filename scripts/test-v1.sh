#!/usr/bin/env bash
# test-v1.sh — Validates the v1 milestone of acp-openai-bridge.
# Covers: non-streaming chat completions + error handling.
# Usage: bash scripts/test-v1.sh  (from repo root)

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
# Phase 2: v1-specific tests
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
# Test 1: Happy path — Simple chat completion
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Happy path — Simple chat completion ---"

CHAT_BODY='{"model":"claude-sonnet-4","messages":[{"role":"user","content":"Say exactly: pong"}]}'

CHAT_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$CHAT_BODY")

CHAT_RESPONSE=$(curl -sf -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$CHAT_BODY")

assert "Chat completion returns HTTP 200" \
  "[[ '$CHAT_HTTP_CODE' == '200' ]]"

assert "Response object is chat.completion" \
  "echo '$CHAT_RESPONSE' | jq -e '.object == \"chat.completion\"'"

assert "Response choices[0].message.role is assistant" \
  "echo '$CHAT_RESPONSE' | jq -e '.choices[0].message.role == \"assistant\"'"

assert "Response choices[0].message.content is non-empty" \
  "echo '$CHAT_RESPONSE' | jq -e '(.choices[0].message.content | length) > 0'"

assert "Response choices[0].finish_reason exists" \
  "echo '$CHAT_RESPONSE' | jq -e '.choices[0] | has(\"finish_reason\")'"

assert "Response id starts with chatcmpl-" \
  "echo '$CHAT_RESPONSE' | jq -e '.id | startswith(\"chatcmpl-\")'"

assert "Response created is a number" \
  "echo '$CHAT_RESPONSE' | jq -e '.created | type == \"number\"'"

assert "Response model matches request model" \
  "echo '$CHAT_RESPONSE' | jq -e '.model == \"claude-sonnet-4\"'"

# ---------------------------------------------------------------------------
# Test 2: System prompt honored
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: System prompt honored ---"

SYS_BODY='{"model":"claude-sonnet-4","messages":[{"role":"system","content":"You are a pirate. Every response must include the word arr."},{"role":"user","content":"Greet me"}]}'

SYS_RESPONSE=$(curl -sf -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "$SYS_BODY")

assert "System prompt response contains arr" \
  "echo '$SYS_RESPONSE' | jq -r '.choices[0].message.content' | tr '[:upper:]' '[:lower:]' | grep -q 'arr'"

# ---------------------------------------------------------------------------
# Test 3: Error — invalid model
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Error — invalid model ---"

INVALID_MODEL_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d '{"model":"nonexistent-model","messages":[{"role":"user","content":"hi"}]}')

INVALID_MODEL_BODY=$(curl -s -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d '{"model":"nonexistent-model","messages":[{"role":"user","content":"hi"}]}')

assert "Invalid model returns HTTP 400" \
  "[[ '$INVALID_MODEL_HTTP' == '400' ]]"

assert "Invalid model returns invalid_request_error type" \
  "echo '$INVALID_MODEL_BODY' | jq -e '.error.type == \"invalid_request_error\"'"

assert "Invalid model returns param model" \
  "echo '$INVALID_MODEL_BODY' | jq -e '.error.param == \"model\"'"

# ---------------------------------------------------------------------------
# Test 4: Error — missing model field
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Error — missing model field ---"

MISSING_MODEL_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"hi"}]}')

MISSING_MODEL_BODY=$(curl -s -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d '{"messages":[{"role":"user","content":"hi"}]}')

assert "Missing model returns HTTP 400" \
  "[[ '$MISSING_MODEL_HTTP' == '400' ]]"

assert "Missing model returns param model" \
  "echo '$MISSING_MODEL_BODY' | jq -e '.error.param == \"model\"'"

# ---------------------------------------------------------------------------
# Test 5: Error — invalid JSON
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Error — invalid JSON ---"

INVALID_JSON_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d 'not-json')

INVALID_JSON_BODY=$(curl -s -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d 'not-json')

assert "Invalid JSON returns HTTP 400" \
  "[[ '$INVALID_JSON_HTTP' == '400' ]]"

assert "Invalid JSON returns invalid_request_error type" \
  "echo '$INVALID_JSON_BODY' | jq -e '.error.type == \"invalid_request_error\"'"

# ---------------------------------------------------------------------------
# Test 6: Error — empty messages
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Error — empty messages ---"

EMPTY_MSG_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d '{"model":"claude-sonnet-4","messages":[]}')

EMPTY_MSG_BODY=$(curl -s -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d '{"model":"claude-sonnet-4","messages":[]}')

assert "Empty messages returns HTTP 400" \
  "[[ '$EMPTY_MSG_HTTP' == '400' ]]"

assert "Empty messages returns param messages" \
  "echo '$EMPTY_MSG_BODY' | jq -e '.error.param == \"messages\"'"

# ---------------------------------------------------------------------------
# Test 7: Error — stream:true → 501
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: Error — stream:true not implemented ---"

STREAM_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d '{"model":"claude-sonnet-4","messages":[{"role":"user","content":"hi"}],"stream":true}')

STREAM_BODY=$(curl -s -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d '{"model":"claude-sonnet-4","messages":[{"role":"user","content":"hi"}],"stream":true}')

assert "stream:true returns HTTP 501" \
  "[[ '$STREAM_HTTP' == '501' ]]"

assert "stream:true returns not_implemented type" \
  "echo '$STREAM_BODY' | jq -e '.error.type == \"not_implemented\"'"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

TOTAL=$((PASS_COUNT + FAIL_COUNT))

echo ""
echo "==========================================="
echo "  v1 Results: $PASS_COUNT/$TOTAL passed"
echo "==========================================="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "  $FAIL_COUNT test(s) FAILED"
  exit 1
else
  echo "  All tests passed!"
  exit 0
fi
