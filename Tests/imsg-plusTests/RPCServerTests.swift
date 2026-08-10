// The contract cases stay together so shared RPC fixtures remain reviewable.
// swiftlint:disable file_length

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

private final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func get() -> Value {
    lock.withLock { value }
  }

  func set(_ newValue: Value) {
    lock.withLock { value = newValue }
  }
}

private func int64Value(_ value: Any?) -> Int64? {
  if let value = value as? Int64 { return value }
  if let value = value as? Int { return Int64(value) }
  if let value = value as? NSNumber { return value.int64Value }
  return nil
}

@Test
func rpcCapabilitiesAdvertiseCompleteBoundedOperationBudgets() async throws {
  let output = TestRPCOutput()
  let server = RPCServer(store: try RPCTestDatabase.makeStore(), verbose: false, output: output)

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"capabilities","method":"rpc.capabilities"}"#
  )

  let result = output.responses.first?["result"] as? [String: Any]
  let budgets = result?["operation_budgets_ms"] as? [String: Int]
  #expect(result?["adapter_contract"] as? String == currentRoseMessagesAdapterContract)
  #expect(budgets?["bridge.preflight"] == 40_000)
  #expect(budgets?["send"] == 105_000)
  #expect((budgets?["typing.set"] ?? 0) > 0)
  #expect((budgets?["messages.markRead"] ?? 0) > 0)
  #expect((budgets?["watch.subscribe"] ?? 0) > 0)
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
    resolvePersistedSend: { chatID, transientGUID, _, _ in
      #expect(chatID == 1)
      return transientGUID
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
    resolvePersistedSend: { chatID, transientGUID, payload, _ in
      #expect(chatID == 1)
      #expect(payload?.payloadData == payloadData)
      return transientGUID
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
func rpcSendRejectsAnUnpersistedProviderMessage() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    autoTyping: false,
    output: output,
    bridgeSendMessage: { _, _, _, _, _, _, _ in
      ["guid": "transient-guid"]
    },
    resolvePersistedSend: { _, _, _, _ in nil },
    bridgeAvailable: true
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"unpersisted","method":"send","params":{"chat_id":1,"text":"yo"}}"#
  )

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == 1)
  let error = output.errors[0]["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32603)
  #expect(error?["data"] as? String == "Messages did not persist the outgoing message")
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
func rpcAllowedChatLockRejectsAnotherSubscriptionAndSendBeforeBridge() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  var preflightCalls = 0
  var sendCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    autoTyping: false,
    output: output,
    bridgeSendMessage: { _, _, _, _, _, _, _ in
      sendCalls += 1
      return ["guid": "must-not-send"]
    },
    bridgeAvailable: true,
    allowedChat: "iMessage;+;chat123",
    bridgePreflightAllowedChat: { _, _, _, _ in
      preflightCalls += 1
      return completeAllowedChatPreflight()
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"lock-watch","method":"watch.subscribe","params":{"chat_identifier":"other@example.com","attachments":false}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"lock-send","method":"send","params":{"to":"other@example.com","text":"must not send"}}"#
  )

  #expect(output.errors.count == 2)
  #expect(
    output.errors.allSatisfy {
      let error = $0["error"] as? [String: Any]
      return int64Value(error?["code"]) == -32602
    })
  #expect(preflightCalls == 0)
  #expect(sendCalls == 0)
}

@Test
func rpcAllowedChatLockRejectsBroadMessagesReads() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    autoTyping: false,
    output: output,
    bridgeAvailable: true,
    allowedChat: "iMessage;+;chat123",
    bridgePreflightAllowedChat: { _, _, _, _ in completeAllowedChatPreflight() }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"locked-chats","method":"chats.list","params":{"limit":10}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"locked-history","method":"messages.history","params":{"chat_id":1,"limit":5}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"locked-status","method":"bridge.status","params":{}}"#
  )

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == 3)
  #expect(
    output.errors.allSatisfy {
      let error = $0["error"] as? [String: Any]
      return int64Value(error?["code"]) == -32602
    })
}

