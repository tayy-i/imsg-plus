import Foundation
import SQLite
import Testing

@testable import IMsgCore
@testable import imsg_plus

private enum RPCTestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makeStore() throws -> MessageStore {
    try makeMutableStore().store
  }

  static func makeMutableStore() throws -> (store: MessageStore, db: Connection) {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT,
        account_guid TEXT
      );
      """
    )
    try db.execute(
      """
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY,
        chat_identifier TEXT,
        guid TEXT,
        display_name TEXT,
        service_name TEXT
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      """
      CREATE TABLE attachment (
        ROWID INTEGER PRIMARY KEY,
        filename TEXT,
        transfer_name TEXT,
        uti TEXT,
        mime_type TEXT,
        total_bytes INTEGER,
        is_sticker INTEGER
      );
      """
    )
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")

    let now = Date()
    try db.run(
      """
      INSERT INTO chat(ROWID, chat_identifier, guid, display_name, service_name)
      VALUES (1, 'iMessage;+;chat123', 'iMessage;+;chat123', 'Group Chat', 'iMessage')
      """
    )
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123'), (2, 'me@icloud.com')")
    try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 1), (1, 2)")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, account_guid)
      VALUES (5, 1, 'hello', ?, 0, 'iMessage', 'account-a')
      """,
      appleEpoch(now)
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 5)")

    return (
      try MessageStore(
        connection: db, path: ":memory:", hasAttributedBody: false, hasReactionColumns: false),
      db
    )
  }
}

final class TestRPCOutput: RPCOutput, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var responses: [[String: Any]] = []
  private(set) var errors: [[String: Any]] = []
  private(set) var notifications: [[String: Any]] = []

  func sendResponse(id: Any, result: Any) {
    record(&responses, value: ["jsonrpc": "2.0", "id": id, "result": result])
  }

  func sendError(id: Any?, error: RPCError) {
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": error.asDictionary(),
    ]
    record(&errors, value: payload)
  }

  func sendNotification(method: String, params: Any) {
    record(&notifications, value: ["jsonrpc": "2.0", "method": method, "params": params])
  }

  private func record(_ bucket: inout [[String: Any]], value: [String: Any]) {
    lock.lock()
    defer { lock.unlock() }
    bucket.append(value)
  }
}

private func int64Value(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  return nil
}

@Test
func rpcChatsListReturnsChatPayload() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":"1","method":"chats.list","params":{"limit":10}}"#
  await server.handleLineForTesting(line)

  #expect(output.responses.count == 1)
  let result = output.responses[0]["result"] as? [String: Any]
  let chats = result?["chats"] as? [[String: Any]] ?? []
  #expect(chats.count == 1)
  let chat = chats[0]
  #expect(int64Value(chat["id"]) == 1)
  #expect(chat["identifier"] as? String == "iMessage;+;chat123")
  #expect(chat["is_group"] as? Bool == true)
  #expect((chat["participants"] as? [String])?.count == 2)
}

@Test
func rpcMessagesHistoryIncludesChatFields() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":2,"method":"messages.history","params":{"chat_id":1,"limit":5}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  let messages = result?["messages"] as? [[String: Any]] ?? []
  #expect(messages.count == 1)
  let message = messages[0]
  #expect(int64Value(message["chat_id"]) == 1)
  #expect(message["chat_identifier"] as? String == "iMessage;+;chat123")
  #expect(message["is_group"] as? Bool == true)
}

@Test
func rpcSendResolvesChatID() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  var captured: (handle: String, text: String)?
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    bridgeSendMessage: { handle, text, _, _, _, _, _ in
      captured = (handle, text)
      return ["guid": "msg-guid-1"]
    },
    bridgeAvailable: true
  )

  let line = #"{"jsonrpc":"2.0","id":"3","method":"send","params":{"chat_id":1,"text":"yo"}}"#
  await server.handleLineForTesting(line)

  #expect(captured?.handle == "iMessage;+;chat123")
  #expect(captured?.text == "yo")
  #expect(output.responses.first?["result"] as? [String: Any] != nil)
}

@Test
func rpcSendPassesExtensionPayload() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let payloadData = Data("payload".utf8)
  var captured: (handle: String, payload: MessageExtensionPayload?)?
  let server = RPCServer(
    store: store,
    verbose: false,
    autoTyping: false,
    output: output,
    bridgeSendMessage: { handle, _, _, _, _, _, payload in
      captured = (handle, payload)
      return ["guid": "msg-guid-extension"]
    },
    bridgeAvailable: true
  )

  let line =
    #"{"jsonrpc":"2.0","id":"3a","method":"send","params":{"chat_id":1,"balloon_bundle_id":"com.apple.messages.MSMessageExtensionBalloonPlugin:TEAMID:com.example.MessagesExtension","payload_data_base64":""#
    + payloadData.base64EncodedString()
    + #""}}"#
  await server.handleLineForTesting(line)

  #expect(captured?.handle == "iMessage;+;chat123")
  #expect(
    captured?.payload?.balloonBundleID
      == "com.apple.messages.MSMessageExtensionBalloonPlugin:TEAMID:com.example.MessagesExtension")
  #expect(captured?.payload?.payloadData == payloadData)
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["extension_payload"] as? Bool == true)
  #expect(result?["guid"] as? String == "msg-guid-extension")
}

@Test
func rpcSendReportsBridgeTimeout() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    autoTyping: false,
    output: output,
    bridgeSendMessage: { _, _, _, _, _, _, _ in
      throw IMCoreBridgeError.connectionFailed("IPC error: Timeout waiting for response")
    },
    bridgeAvailable: true
  )

  let line = #"{"jsonrpc":"2.0","id":"3b","method":"send","params":{"chat_id":1,"text":"yo"}}"#
  await server.handleLineForTesting(line)

  #expect(output.errors.count == 1)
  let error = output.errors[0]["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32603)
  #expect((error?["data"] as? String)?.contains("Timeout waiting for response") == true)
}

@Test
func rpcSendRejectsBridgeChatNotFound() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    autoTyping: false,
    output: output,
    bridgeSendMessage: { _, _, _, _, _, _, _ in
      throw IMCoreBridgeError.chatNotFound("iMessage;+;chat123")
    },
    bridgeAvailable: true
  )

  let line = #"{"jsonrpc":"2.0","id":"3c","method":"send","params":{"chat_id":1,"text":"yo"}}"#
  await server.handleLineForTesting(line)

  #expect(output.errors.count == 1)
  let error = output.errors[0]["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32603)
  #expect((error?["data"] as? String)?.contains("Chat not found") == true)
}

@Test
func rpcSendRejectsMissingTextAndFile() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":"4","method":"send","params":{"to":"+15551234567"}}"#
  await server.handleLineForTesting(line)

  #expect(output.errors.count == 1)
  let error = output.errors[0]["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcRejectsInvalidJSON() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting("not-json")

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32700)
}

@Test
func rpcRejectsNonObjectRequest() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting("[]")

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32600)
}

@Test
func rpcRejectsInvalidJSONRPCVersion() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"1.0","id":1,"method":"chats.list"}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32600)
}

@Test
func rpcRejectsMissingMethod() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":1}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32600)
}

@Test
func rpcReportsMethodNotFound() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":1,"method":"nope"}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32601)
}

@Test
func rpcHistoryRequiresChatID() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":5,"method":"messages.history","params":{"limit":5}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcSendRejectsUnsupportedServiceParam() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":6,"method":"send","params":{"to":"+15551234567","text":"hi","service":"fax"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
  #expect((error?["data"] as? String)?.contains("service is no longer supported") == true)
}

@Test
func rpcSendRejectsMissingRecipientForDirectSend() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":7,"method":"send","params":{"text":"hi"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcSendRejectsChatAndRecipient() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":8,"method":"send","params":{"chat_id":1,"to":"+15551234567","text":"hi"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcSendRejectsUnknownChatID() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":9,"method":"send","params":{"chat_id":999,"text":"hi"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcWatchSubscribeEmitsNotificationAndUnsubscribe() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let subscribe =
    #"{"jsonrpc":"2.0","id":10,"method":"watch.subscribe","params":{"chat_id":1,"since_rowid":-1}}"#
  await server.handleLineForTesting(subscribe)

  let result = output.responses.first?["result"] as? [String: Any]
  let subscription = int64Value(result?["subscription"]) ?? 0
  #expect(subscription > 0)
  #expect(int64Value(result?["since_rowid"]) == -1)
  #expect(int64Value(result?["max_rowid"]) == 5)
  #expect((result?["provider_epoch"] as? String)?.hasPrefix(
    "messages-db-v2:memory:scope:"
  ) == true)
  #expect(result?["pending_history_regression"] as? Bool == false)

  for _ in 0..<20 {
    if output.notifications.count >= 1 { break }
    try await Task.sleep(nanoseconds: 50_000_000)
  }
  #expect(output.notifications.count == 1)
  let params = output.notifications.first?["params"] as? [String: Any]
  #expect(int64Value(params?["subscription"]) == subscription)
  #expect(params?["message"] as? [String: Any] != nil)

  let unsubscribe =
    #"{"jsonrpc":"2.0","id":11,"method":"watch.unsubscribe","params":{"subscription":\#(subscription)}}"#
  await server.handleLineForTesting(unsubscribe)

  #expect(output.responses.count >= 2)
}

@Test
func rpcWatchRefreshesAudienceMembershipForEveryDeliveredRow() async throws {
  let (store, db) = try RPCTestDatabase.makeMutableStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":31,"method":"watch.subscribe","params":{"chat_id":1,"since_rowid":5}}"#
  )
  try db.run("INSERT INTO handle(ROWID, id) VALUES (3, '+456')")
  try db.run("INSERT INTO chat_handle_join(chat_id, handle_id) VALUES (1, 3)")
  try db.run(
    "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, account_guid) VALUES (6, 1, 'membership changed', ?, 0, 'iMessage', 'account-a')",
    RPCTestDatabase.appleEpoch(Date().addingTimeInterval(1))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 6)")

  var delivered: [String: Any]?
  for _ in 0..<50 {
    delivered = output.notifications.compactMap { notification -> [String: Any]? in
      guard let params = notification["params"] as? [String: Any],
            let message = params["message"] as? [String: Any],
            int64Value(message["id"]) == 6 else { return nil }
      return message
    }.first
    if delivered != nil { break }
    try await Task.sleep(nanoseconds: 50_000_000)
  }

  #expect((delivered?["participants"] as? [String])?.contains("+456") == true)
  #expect(delivered?["audience_revision"] as? Int == stableAudienceRevision(
    chatGUID: "iMessage;+;chat123",
    participants: ["+123", "+456", "me@icloud.com"],
    sender: "+123"
  ))
}

@Test
func rpcWatchPinsBeforeDeliveringAReassociatedChat() async throws {
  let (store, db) = try RPCTestDatabase.makeMutableStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":32,"method":"watch.subscribe","params":{"chat_id":1,"since_rowid":5}}"#
  )
  try db.run(
    "UPDATE chat SET chat_identifier = 'iMessage;+;reassociated' WHERE ROWID = 1"
  )
  try db.run(
    "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, account_guid) VALUES (6, 1, 'must stay quarantined', ?, 0, 'iMessage', 'account-a')",
    RPCTestDatabase.appleEpoch(Date().addingTimeInterval(1))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 6)")

  for _ in 0..<50 {
    if output.notifications.contains(where: { $0["method"] as? String == "error" }) { break }
    try await Task.sleep(nanoseconds: 50_000_000)
  }
  let deliveredRowSix = output.notifications.contains { notification in
    guard notification["method"] as? String == "message",
          let params = notification["params"] as? [String: Any],
          let message = params["message"] as? [String: Any] else { return false }
    return int64Value(message["id"]) == 6
  }
  let errorText = output.notifications.compactMap { notification -> String? in
    guard notification["method"] as? String == "error",
          let params = notification["params"] as? [String: Any],
          let error = params["error"] as? [String: Any] else { return nil }
    return error["message"] as? String
  }.first

  #expect(deliveredRowSix == false)
  #expect(errorText?.contains("subscription identity changed") == true)
}

@Test
func rpcWatchSubscribeReturnsFreshDeterministicBaselineWithoutReplayingHistory() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let subscribe =
    #"{"jsonrpc":"2.0","id":13,"method":"watch.subscribe","params":{"chat_id":1}}"#
  await server.handleLineForTesting(subscribe)

  let result = output.responses.first?["result"] as? [String: Any]
  #expect(int64Value(result?["since_rowid"]) == 5)
  #expect(int64Value(result?["max_rowid"]) == 5)
  #expect((result?["provider_epoch"] as? String)?.hasPrefix(
    "messages-db-v2:memory:scope:"
  ) == true)
  try await Task.sleep(nanoseconds: 100_000_000)
  #expect(output.notifications.isEmpty)
}

@Test
func providerEpochChangesWithChatAndAccountScope() throws {
  let (store, db) = try RPCTestDatabase.makeMutableStore()
  let original = try store.providerEpoch(chatID: 1)

  try db.run("UPDATE message SET account_guid = 'account-b' WHERE ROWID = 5")
  let changedAccount = try store.providerEpoch(chatID: 1)
  #expect(changedAccount != original)

  try db.run("UPDATE chat SET chat_identifier = 'iMessage;+;other-chat' WHERE ROWID = 1")
  let changedChat = try store.providerEpoch(chatID: 1)
  #expect(changedChat != changedAccount)
}

@Test
func rpcWatchSubscribeRejectsACursorAheadOfTheCurrentProvider() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":14,"method":"watch.subscribe","params":{"since_rowid":99}}"#
  )

  #expect(output.responses.isEmpty)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
  #expect((error?["data"] as? String)?.contains("provider reset") == true)
}

@Test
func rpcMessageEditRequiresHandle() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":20,"method":"message.edit","params":{"guid":"ABC","text":"new"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcMessageEditRequiresGuid() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":21,"method":"message.edit","params":{"handle":"+123","text":"new"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcMessageEditRequiresText() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":22,"method":"message.edit","params":{"handle":"+123","guid":"ABC"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcMessageUnsendRequiresHandle() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":23,"method":"message.unsend","params":{"guid":"ABC"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcMessageUnsendRequiresGuid() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line =
    #"{"jsonrpc":"2.0","id":24,"method":"message.unsend","params":{"handle":"+123"}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcWatchUnsubscribeRequiresSubscription() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(store: store, verbose: false, output: output)

  let line = #"{"jsonrpc":"2.0","id":12,"method":"watch.unsubscribe","params":{}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32602)
}

@Test
func rpcLocationsListReturnsPayload() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let location = FriendLocation(
    handle: "+14155551234",
    latitude: 37.7749,
    longitude: -122.4194,
    address: "1 Apple Park Way, Cupertino, CA",
    formattedAddressLines: ["1 Apple Park Way", "Cupertino, CA"],
    labels: ["_$!<home>!$_"]
  )
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    bridgeAvailable: true,
    getLocations: { handle in
      #expect(handle == "+14155551234")
      return [location]
    }
  )

  let line =
    #"{"jsonrpc":"2.0","id":30,"method":"locations.list","params":{"handle":"+14155551234"}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  let locations = result?["locations"] as? [[String: Any]] ?? []
  #expect(locations.count == 1)
  #expect(locations[0]["labels"] as? [String] == ["Home"])
  #expect(
    locations[0]["formatted_address_lines"] as? [String] == ["1 Apple Park Way", "Cupertino, CA"])
}

@Test
func rpcLocationGetSupportsRawOutput() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let rawLocation: [String: Any] = [
    "handle": "+14155551234",
    "labels": ["_$!<home>!$_"],
    "raw_location": ["fields": ["labels": ["_$!<home>!$_"]]],
  ]
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    bridgeAvailable: true,
    getLocationsResponse: { handle, raw in
      #expect(handle == "+14155551234")
      #expect(raw == true)
      return [rawLocation]
    }
  )

  let line =
    #"{"jsonrpc":"2.0","id":31,"method":"location.get","params":{"handle":"+14155551234","raw":true}}"#
  await server.handleLineForTesting(line)

  let result = output.responses.first?["result"] as? [String: Any]
  let locations = result?["locations"] as? [[String: Any]] ?? []
  #expect(locations.count == 1)
  #expect(locations[0]["labels"] as? [String] == ["_$!<home>!$_"])
  #expect((locations[0]["raw_location"] as? [String: Any])?["fields"] as? [String: Any] != nil)
}

@Test
func rpcLocationsListRequiresBridge() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    output: output,
    bridgeAvailable: false
  )

  let line = #"{"jsonrpc":"2.0","id":32,"method":"locations.list","params":{}}"#
  await server.handleLineForTesting(line)

  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32603)
  #expect((error?["message"] as? String)?.isEmpty == false)
}
