#!/usr/bin/env bash
# test-v0.sh — Validates the v0 milestone of acp-openai-bridge.
# Usage: bash scripts/test-v0.sh  (from repo root)

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
# Test 1: GET /v1/health
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: GET /v1/health ---"

HEALTH_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/v1/health")
HEALTH_BODY=$(curl -sf "${BASE_URL}/v1/health")

assert "Health endpoint returns HTTP 200" \
  "[[ '$HEALTH_HTTP_CODE' == '200' ]]"

assert "Health endpoint returns status ok" \
  "echo '$HEALTH_BODY' | jq -e '.status == \"ok\"'"

assert "Health endpoint returns copilot connected" \
  "echo '$HEALTH_BODY' | jq -e '.copilot == \"connected\"'"

# ---------------------------------------------------------------------------
# Test 2: GET /v1/models
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: GET /v1/models ---"

MODELS_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/v1/models")
MODELS_BODY=$(curl -sf "${BASE_URL}/v1/models")

assert "Models endpoint returns HTTP 200" \
  "[[ '$MODELS_HTTP_CODE' == '200' ]]"

assert "Models endpoint returns object list" \
  "echo '$MODELS_BODY' | jq -e '.object == \"list\"'"

assert "Models endpoint returns non-empty data array" \
  "echo '$MODELS_BODY' | jq -e '(.data | length) > 0'"

# Validate structure of each model in the data array
assert "Each model has id field" \
  "echo '$MODELS_BODY' | jq -e '[.data[] | has(\"id\")] | all'"

assert "Each model has object field equal to model" \
  "echo '$MODELS_BODY' | jq -e '[.data[] | .object == \"model\"] | all'"

assert "Each model has created field" \
  "echo '$MODELS_BODY' | jq -e '[.data[] | has(\"created\")] | all'"

assert "Each model has owned_by field" \
  "echo '$MODELS_BODY' | jq -e '[.data[] | has(\"owned_by\")] | all'"

# ---------------------------------------------------------------------------
# Test 3: Invalid route — GET /v1/nonexistent
# ---------------------------------------------------------------------------

echo ""
echo "--- Test: GET /v1/nonexistent ---"

NOTFOUND_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/v1/nonexistent")
NOTFOUND_BODY=$(curl -s "${BASE_URL}/v1/nonexistent")

assert "Unknown route returns HTTP 404" \
  "[[ '$NOTFOUND_HTTP_CODE' == '404' ]]"

assert "Unknown route returns not_found_error type" \
  "echo '$NOTFOUND_BODY' | jq -e '.error.type == \"not_found_error\"'"

assert "Unknown route returns code 404 in body" \
  "echo '$NOTFOUND_BODY' | jq -e '.error.code == 404'"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

TOTAL=$((PASS_COUNT + FAIL_COUNT))

echo ""
echo "==========================================="
echo "  Results: $PASS_COUNT/$TOTAL passed"
echo "==========================================="

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "  $FAIL_COUNT test(s) FAILED"
  exit 1
else
  echo "  All tests passed!"
  exit 0
fi
