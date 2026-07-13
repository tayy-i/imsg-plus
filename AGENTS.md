# Repository Guidelines

## Communication

When describing this project, including in documentation, code comments, plans, issues, and other project files, use plain terminology that someone who understands the project's scope can follow. Do not use project-specific technical jargon.

## Agent-owned workflow

Routine work is owned by the active primary development agent. That agent is responsible for execution, checking, and keeping work records current. Use a separate review agent that did not implement the work when an independent security or release-readiness review is required. Ask the user only when a decision or action needs the user's authority; do not leave routine work unowned merely because no human assignee was named.

## Project Structure & Module Organization
- `Sources/imsg` holds the CLI entrypoint and command wiring.
- `Sources/IMsgCore` contains SQLite access, watchers, IMCore bridge logic, and helpers.
- `bin/` is created by `make build` for local artifacts.

## Build, Test, and Development Commands
- `make imsg` — clean rebuild + run debug CLI (use `ARGS=...`).
- `make build` — universal release build into `bin/` (includes dylib).
- `make build-dylib` — build only the injectable dylib for advanced features.
- `make lint` — run `swift format` lint + `swiftlint`.
- `make test` — run `swift test` after syncing version + patching deps.

## Advanced Features Architecture (imsg-plus)

### Dylib Injection Approach
Advanced features (typing indicators, read receipts, tapbacks) require access to the private IMCore framework, which is only available inside Messages.app's process. We use `DYLD_INSERT_LIBRARIES` to inject `imsg-plus-helper.dylib` into Messages.app at launch.

**Key files:**
- `Sources/IMsgHelper/IMsgInjected.m` — Objective-C dylib that loads into Messages.app
- `Sources/IMsgCore/IMCoreBridge.swift` — Swift side of IPC bridge
- `Sources/IMsgCore/MessagesLauncher.swift` — Manages dylib injection lifecycle
- `Makefile` — `build-dylib` target compiles the injectable dylib (arm64e)

### IPC Mechanism
File-based IPC is used for communication between the CLI and the injected dylib:
- **Command file**: `~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-command.json`
- **Response file**: `~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-response.json`
- **Lock file**: `~/Library/Containers/com.apple.MobileSMS/Data/.imsg-plus-ready` (contains Messages.app PID)

The dylib watches the command file using `dispatch_source_t` and writes responses to the response file. The Swift side polls for responses with timeout.

### IMCore Framework Access
The dylib uses Objective-C runtime to access IMCore classes:
- `IMChatRegistry` — Find chats by handle/identifier
- `IMChat` — Chat objects with methods like `setLocalUserIsTyping:`, `markAllMessagesAsRead`
- `IMMessageItem` / `IMChatItem` — Message objects (note: these are different classes!)

**Runtime compatibility:** Some methods may not exist on all macOS versions. The dylib injects missing methods at runtime (e.g., `isEditedMessageHistory` for macOS 15.6).

### Implementation Status
- ✅ **Typing indicators**: Working via `IMChat.setLocalUserIsTyping:`
- ✅ **Read receipts**: Working via `IMChat.markAllMessagesAsRead`
- ❌ **Tapbacks**: In progress - GUID-to-chat-item lookup needs work
  - Issue: `chatItems` array search doesn't find messages by GUID
  - May need alternative approach or different IMCore method

### Testing Notes
- Must launch Messages.app with dylib: `DYLD_INSERT_LIBRARIES=.build/release/imsg-plus-helper.dylib /System/Applications/Messages.app/Contents/MacOS/Messages &`
- Requires SIP disabled (`csrutil disable` from Recovery Mode)
- Check dylib loaded: `lsof -p $(pgrep Messages) | grep imsg` or check for IPC files
- Console.app shows `[imsg-plus]` logs from the dylib
- Typing indicators appear on recipient's device, not sender's

## Coding Style & Naming Conventions
- Swift 6 module; prefer concrete types, early returns, and minimal globals.
- Formatting is enforced by `swift format` and `swiftlint`.
- CLI flags use long-form, kebab-case (`--chat-id`, `--attachments`).

## Testing Guidelines
- Unit tests live in `Tests/` as `*Tests.swift`.
- Prefer deterministic fixtures over touching the live Messages DB.
- Add regression tests for fixes touching parsing, filtering, or attachment metadata.

## Commit & Pull Request Guidelines
- Follow the existing short, lowercase prefixes seen in history (`ci:`, `chore:`, `fix:`, `feat:`) with an imperative summary (e.g., `fix: handle missing attachments`).
- PRs should include: brief description, steps to repro/verify, and outputs of `make lint` and `make test`. For CLI changes, include sample commands and before/after snippets.
- Keep changeset focused; avoid drive-by refactors unless they reduce risk or remove duplication in touched areas.

## Security & macOS Permissions
- The tool needs read-only access to `~/Library/Messages/chat.db`; ensure the terminal has Full Disk Access before running tests that touch the DB.
- Sending requires the injected Messages.app helper to be available; document any manual steps needed for reviewers.