@Test
func rpcAllowedChatPreflightsEveryTargetedProviderOperation() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  var preflightCalls = 0
  var locationCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    autoTyping: false,
    output: output,
    bridgeAvailable: true,
    allowedChat: "iMessage;+;chat123",
    bridgePreflightAllowedChat: { _, _, _, _ in
      preflightCalls += 1
      throw IMCoreBridgeError.operationFailed("blocked before provider dispatch")
    },
    getLocations: { _ in
      locationCalls += 1
      return []
    }
  )

  let requests = [
    #"{"jsonrpc":"2.0","id":"locked-typing","method":"typing.set","params":{"handle":"iMessage;+;chat123","state":"on"}}"#,
    #"{"jsonrpc":"2.0","id":"locked-read","method":"messages.markRead","params":{"handle":"iMessage;+;chat123"}}"#,
    #"{"jsonrpc":"2.0","id":"locked-tapback","method":"tapback.send","params":{"handle":"iMessage;+;chat123","guid":"guid-1","type":"love"}}"#,
    #"{"jsonrpc":"2.0","id":"locked-rename","method":"group.rename","params":{"handle":"iMessage;+;chat123","name":"Test"}}"#,
    #"{"jsonrpc":"2.0","id":"locked-edit","method":"message.edit","params":{"handle":"iMessage;+;chat123","guid":"guid-1","text":"edited"}}"#,
    #"{"jsonrpc":"2.0","id":"locked-unsend","method":"message.unsend","params":{"handle":"iMessage;+;chat123","guid":"guid-1"}}"#,
    #"{"jsonrpc":"2.0","id":"locked-location","method":"location.get","params":{"handle":"iMessage;+;chat123"}}"#,
  ]
  for request in requests {
    await server.handleLineForTesting(request)
  }

  #expect(output.responses.isEmpty)
  #expect(output.errors.count == requests.count)
  #expect(preflightCalls == requests.count - 1)
  #expect(locationCalls == 0)
  let errorCodes = output.errors.compactMap {
    int64Value(($0["error"] as? [String: Any])?["code"])
  }
  #expect(errorCodes.filter { $0 == -32011 }.count == requests.count - 1)
  #expect(errorCodes.filter { $0 == -32602 }.count == 1)
}

@Test
func rpcAllowedChatPreflightsImmediatelyBeforeSend() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  var boundaries: [String] = []
  let server = RPCServer(
    store: store,
    verbose: false,
    autoTyping: false,
    output: output,
    bridgeSendMessage: { handle, _, _, _, _, _, _ in
      boundaries.append("send:\(handle)")
      return ["guid": "locked-guid"]
    },
    resolvePersistedSend: { _, transientGUID, _, _ in transientGUID },
    bridgeAvailable: true,
    allowedChat: "iMessage;+;chat123",
    bridgePreflightAllowedChat: { handle, _, _, _ in
      boundaries.append("preflight:\(handle)")
      return completeAllowedChatPreflight()
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"locked-send","method":"send","params":{"chat_id":1,"text":"safe"}}"#
  )

  #expect(
    boundaries == [
      "preflight:iMessage;+;chat123",
      "send:iMessage;+;chat123",
    ])
  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["guid"] as? String == "locked-guid")
}

@Test
func rpcBridgePreflightReturnsOnlyContentFreeReadiness() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let server = RPCServer(
    store: store,
    verbose: false,
    autoTyping: false,
    output: output,
    bridgeAvailable: true,
    allowedChat: "iMessage;+;chat123",
    bridgePreflightAllowedChat: { _, _, _, _ in completeAllowedChatPreflight() }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"preflight","method":"bridge.preflight"}"#
  )

  let result = output.responses.first?["result"] as? [String: Any]
  #expect(result?["helper_ready"] as? Bool == true)
  #expect(result?["allowed_chat_locked"] as? Bool == true)
  #expect(result?["direct_chat"] as? Bool == true)
  #expect(result?.values.allSatisfy { $0 is Bool } == true)
  #expect(String(describing: result).contains("chat123") == false)
}

