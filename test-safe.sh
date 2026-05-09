#!/bin/bash

# test-safe.sh - Safe testing of imsg-plus features without sending real messages

IMSG="./.build/release/imsg"

echo "==================================="
echo "imsg-plus Safe Test Suite"
echo "==================================="
echo

echo "1. Testing help output for new commands..."
echo "----------------------------------------"
$IMSG typing --help 2>/dev/null | head -10
echo
$IMSG react --help 2>/dev/null | head -15
echo

echo "2. Testing argument validation..."
echo "----------------------------------------"
echo "Invalid state (should error):"
$IMSG typing --handle test@example.com --state invalid 2>&1 | grep -i "error\|must be"
echo
echo "Missing required args (should error):"
$IMSG react --handle test@example.com 2>&1 | grep -i "required"
echo

echo "3. Testing status command..."
echo "----------------------------------------"
$IMSG status
echo

echo "4. Testing JSON output format..."
echo "----------------------------------------"
$IMSG status --json | python3 -m json.tool
echo

echo "5. Checking that basic commands still work..."
echo "----------------------------------------"
echo "Listing chats (first 3):"
$IMSG chats --limit 3
echo

echo "==================================="
echo "Safe tests complete!"
echo "==================================="
echo
echo "To actually test the features:"
echo "1. Find a real chat ID: imsg chats"
echo "2. Get a message GUID: imsg history --chat-id <ID> --limit 5"
echo "3. Try typing: imsg typing --handle <phone> --state on"
echo "   (Will show 'not fully implemented' due to Swift/ObjC bridging limits)"
echo
echo "Note: Sends and advanced actions require the injected Objective-C bridge."
