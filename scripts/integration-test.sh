#!/bin/bash
#
# Integration test for imsg-plus features:
#   - Bridge-first sends (plain text, attachments, effects, thread replies)
#   - Edit, unsend
#   - AppleScript fallback
#   - RPC smoke tests
#
# Requires: SIP disabled, dylib injected, Messages.app running.
#
set -euo pipefail

# Source .env from repo root if it exists
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO_ROOT/.env" ] && source "$REPO_ROOT/.env"

TARGET="${IMSG_TEST_TARGET:?Set IMSG_TEST_TARGET to a phone number or email}"
IMSG="imsg-plus"
LOG="/tmp/imsg-integration-test.log"
TEST_FILE="/tmp/imsg-test-attachment.txt"
TEST_IMG="/tmp/imsg-test-attachment.png"
PASS=0
FAIL=0
SKIP=0

: > "$LOG"

log() { echo "=== $1 ===" | tee -a "$LOG"; }
record() { echo "$1" | tee -a "$LOG"; }
pass() { record "PASS: $1"; PASS=$((PASS + 1)); }
fail() { record "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { record "SKIP: $1"; SKIP=$((SKIP + 1)); }

# Create test attachment files
echo "imsg-plus integration test file $(date)" > "$TEST_FILE"
# Create a small 1x1 red PNG (68 bytes)
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82' > "$TEST_IMG"

# Find chat ID for the target number
log "Step 0: Find chat ID for $TARGET"
CHAT_JSON=$($IMSG history --chat-id 0 --limit 1 --json 2>/dev/null || true)

# Get chat list and find the right chat
CHATS_JSON=$($IMSG chats --limit 50 --json 2>/dev/null)
CHAT_ID=$(echo "$CHATS_JSON" | jq -r --arg t "$TARGET" 'select(.identifier == $t or (.participants // [] | index($t) != null)) | .id // empty' | head -1)

if [ -z "$CHAT_ID" ]; then
  # Try finding via identifier containing the number
  CHAT_ID=$(echo "$CHATS_JSON" | jq -r --arg t "$TARGET" 'select(.identifier | test($t)) | .id // empty' | head -1)
fi

if [ -z "$CHAT_ID" ]; then
  record "WARNING: Could not find chat ID for $TARGET, will use --to for sends and search history after"
  CHAT_ID=""
fi
record "Chat ID: ${CHAT_ID:-not found}"

# --- Test 0b: Check bridge status ---
log "Step 0b: Verify bridge status"
BRIDGE_STATUS=$(echo '{"jsonrpc":"2.0","id":0,"method":"bridge.status"}' | $IMSG rpc 2>/dev/null | head -1)
record "Bridge status: $BRIDGE_STATUS"

BRIDGE_INJECTED=$(echo "$BRIDGE_STATUS" | jq -r '.result.injected // empty')
ATTACH_AVAILABLE=$(echo "$BRIDGE_STATUS" | jq -r '.result.attachment_send_available // empty')
if [ "$BRIDGE_INJECTED" = "true" ]; then
  pass "Bridge injected"
else
  fail "Bridge not injected — bridge-first tests will fail"
fi
if [ "$ATTACH_AVAILABLE" = "true" ]; then
  pass "Attachment send available (IMFileTransferCenter present)"
else
  record "NOTE: attachment_send_available=$ATTACH_AVAILABLE — attachment tests may fail"
fi

# --- Test 1: Send a base message (bridge-first plain text) ---
log "Step 1: Send base message (bridge-first plain text)"
SEND1_OUT=$($IMSG send --to "$TARGET" --text "integration-test-base-$(date +%s)" --json 2>&1 || true)
record "Send result: $SEND1_OUT"
if echo "$SEND1_OUT" | jq -e '.status == "sent"' >/dev/null 2>&1; then
  pass "Plain text send via bridge"
else
  fail "Plain text send: $SEND1_OUT"
fi
sleep 3

# Get the GUID of the message we just sent
log "Step 1b: Get GUID of base message from history"
if [ -n "$CHAT_ID" ]; then
  HISTORY=$($IMSG history --chat-id "$CHAT_ID" --limit 3 --json 2>/dev/null)
else
  # Find the chat by listing recent chats
  CHATS_JSON=$($IMSG chats --limit 10 --json 2>/dev/null)
  CHAT_ID=$(echo "$CHATS_JSON" | jq -r --arg t "$TARGET" 'select(.identifier | test($t; "i")) | .id // empty' | head -1)
  if [ -z "$CHAT_ID" ]; then
    CHAT_ID=$(echo "$CHATS_JSON" | jq -r --arg t "$TARGET" 'select(.participants != null) | select(.participants[] | test($t; "i")) | .id' | head -1)
  fi
  record "Resolved Chat ID: ${CHAT_ID:-STILL NOT FOUND}"
  if [ -z "$CHAT_ID" ]; then
    record "FATAL: Cannot find chat for $TARGET. Listing all chats:"
    echo "$CHATS_JSON" | jq '.' | tee -a "$LOG"
    exit 1
  fi
  HISTORY=$($IMSG history --chat-id "$CHAT_ID" --limit 3 --json 2>/dev/null)
fi

BASE_GUID=$(echo "$HISTORY" | jq -r 'select(.is_from_me == true and (.text | test("integration-test-base"))) | .guid' | head -1)
record "Base message GUID: ${BASE_GUID:-NOT FOUND}"
record "Recent history:"
echo "$HISTORY" | jq '{guid, text, is_from_me, reply_to_guid, is_edited, date_edited, reply_to_part}' | tee -a "$LOG"

if [ -z "$BASE_GUID" ]; then
  record "WARNING: Could not find base message GUID. Using most recent from-me message."
  BASE_GUID=$(echo "$HISTORY" | jq -r 'select(.is_from_me == true) | .guid' | head -1)
  record "Fallback GUID: ${BASE_GUID:-NONE}"
fi

# --- Test 2: Send thread reply ---
log "Step 2: Send thread reply to GUID $BASE_GUID"
if [ -n "$BASE_GUID" ]; then
  REPLY_OUT=$($IMSG send --to "$TARGET" --text "integration-test-reply-$(date +%s)" --reply-to "$BASE_GUID" --json 2>&1 || true)
  record "Reply result: $REPLY_OUT"
  if echo "$REPLY_OUT" | jq -e '.status == "sent"' >/dev/null 2>&1; then
    pass "Thread reply send"
  else
    fail "Thread reply: $REPLY_OUT"
  fi
  sleep 3
else
  skip "Thread reply (no base GUID)"
fi

# --- Test 3: Send a message then edit it ---
log "Step 3: Send message to edit"
EDIT_TS=$(date +%s)
EDIT_OUT=$($IMSG send --to "$TARGET" --text "integration-test-before-edit-$EDIT_TS" --json 2>&1 || true)
record "Send for edit: $EDIT_OUT"
sleep 3

log "Step 3b: Get GUID of message to edit"
HISTORY=$($IMSG history --chat-id "$CHAT_ID" --limit 5 --json 2>/dev/null)
EDIT_GUID=$(echo "$HISTORY" | jq -r --arg ts "$EDIT_TS" 'select(.is_from_me == true and (.text | test("before-edit-" + $ts))) | .guid' | head -1)
record "Edit target GUID: ${EDIT_GUID:-NOT FOUND}"

if [ -n "$EDIT_GUID" ]; then
  log "Step 3c: Edit message"
  HANDLE="$TARGET"
  EDIT_RESULT=$($IMSG edit --handle "$HANDLE" --guid "$EDIT_GUID" --text "integration-test-EDITED-$EDIT_TS" --json 2>&1 || true)
  record "Edit result: $EDIT_RESULT"
  if echo "$EDIT_RESULT" | jq -e '.action == "edited"' >/dev/null 2>&1; then
    pass "Edit message"
  else
    fail "Edit message: $EDIT_RESULT"
  fi
  sleep 3
else
  skip "Edit message (no GUID)"
fi

# --- Test 4: Send a message then unsend it ---
log "Step 4: Send message to unsend"
UNSEND_TS=$(date +%s)
UNSEND_OUT=$($IMSG send --to "$TARGET" --text "integration-test-will-unsend-$UNSEND_TS" --json 2>&1 || true)
record "Send for unsend: $UNSEND_OUT"
sleep 3

log "Step 4b: Get GUID of message to unsend"
HISTORY=$($IMSG history --chat-id "$CHAT_ID" --limit 5 --json 2>/dev/null)
UNSEND_GUID=$(echo "$HISTORY" | jq -r --arg ts "$UNSEND_TS" 'select(.is_from_me == true and (.text | test("will-unsend-" + $ts))) | .guid' | head -1)
record "Unsend target GUID: ${UNSEND_GUID:-NOT FOUND}"

if [ -n "$UNSEND_GUID" ]; then
  log "Step 4c: Unsend message"
  UNSEND_RESULT=$($IMSG edit --handle "$TARGET" --guid "$UNSEND_GUID" --unsend --json 2>&1 || true)
  record "Unsend result: $UNSEND_RESULT"
  if echo "$UNSEND_RESULT" | jq -e '.action == "unsent"' >/dev/null 2>&1; then
    pass "Unsend message"
  else
    fail "Unsend message: $UNSEND_RESULT"
  fi
  sleep 3
else
  skip "Unsend message (no GUID)"
fi

# --- Test 4b: Standalone effect (no attachment) ---
log "Step 4b: Send standalone effect (balloons, no attachment)"
EFFECT_OUT=$($IMSG send --to "$TARGET" --text "integration-test-effect-$(date +%s)" --effect balloons --json 2>&1 || true)
record "Standalone effect result: $EFFECT_OUT"
if echo "$EFFECT_OUT" | jq -e '.status == "sent"' >/dev/null 2>&1; then
  pass "Standalone effect send (balloons)"
else
  fail "Standalone effect send: $EFFECT_OUT"
fi
sleep 3

# --- Test 4c: Standalone effect (slam bubble) ---
log "Step 4c: Send standalone bubble effect (slam)"
EFFECT2_OUT=$($IMSG send --to "$TARGET" --text "integration-test-slam-$(date +%s)" --effect slam --json 2>&1 || true)
record "Slam effect result: $EFFECT2_OUT"
if echo "$EFFECT2_OUT" | jq -e '.status == "sent"' >/dev/null 2>&1; then
  pass "Standalone effect send (slam)"
else
  fail "Standalone effect send (slam): $EFFECT2_OUT"
fi
sleep 3

# --- Test 5: Attachment only via bridge ---
log "Step 5: Send attachment only (no text)"
ATTACH1_OUT=$($IMSG send --to "$TARGET" --file "$TEST_IMG" --json 2>&1 || true)
record "Attachment-only result: $ATTACH1_OUT"
if echo "$ATTACH1_OUT" | jq -e '.status == "sent"' >/dev/null 2>&1; then
  pass "Attachment-only send via bridge"
else
  fail "Attachment-only send: $ATTACH1_OUT"
fi
sleep 3

# --- Test 6: Text + attachment via bridge ---
log "Step 6: Send text + attachment"
ATTACH2_OUT=$($IMSG send --to "$TARGET" --text "integration-test-text-and-file-$(date +%s)" --file "$TEST_FILE" --json 2>&1 || true)
record "Text+attachment result: $ATTACH2_OUT"
if echo "$ATTACH2_OUT" | jq -e '.status == "sent"' >/dev/null 2>&1; then
  pass "Text + attachment send via bridge"
else
  fail "Text + attachment send: $ATTACH2_OUT"
fi
sleep 3

# --- Test 7: Effect + attachment via bridge ---
log "Step 7: Send effect + attachment"
ATTACH3_OUT=$($IMSG send --to "$TARGET" --text "integration-test-effect-file-$(date +%s)" --file "$TEST_IMG" --effect balloons --json 2>&1 || true)
record "Effect+attachment result: $ATTACH3_OUT"
if echo "$ATTACH3_OUT" | jq -e '.status == "sent"' >/dev/null 2>&1; then
  pass "Effect + attachment send via bridge"
elif echo "$ATTACH3_OUT" | jq -e '.effect == "balloons"' >/dev/null 2>&1; then
  pass "Effect + attachment send via bridge"
else
  fail "Effect + attachment send: $ATTACH3_OUT"
fi
sleep 3

# --- Test 8: Thread reply + attachment ---
log "Step 8: Send thread reply + attachment"
if [ -n "$BASE_GUID" ]; then
  ATTACH4_OUT=$($IMSG send --to "$TARGET" --text "integration-test-reply-file-$(date +%s)" --file "$TEST_FILE" --reply-to "$BASE_GUID" --json 2>&1 || true)
  record "Reply+attachment result: $ATTACH4_OUT"
  if echo "$ATTACH4_OUT" | jq -e '.status == "sent"' >/dev/null 2>&1; then
    pass "Thread reply + attachment send"
  else
    fail "Thread reply + attachment: $ATTACH4_OUT"
  fi
  sleep 3
else
  skip "Thread reply + attachment (no base GUID)"
fi

# --- Test 8b: Standalone markdown (no attachment) ---
log "Step 8b: Send standalone markdown (bold + italic, no attachment)"
MD_OUT=$($IMSG send --to "$TARGET" --text "**bold text** and *italic text*" --markdown --json 2>&1 || true)
record "Standalone markdown result: $MD_OUT"
if echo "$MD_OUT" | jq -e '.status == "sent"' >/dev/null 2>&1; then
  pass "Standalone markdown send"
else
  fail "Standalone markdown send: $MD_OUT"
fi
sleep 3

# --- Test 9: Markdown + attachment ---
log "Step 9: Send markdown + attachment"
ATTACH5_OUT=$($IMSG send --to "$TARGET" --text "**bold** and *italic* with file" --file "$TEST_FILE" --markdown --json 2>&1 || true)
record "Markdown+attachment result: $ATTACH5_OUT"
if echo "$ATTACH5_OUT" | jq -e '.status == "sent"' >/dev/null 2>&1; then
  pass "Markdown + attachment send via bridge"
else
  fail "Markdown + attachment send: $ATTACH5_OUT"
fi
sleep 3

# --- Test 10: Dump final history showing enriched fields ---
log "Step 10: Final history dump (checking enriched fields)"
FINAL=$($IMSG history --chat-id "$CHAT_ID" --limit 15 --json 2>/dev/null)
echo "$FINAL" | jq '{guid, text, is_from_me, reply_to_guid, reply_to_part, is_edited, date_edited, created_at}' | tee -a "$LOG"

# --- Test 11: RPC smoke tests ---
log "Step 11: RPC smoke tests"

# message.edit without handle (should error)
RPC_EDIT_ERR=$(echo '{"jsonrpc":"2.0","id":1,"method":"message.edit","params":{"guid":"ABC","text":"new"}}' | $IMSG rpc 2>/dev/null | head -1)
record "RPC edit missing handle: $RPC_EDIT_ERR"
if echo "$RPC_EDIT_ERR" | jq -e '.error' >/dev/null 2>&1; then
  pass "RPC edit rejects missing handle"
else
  fail "RPC edit missing handle: expected error"
fi

# message.unsend without guid (should error)
RPC_UNSEND_ERR=$(echo '{"jsonrpc":"2.0","id":2,"method":"message.unsend","params":{"handle":"+123"}}' | $IMSG rpc 2>/dev/null | head -1)
record "RPC unsend missing guid: $RPC_UNSEND_ERR"
if echo "$RPC_UNSEND_ERR" | jq -e '.error' >/dev/null 2>&1; then
  pass "RPC unsend rejects missing guid"
else
  fail "RPC unsend missing guid: expected error"
fi

# RPC send with file param (text + attachment via RPC)
log "Step 11b: RPC send with file param"
RPC_FILE=$(echo '{"jsonrpc":"2.0","id":4,"method":"send","params":{"to":"'"$TARGET"'","text":"rpc-file-test-'"$(date +%s)"'","file":"'"$TEST_FILE"'"}}' | $IMSG rpc 2>/dev/null | head -1)
record "RPC send with file: $RPC_FILE"
if echo "$RPC_FILE" | jq -e '.result.ok == true' >/dev/null 2>&1; then
  pass "RPC send with file param"
else
  fail "RPC send with file: $RPC_FILE"
fi
sleep 3

# RPC send attachment only (no text)
log "Step 11c: RPC send attachment only"
RPC_FILE_ONLY=$(echo '{"jsonrpc":"2.0","id":5,"method":"send","params":{"to":"'"$TARGET"'","file":"'"$TEST_IMG"'"}}' | $IMSG rpc 2>/dev/null | head -1)
record "RPC send file only: $RPC_FILE_ONLY"
if echo "$RPC_FILE_ONLY" | jq -e '.result.ok == true' >/dev/null 2>&1; then
  pass "RPC send attachment only"
else
  fail "RPC send attachment only: $RPC_FILE_ONLY"
fi
sleep 3

# RPC send with reply_to_guid to fake guid (should error - message not found)
RPC_REPLY=$(echo '{"jsonrpc":"2.0","id":6,"method":"send","params":{"to":"'"$TARGET"'","text":"rpc-reply-test","reply_to_guid":"fake-guid"}}' | $IMSG rpc 2>/dev/null | head -1)
record "RPC send with fake reply_to_guid: $RPC_REPLY"
if echo "$RPC_REPLY" | jq -e '.error' >/dev/null 2>&1; then
  pass "RPC send rejects fake reply_to_guid"
elif echo "$RPC_REPLY" | jq -e '.result.ok == true' >/dev/null 2>&1; then
  pass "RPC send with reply_to_guid (bridge accepted)"
else
  fail "RPC send with reply_to_guid: unexpected response"
fi

# --- Test 12: AppleScript fallback ---
log "Step 12: AppleScript fallback (kill Messages, send without bridge)"
record "Killing Messages.app to test fallback..."
killall Messages 2>/dev/null || true
sleep 2

FALLBACK_OUT=$($IMSG send --to "$TARGET" --text "integration-test-fallback-$(date +%s)" --json 2>&1 || true)
record "Fallback result: $FALLBACK_OUT"
if echo "$FALLBACK_OUT" | jq -e '.status == "sent"' >/dev/null 2>&1; then
  pass "AppleScript fallback send (bridge unavailable)"
else
  # AppleScript send prints "sent" to stdout, not JSON — check for that
  if echo "$FALLBACK_OUT" | grep -q '"status":"sent"'; then
    pass "AppleScript fallback send (bridge unavailable)"
  else
    fail "AppleScript fallback: $FALLBACK_OUT"
  fi
fi
sleep 3

# Relaunch Messages with injection so subsequent manual tests work
record "Relaunching Messages.app with injection..."
$IMSG launch 2>/dev/null &
sleep 5

# --- Cleanup ---
rm -f "$TEST_FILE" "$TEST_IMG"

# --- Summary ---
log "SUMMARY"
TOTAL=$((PASS + FAIL + SKIP))
record "Total: $TOTAL  Pass: $PASS  Fail: $FAIL  Skip: $SKIP"
if [ "$FAIL" -gt 0 ]; then
  record "❌ SOME TESTS FAILED"
else
  record "✅ ALL TESTS PASSED"
fi
record "Full log at $LOG"

exit "$FAIL"