@Test
func rpcEnrolledIdentityPreflightsBeforeAnyBaselineOrSubscription() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let localAccount = String(repeating: "1", count: 64)
  let helper = String(repeating: "2", count: 64)
  let chat = String(repeating: "3", count: 64)
  let server = RPCServer(
    store: store,
    verbose: false,
    autoRead: false,
    autoTyping: false,
    output: output,
    bridgeAvailable: true,
    allowedChat: "iMessage;+;chat123",
    expectedLocalAccountFingerprint: localAccount,
    expectedHelperSHA256: helper,
    expectedChatFingerprint: chat,
    bridgePreflightAllowedChat: { _, expectedLocal, expectedHelper, expectedChat in
      #expect(expectedLocal == localAccount)
      #expect(expectedHelper == helper)
      #expect(expectedChat == chat)
      return completeEnrolledChatPreflight(
        localAccount: localAccount,
        helper: helper,
        chat: chat
      )
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"early-baseline","method":"watch.baseline","params":{"chat_identifier":"iMessage;+;chat123"}}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"early-subscribe","method":"watch.subscribe","params":{"chat_identifier":"iMessage;+;chat123"}}"#
  )
  #expect(output.responses.isEmpty)
  #expect(output.errors.count == 2)
  #expect(
    output.errors.allSatisfy {
      int64Value(($0["error"] as? [String: Any])?["code"]) == -32011
    })

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"preflight","method":"bridge.preflight"}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"baseline","method":"watch.baseline","params":{"chat_identifier":"iMessage;+;chat123"}}"#
  )

  #expect(output.responses.count == 2)
  let preflight = output.responses[0]["result"] as? [String: Any]
  #expect(preflight?["local_account_fingerprint"] as? String == localAccount)
  #expect(preflight?["loaded_helper_sha256"] as? String == helper)
  #expect(preflight?["chat_fingerprint"] as? String == chat)
  let baseline = output.responses[1]["result"] as? [String: Any]
  #expect(int64Value(baseline?["since_rowid"]) == 5)
  #expect(baseline?["adapter_contract"] as? String == currentRoseMessagesAdapterContract)
  #expect(output.notifications.isEmpty)
}

@Test
func rpcMissingHelperIsDefinitelyNotSentBeforeBridgeDispatch() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  var sendCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    autoTyping: false,
    output: output,
    bridgeSendMessage: { _, _, _, _, _, _, _ in
      sendCalls += 1
      return ["guid": "must-not-send"]
    },
    bridgeAvailable: true,
    allowedChat: "iMessage;+;chat123",
    bridgePreflightAllowedChat: { _, _, _, _ in
      throw IMCoreBridgeError.relaunchRequired
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"missing-helper","method":"send","params":{"chat_id":1,"text":"must not send"}}"#
  )

  #expect(sendCalls == 0)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32010)
  #expect(error?["data"] as? String == "definitely_not_sent")
}

