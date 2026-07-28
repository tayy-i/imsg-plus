# RPC

Goal: signal-style JSON-RPC without a daemon. Clawdis spawns `imsg rpc` and talks over stdio.

## Transport
- stdin/stdout, one JSON object per line.
- JSON-RPC 2.0 framing (`jsonrpc`, `id`, `method`, `params`).
- Notifications omit `id`.

## Lifecycle
- Gateway spawns one `imsg rpc` process.
- Process stays alive for watch + send.
- No TCP port, no daemon install.

## Methods

### `chats.list`
Params:
- `limit` (int, default 20)
Result:
- `{ "chats": [Chat] }`

### `messages.history`
Params:
- `chat_id` (int, required, preferred identifier)
- `limit` (int, default 50)
- `participants` (array, optional)
- `start` / `end` (ISO8601, optional)
- `attachments` (bool, default false)
Result:
- `{ "messages": [Message] }`

### `watch.subscribe`
Params:
- `chat_id` (int, optional)
- `since_rowid` (int, optional)
- `participants` (array, optional)
- `start` / `end` (ISO8601, optional)
- `attachments` (bool, default false)
Result:
- `{ "subscription": 1, "since_rowid": 42, "max_rowid": 42, "provider_epoch": "...", "pending_history_regression": false, "adapter_contract": "rose-imsg-plus-rpc-v2" }`

Consumers must require the exact `adapter_contract`. Missing or different
contracts are hard version errors; current Rose does not silently consume an
older Messages stream.

Contract `rose-imsg-plus-rpc-v2` includes reaction changes in the watched
message revision fingerprint, so an active tapback is emitted on the message it
targets.
Notifications:
- `{"jsonrpc":"2.0","method":"message","params":{"subscription":1,"message":<Message>}}`

### `watch.unsubscribe`
Params:
- `subscription` (int, required)
Result:
- `{ "ok": true, "guid": "..." }`

### `send`
Params (direct):
- `to` (string, required)
- `text` (string, optional)
- `file` (string, optional)
- `balloon_bundle_id` (string, optional, experimental)
- `payload_data_base64` (string, optional, experimental)
- `payload_file` (string, optional, experimental)
- `service` ("imessage"|"sms"|"auto", optional)
- `region` (string, optional)

Params (group):
- `chat_id` or `chat_identifier` or `chat_guid` (one required; `chat_id` preferred)
- `text` / `file` / extension payload fields as above

Result:
- `{ "ok": true }`

Experimental extension payload sending requires `balloon_bundle_id` plus exactly
one of `payload_data_base64` or `payload_file`. The payload is passed through to
Messages as the private `message.payload_data` blob. This path depends on
private IMCore/ChatKit behavior and should be treated as a compatibility probe,
not a stable public API.

## Objects

### Chat
- `id` (int)
- `name` (string)
- `identifier` (string)
- `guid` (string, optional)
- `service` (string)
- `last_message_at` (ISO8601)
- `participants` (array, optional)
- `is_group` (bool, optional)

### `message.edit`
Params:
- `handle` (string, required)
- `guid` (string, required)
- `text` or `markdown_text` (string, optional)
- `balloon_bundle_id` plus `payload_data_base64` or `payload_file` (optional, experimental)

When extension payload fields are provided, imsg-plus asks Messages to edit the
existing message with replacement `payload_data`. This is private ChatKit/IMCore
behavior and should be verified on the target OS before depending on it.

Result:
- `{ "ok": true, "handle": "...", "guid": "...", "action": "edited" }`

### Message
- `id` (rowid)
- `chat_id` (always present; preferred handle for routing)
- `guid` (string)
- `reply_to_guid` (string, optional)
- `sender`
- `is_from_me`
- `text`
- `created_at`
- `attachments` (array)
- `reactions` (array)
- `chat_identifier`
- `chat_guid`
- `chat_name`
- `participants`
- `is_group`

## Examples

Request:
```
{"jsonrpc":"2.0","id":"1","method":"chats.list","params":{"limit":10}}
```

Response:
```
{"jsonrpc":"2.0","id":"1","result":{"chats":[...]}}
```

Subscribe:
```
{"jsonrpc":"2.0","id":"2","method":"watch.subscribe","params":{"chat_id":1}}
```

Notification:
```
{"jsonrpc":"2.0","method":"message","params":{"subscription":2,"message":{...}}}
```
