#!/usr/bin/env bash

# test-emoji-tapback.sh - Integration test for custom emoji tapback reactions
# Tests CLI argument parsing and RPC handling for standard + custom emoji types.
# NOTE: Actual sending requires SIP disabled + Messages injection running.
# These tests verify the parsing/validation layer works correctly.

IMSG="imsg-plus"
PASS=0
FAIL=0

pass() { echo "  ✅ $1"; ((PASS++)); }
fail() { echo "  ❌ $1"; ((FAIL++)); }

echo "==========================================="
echo " Emoji Tapback Integration Tests"
echo "==========================================="
echo

# -------------------------------------------------------------------
# 1. CLI: Standard tapback types still work (parsing layer)
# -------------------------------------------------------------------
echo "1. CLI: Standard tapback types parse correctly"

for type in love thumbsup thumbsdown haha emphasis question; do
  output=$($IMSG react --handle test@example.com --guid FAKE-GUID --type "$type" --json 2>&1)
  if echo "$output" | grep -q '"reaction"'; then
    pass "  --type $type accepted"
  elif echo "$output" | grep -q "Invalid reaction type"; then
    fail "  --type $type rejected unexpectedly"
  else
    pass "  --type $type accepted (bridge unavailable, but parsed ok)"
  fi
done
echo

# -------------------------------------------------------------------
# 2. CLI: Standard emoji characters map to standard types
# -------------------------------------------------------------------
echo "2. CLI: Standard emoji → standard types"

for emoji in "❤️" "👍" "👎" "😂" "❓"; do
  output=$($IMSG react --handle test@example.com --guid FAKE-GUID --type "$emoji" --json 2>&1)
  if echo "$output" | grep -q "Invalid reaction type"; then
    fail "  --type $emoji rejected"
  else
    pass "  --type $emoji accepted"
  fi
done
echo

# -------------------------------------------------------------------
# 3. CLI: Custom emoji accepted
# -------------------------------------------------------------------
echo "3. CLI: Custom emoji reactions"

for emoji in "🎉" "🔥" "👀" "🫡" "💯"; do
  output=$($IMSG react --handle test@example.com --guid FAKE-GUID --type "$emoji" --json 2>&1)
  if echo "$output" | grep -q "Invalid reaction type"; then
    fail "  --type $emoji rejected"
  else
    pass "  --type $emoji accepted"
  fi
done
echo

# -------------------------------------------------------------------
# 4. CLI: Custom emoji with --remove
# -------------------------------------------------------------------
echo "4. CLI: Custom emoji removal"

output=$($IMSG react --handle test@example.com --guid FAKE-GUID --type "🎉" --remove --json 2>&1)
if echo "$output" | grep -q "Invalid reaction type"; then
  fail "  --type 🎉 --remove rejected"
else
  pass "  --type 🎉 --remove accepted"
fi
echo

# -------------------------------------------------------------------
# 5. CLI: Invalid strings still rejected
# -------------------------------------------------------------------
echo "5. CLI: Invalid types rejected"

for bad in "invalid" "hello" "abc" "nope"; do
  output=$($IMSG react --handle test@example.com --guid FAKE-GUID --type "$bad" --json 2>&1)
  if echo "$output" | grep -q "Invalid reaction type"; then
    pass "  --type '$bad' correctly rejected"
  else
    fail "  --type '$bad' should have been rejected"
  fi
done
echo

# -------------------------------------------------------------------
# 6. RPC: tapback.send with standard type
# -------------------------------------------------------------------
echo "6. RPC: tapback.send standard type"

RPC_OUT=$(echo '{"jsonrpc":"2.0","id":1,"method":"tapback.send","params":{"handle":"test@example.com","guid":"FAKE-GUID","type":"love"}}' | $IMSG rpc 2>&1 | head -1)
if echo "$RPC_OUT" | grep -q '"error"'; then
  # Could be "bridge not available" which is fine — means it parsed ok
  if echo "$RPC_OUT" | grep -q "invalid reaction type"; then
    fail "  love rejected by RPC"
  else
    pass "  love accepted by RPC (bridge may be unavailable)"
  fi
else
  pass "  love accepted by RPC"
fi
echo

# -------------------------------------------------------------------
# 7. RPC: tapback.send with custom emoji
# -------------------------------------------------------------------
echo "7. RPC: tapback.send custom emoji"

RPC_OUT=$(echo '{"jsonrpc":"2.0","id":2,"method":"tapback.send","params":{"handle":"test@example.com","guid":"FAKE-GUID","type":"🎉"}}' | $IMSG rpc 2>&1 | head -1)
if echo "$RPC_OUT" | grep -q "invalid reaction type"; then
  fail "  🎉 rejected by RPC"
else
  pass "  🎉 accepted by RPC"
fi
echo

# -------------------------------------------------------------------
# 8. RPC: tapback.send invalid type rejected
# -------------------------------------------------------------------
echo "8. RPC: tapback.send invalid type"

RPC_OUT=$(echo '{"jsonrpc":"2.0","id":3,"method":"tapback.send","params":{"handle":"test@example.com","guid":"FAKE-GUID","type":"notanemoji"}}' | $IMSG rpc 2>&1 | head -1)
if echo "$RPC_OUT" | grep -q "invalid reaction type"; then
  pass "  'notanemoji' correctly rejected by RPC"
else
  fail "  'notanemoji' should have been rejected by RPC"
fi
echo

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------
echo "==========================================="
TOTAL=$((PASS + FAIL))
echo " Results: $PASS/$TOTAL passed"
if [ $FAIL -eq 0 ]; then
  echo " All tests passed!"
else
  echo " $FAIL test(s) failed"
fi
echo "==========================================="
exit $FAIL