@Test
func rpcChangedHelperGenerationIsDefinitelyNotSentBeforeBridgeDispatch() async throws {
  let store = try RPCTestDatabase.makeStore()
  let output = TestRPCOutput()
  let localAccount = String(repeating: "1", count: 64)
  let helper = String(repeating: "2", count: 64)
  let chat = String(repeating: "3", count: 64)
  var generation = String(repeating: "5", count: 64)
  var sendCalls = 0
  let server = RPCServer(
    store: store,
    verbose: false,
    autoTyping: false,
    output: output,
    bridgeSendMessage: { _, _, _, _, _, _, _ in
      sendCalls += 1
      return ["guid": "must-not-send"]
    },
    bridgeAvailable: true,
    allowedChat: "iMessage;+;chat123",
    expectedLocalAccountFingerprint: localAccount,
    expectedHelperSHA256: helper,
    expectedChatFingerprint: chat,
    bridgePreflightAllowedChat: { _, _, _, _ in
      completeEnrolledChatPreflight(
        localAccount: localAccount,
        helper: helper,
        chat: chat,
        generation: generation
      )
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"preflight","method":"bridge.preflight"}"#
  )
  generation = String(repeating: "6", count: 64)
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"changed-helper","method":"send","params":{"chat_id":1,"text":"must not send"}}"#
  )

  #expect(sendCalls == 0)
  let error = output.errors.first?["error"] as? [String: Any]
  #expect(int64Value(error?["code"]) == -32010)
  #expect(error?["data"] as? String == "definitely_not_sent")
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

private func completeAllowedChatPreflight() -> [String: Any] {
  [
    "allowed_chat_locked": true,
    "expected_chat_match": true,
    "chat_found": true,
    "direct_chat": true,
    "chat_identifier_match": true,
    "participant_match": true,
    "chat_guid_present": true,
  ]
}

private func completeEnrolledChatPreflight(
  localAccount: String,
  helper: String,
  chat: String,
  generation: String = String(repeating: "5", count: 64)
) -> [String: Any] {
  var result = completeAllowedChatPreflight()
  result["local_account_match"] = true
  result["loaded_helper_match"] = true
  result["chat_fingerprint_match"] = true
  result["local_account_fingerprint"] = localAccount
  result["loaded_helper_sha256"] = helper
  result["chat_fingerprint"] = chat
  result["helper_process_fingerprint"] = String(repeating: "4", count: 64)
  result["helper_generation_fingerprint"] = generation
  return result
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
  #expect(
    (result?["provider_epoch"] as? String)?.hasPrefix(
      "messages-db-v4:memory:scope:"
    ) == true)
  #expect(result?["pending_history_regression"] as? Bool == false)
  #expect(result?["adapter_contract"] as? String == currentRoseMessagesAdapterContract)

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
    delivered =
      output.notifications.compactMap { notification -> [String: Any]? in
        guard let params = notification["params"] as? [String: Any],
          let message = params["message"] as? [String: Any],
          int64Value(message["id"]) == 6
        else { return nil }
        return message
      }.first
    if delivered != nil { break }
    try await Task.sleep(nanoseconds: 50_000_000)
  }

  #expect((delivered?["participants"] as? [String])?.contains("+456") == true)
  #expect(
    delivered?["audience_revision"] as? Int
      == stableAudienceRevision(
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
      let message = params["message"] as? [String: Any]
    else { return false }
    return int64Value(message["id"]) == 6
  }
  let errorText = output.notifications.compactMap { notification -> String? in
    guard notification["method"] as? String == "error",
      let params = notification["params"] as? [String: Any],
      let error = params["error"] as? [String: Any]
    else { return nil }
    return error["message"] as? String
  }.first

  #expect(deliveredRowSix == false)
  #expect(errorText?.contains("subscription identity changed") == true)
}

