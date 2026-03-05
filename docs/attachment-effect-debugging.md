# Attachment + Effect Implementation: Debugging Notes

## Problem

Sending file attachments with effects (confetti, slam, etc.) or rich text formatting (bold, italic)
via the IMCore bridge resulted in the effect/formatting being silently stripped. The attachment would
arrive but without any effect. Standalone effects (no attachment) and standalone formatting worked
fine.

## Root Causes Found

### 1. Messages.app Sandbox Blocks File Operations

The dylib runs inside Messages.app's sandbox. `NSHomeDirectory()` returns the container path
(`~/Library/Containers/com.apple.MobileSMS/Data/`), not the real home directory. The sandbox
blocks:

- Creating directories inside `~/Library/Messages/Attachments/` (the real path)
- Creating directories inside `NSTemporaryDirectory()` (maps to container tmp)
- Copying files between arbitrary paths

**Solution:** The CLI process (which is NOT sandboxed) stages files to
`~/Library/Messages/Attachments/XX/imsg-plus-UUID/filename` before calling the bridge. The dylib
receives the already-staged path and creates the file transfer from it.

### 2. AppleScript Fallback Masked the Bug

`SendCommand.swift` and `RPCServer.swift` silently fell back to AppleScript when the bridge threw
errors. Since AppleScript can send attachments (but not effects), attachment sends appeared to work.
The bridge attachment path had been broken since it was first written, but nobody noticed because
AppleScript handled it.

### 3. Empty Text Treated as "Has Text"

When sending a file-only message, `plainText` was `""` (empty string, not nil). The code created
an `NSAttributedString` from it and treated the message as "text + attachment", assigning
`__kIMMessagePartAttributeName = 1` to the file. The native UI uses part index 0 for file-only
sends.

**Fix:** Check `plainText.length > 0` before creating messageText, and check
`messageText.length > 0` for `hasText`.

## Key Discovery: How the Native UI Sends Photo + Effect

Method swizzling on `CKConversation.sendMessage:newComposition:` revealed the native UI's pattern:

```
CKConversation sendMessage:newComposition:
  message class=IMMessage
    expressiveSendStyleID=com.apple.messages.effect.CKConfettiEffect
    fileTransferGUIDs=("D03B93DE-...")
    flags=1048581  (0x100005)
    text.string=￼  (single \uFFFC, length 1)
    text.attrs[0]={
      __kIMFileTransferGUIDAttributeName = "D03B93DE-...";
      __kIMMessagePartAttributeName = 0;
    }
  composition=nil
```

Key observations:
- `composition` is **nil** — the native UI does NOT use CKComposition for photo+effect
- Everything is on the **IMMessage**: effect ID, file transfer GUIDs, text attributes
- Text is just `\uFFFC` (object replacement character) with transfer GUID attributes
- `__kIMMessagePartAttributeName = 0` for file-only sends
- Flags are `0x100005` (same as all outgoing messages)

This means the daemon preserves `expressive_send_style_id` when:
1. The send goes through `CKConversation.sendMessage:newComposition:`
2. The `IMMessage` has `expressiveSendStyleID` set via the long init method
3. The file transfer is properly registered with the daemon

## What Didn't Work

- **CKMediaObject `initWithTransfer:context:forceInlinePreview:`**: Crashes with
  `NSInvalidArgumentException` — `IMFileTransfer` doesn't implement `mediaObjectAdded` which
  `CKMediaObject`'s init expects.

- **Copying files inside the dylib**: Messages.app sandbox prevents directory creation and file
  copies to both `NSTemporaryDirectory()` and the real `~/Library/Messages/Attachments/`.

- **Sending attachment via `IMChat.sendMessage:`**: The daemon strips `expressive_send_style_id`
  from messages sent through this path when they have real file transfers. Must use
  `CKConversation.sendMessage:newComposition:` instead.

- **Using the original file path without staging**: `guidForNewOutgoingTransferWithLocalURL:` accepts
  any path, but the daemon can't always access files at arbitrary locations (e.g. `/tmp/`). Files
  must be in `~/Library/Messages/Attachments/` for reliable delivery.

## Working Architecture

```
CLI (unsandboxed)                    Dylib (inside Messages.app sandbox)
─────────────────                    ───────────────────────────────────
1. Copy file to                      3. IMFileTransferCenter
   ~/Library/Messages/                  .guidForNewOutgoingTransferWithLocalURL:
   Attachments/XX/imsg-plus-UUID/       (with staged path)
                                     4. registerTransferWithDaemon:
2. Send IPC command with             5. Build \uFFFC attributed string
   staged path as "file" param          with transfer GUID attributes
                                     6. createIMMessage with effect ID
                                        and file transfer GUIDs
                                     7. CKConversation.sendMessage:nil
```

## Debugging Techniques

### Send Path Swizzles (kept in code)

Three swizzles are installed at startup to log all sends going through Messages.app:

1. `CKConversation sendMessage:newComposition:` — logs message properties and composition
2. `CKConversation sendMessage:onService:newComposition:` — logs service selection
3. `IMChat sendMessage:` — logs lower-level sends

Logs are stored in the `_diagLog` static array and exposed via the `send_diag` key in the
`bridge.status` RPC response. To view:

```bash
echo '{"method":"bridge.status","params":{},"id":1}' | imsg-plus rpc \
  | python3 -c "import sys,json; d=json.load(sys.stdin); \
    [print(l) for l in d.get('result',{}).get('send_diag',[])]"
```

### Comparing UI vs Programmatic Sends

Send a photo+effect from the native Messages UI, then query `bridge.status` to see exactly what
parameters the UI passes. Compare with programmatic sends to find discrepancies.

### NSLog Doesn't Work

NSLog from the injected dylib does NOT appear in `log show` or Console.app. Use the `_diagLog`
in-memory array exposed via IPC instead. See `docs/thread-reply-debugging.md` for more on this.

## Files Modified

- `Sources/IMsgHelper/IMsgInjected.m` — Dylib: attachment prep, send path, swizzles
- `Sources/IMsgCore/IMCoreBridge.swift` — CLI-side file staging in `stageAttachment()`
- `Sources/imsg-plus/Commands/SendCommand.swift` — Bridge-first send flow
- `Sources/imsg-plus/RPCServer.swift` — Bridge-first send flow for RPC
