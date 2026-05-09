# Groups

## What counts as a group
- `chat.chat_identifier` or `chat.guid` with `;+;` or `;-;` in the handle.
- Example: `iMessage;+;chat1234567890` (group handle).
- Direct chats typically use a single handle (phone/email) without `;+;` or `;-;`.

## Where the identifiers live
- `chat.ROWID` -> `chat_id` (stable within one DB).
- `chat.chat_identifier` -> group handle (used by Messages).
- `chat.guid` -> group GUID (often same chat handle semantics).
- `chat.display_name` -> group name (optional).
- Participants in `chat_handle_join` + `handle`.

## Sending to a group
- `imsg send --chat-id <rowid>` (preferred; DB local).
- `imsg send --chat-identifier <handle>` (portable).
- `imsg send --chat-guid <guid>` (portable).
- Uses the injected IMCore bridge for group sends.
- Attachments supported same as direct sends.

## Inbound metadata (JSON)
- `chat_id`
- `chat_identifier`
- `chat_guid`
- `chat_name`
- `participants` (array of handles)
- `is_group`

`chat_id` is preferred for routing within one machine/DB.

## Notes
- Group send uses chat handle, not `buddy`.
- Messages from self may have empty `sender`; prefer `SenderName` + chat metadata.