@Test
func rpcWatchDoesNotSynchronouslyPreflightTheHelperForEveryDeliveredRow() async throws {
  let (store, db) = try RPCTestDatabase.makeMutableStore()
  let output = TestRPCOutput()
  let localAccount = String(repeating: "1", count: 64)
  let helper = String(repeating: "2", count: 64)
  let chat = String(repeating: "3", count: 64)
  let generation = LockedValue(String(repeating: "5", count: 64))
  let preflightCalls = LockedValue(0)
  let server = RPCServer(
    store: store,
    verbose: false,
    autoTyping: false,
    output: output,
    bridgeAvailable: true,
    allowedChat: "iMessage;+;chat123",
    expectedLocalAccountFingerprint: localAccount,
    expectedHelperSHA256: helper,
    expectedChatFingerprint: chat,
    bridgePreflightAllowedChat: { _, _, _, _ in
      preflightCalls.set(preflightCalls.get() + 1)
      return completeEnrolledChatPreflight(
        localAccount: localAccount,
        helper: helper,
        chat: chat,
        generation: generation.get()
      )
    }
  )

  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"preflight","method":"bridge.preflight"}"#
  )
  await server.handleLineForTesting(
    #"{"jsonrpc":"2.0","id":"subscribe","method":"watch.subscribe","params":{"chat_identifier":"iMessage;+;chat123","since_rowid":5}}"#
  )
  generation.set(String(repeating: "6", count: 64))
  try db.run(
    "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, account_guid) VALUES (6, 1, 'must stay quarantined', ?, 0, 'iMessage', 'account-b')",
    RPCTestDatabase.appleEpoch(Date().addingTimeInterval(1))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 6)")

  for _ in 0..<50 {
    if output.notifications.contains(where: { notification in
      guard notification["method"] as? String == "message",
        let params = notification["params"] as? [String: Any],
        let message = params["message"] as? [String: Any]
      else { return false }
      return int64Value(message["id"]) == 6
    }) {
      break
    }
    try await Task.sleep(nanoseconds: 50_000_000)
  }
  let deliveredRowSix = output.notifications.contains { notification in
    guard notification["method"] as? String == "message",
      let params = notification["params"] as? [String: Any],
      let message = params["message"] as? [String: Any]
    else { return false }
    return int64Value(message["id"]) == 6
  }
  #expect(deliveredRowSix == true)
  #expect(preflightCalls.get() == 1)
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
  #expect(
    (result?["provider_epoch"] as? String)?.hasPrefix(
      "messages-db-v4:memory:scope:"
    ) == true)
  try await Task.sleep(nanoseconds: 100_000_000)
  #expect(output.notifications.isEmpty)
}

@Test
func providerEpochStaysStableForNewMessageAccountValuesAndChangesWithChatScope() throws {
  let (store, db) = try RPCTestDatabase.makeMutableStore()
  let original = try store.providerEpoch(chatID: 1)

  try db.run(
    "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service, account_guid) VALUES (6, 1, 'new direction', ?, 1, 'iMessage', 'account-b')",
    RPCTestDatabase.appleEpoch(Date().addingTimeInterval(1))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 6)")
  let afterNewAccountValue = try store.providerEpoch(chatID: 1)
  #expect(afterNewAccountValue == original)

  try db.run("UPDATE chat SET chat_identifier = 'iMessage;+;other-chat' WHERE ROWID = 1")
  let changedChat = try store.providerEpoch(chatID: 1)
  #expect(changedChat != afterNewAccountValue)
}

@Test
func providerDatabaseEpochUsesStableVolumeIdentity() throws {
  let created = Date(timeIntervalSince1970: 1_700_000_000.125)
  let original = try ProviderIdentity.databaseEpoch(
    volumeUUID: "A1B2-C3D4",
    fileNumber: 42,
    creationDate: created
  )
  let sameAfterRemount = try ProviderIdentity.databaseEpoch(
    volumeUUID: "a1b2-c3d4",
    fileNumber: 42,
    creationDate: created
  )
  let replacement = try ProviderIdentity.databaseEpoch(
    volumeUUID: "a1b2-c3d4",
    fileNumber: 43,
    creationDate: created
  )
  let subMillisecondReplacement = try ProviderIdentity.databaseEpoch(
    volumeUUID: "a1b2-c3d4",
    fileNumber: 42,
    creationDate: created.addingTimeInterval(0.000_5)
  )
  let creationIdentity = String(
    format: "%016llx",
    created.timeIntervalSinceReferenceDate.bitPattern
  )

  #expect(original == "messages-db-v4:a1b2-c3d4:42:\(creationIdentity)")
  #expect(sameAfterRemount == original)
  #expect(replacement != original)
  #expect(subMillisecondReplacement != original)
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
