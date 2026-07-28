import Foundation
import IMsgCore

let currentRoseMessagesAdapterContract = "rose-imsg-plus-rpc-v1"

protocol RPCOutput: Sendable {
  func sendResponse(id: Any, result: Any)
  func sendError(id: Any?, error: RPCError)
  func sendNotification(method: String, params: Any)
}

final class RPCServer {
  private let store: MessageStore
  private let watcher: MessageWatcher
  private let output: RPCOutput
  private let cache: ChatCache
  private let verbose: Bool
  private let bridgeSendMessage:
    (String, String, String?, String?, MessageEffect?, String?, MessageExtensionPayload?)
      async throws -> [String: Any]
  private let autoRead: Bool
  private let autoTyping: Bool
  private let bridgeAvailable: Bool
  private let contactResolver: ContactResolving?
  private let getLocations: (String?) async throws -> [FriendLocation]
  private let getLocationsResponse: (String?, Bool) async throws -> [[String: Any]]
  private var nextSubscriptionID = 1
  private var subscriptions: [Int: Task<Void, Never>] = [:]

  init(
    store: MessageStore,
    verbose: Bool,
    autoRead: Bool? = nil,
    autoTyping: Bool? = nil,
    output: RPCOutput = RPCWriter(),
    bridgeSendMessage:
      @escaping (
        String, String, String?, String?, MessageEffect?, String?, MessageExtensionPayload?
      ) async throws -> [String: Any] = RPCServer.defaultBridgeSendMessage,
    contactResolver: ContactResolving? = ContactResolver(),
    bridgeAvailable: Bool? = nil,
    getLocations: @escaping (String?) async throws -> [FriendLocation] = {
      try await IMCoreBridge.shared.getLocations(handle: $0)
    },
    getLocationsResponse: @escaping (String?, Bool) async throws -> [[String: Any]] = {
      try await IMCoreBridge.shared.getLocationsResponse(handle: $0, includeDebugRaw: $1)
    }
  ) {
    self.store = store
    self.watcher = MessageWatcher(store: store)
    self.cache = ChatCache(store: store)
    self.verbose = verbose
    self.output = output
    self.bridgeSendMessage = bridgeSendMessage
    self.contactResolver = contactResolver
    let available = bridgeAvailable ?? IMCoreBridge.shared.isAvailable
    self.bridgeAvailable = available
    self.autoRead = autoRead ?? available
    self.autoTyping = autoTyping ?? available
    self.getLocations = getLocations
    self.getLocationsResponse = getLocationsResponse
  }

  func run() async throws {
    while let line = readLine() {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      await handleLine(trimmed)
    }
    for task in subscriptions.values {
      task.cancel()
    }
  }

  func handleLineForTesting(_ line: String) async {
    await handleLine(line)
  }

  private func handleLine(_ line: String) async {
    guard let data = line.data(using: .utf8) else {
      output.sendError(id: nil, error: RPCError.parseError("invalid utf8"))
      return
    }
    let json: Any
    do {
      json = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      output.sendError(id: nil, error: RPCError.parseError(error.localizedDescription))
      return
    }
    guard let request = json as? [String: Any] else {
      output.sendError(id: nil, error: RPCError.invalidRequest("request must be an object"))
      return
    }
    let jsonrpc = request["jsonrpc"] as? String
    if jsonrpc != nil && jsonrpc != "2.0" {
      output.sendError(id: request["id"], error: RPCError.invalidRequest("jsonrpc must be 2.0"))
      return
    }
    guard let method = request["method"] as? String, !method.isEmpty else {
      output.sendError(id: request["id"], error: RPCError.invalidRequest("method is required"))
      return
    }
    let params = request["params"] as? [String: Any] ?? [:]
    let id = request["id"]

    do {
      switch method {
      case "chats.list":
        let limit = intParam(params["limit"]) ?? 20
        let chats = try store.listChats(limit: max(limit, 1))
        let payloads = try chats.map { chat in
          let info = try cache.info(chatID: chat.id)
          let participants = try cache.participants(chatID: chat.id)
          let identifier = info?.identifier ?? chat.identifier
          let guid = info?.guid ?? ""
          let name = (info?.name.isEmpty == false ? info?.name : nil) ?? chat.name
          let service = info?.service ?? chat.service
          var participantNames: [String: String]? = nil
          if let resolver = self.contactResolver {
            var names: [String: String] = [:]
            for handle in participants {
              if let resolved = resolver.resolve(handle: handle) {
                names[handle] = resolved
              }
            }
            if !names.isEmpty { participantNames = names }
          }
          return chatPayload(
            id: chat.id,
            identifier: identifier,
            guid: guid,
            name: name,
            service: service,
            lastMessageAt: chat.lastMessageAt,
            participants: participants,
            participantNames: participantNames
          )
        }
        respond(id: id, result: ["chats": payloads])
      case "messages.history":
        guard let chatID = int64Param(params["chat_id"]) else {
          throw RPCError.invalidParams("chat_id is required")
        }
        let limit = intParam(params["limit"]) ?? 50
        let participants = stringArrayParam(params["participants"])
        let startISO = stringParam(params["start"])
        let endISO = stringParam(params["end"])
        let includeAttachments = boolParam(params["attachments"]) ?? false
        let filter = try MessageFilter.fromISO(
          participants: participants,
          startISO: startISO,
          endISO: endISO
        )
        let filtered = try store.messages(chatID: chatID, limit: max(limit, 1), filter: filter)
        let localResolver = contactResolver
        let payloads = try filtered.map { message in
          try buildMessagePayload(
            store: store,
            cache: cache,
            message: message,
            includeAttachments: includeAttachments,
            contactResolver: localResolver
          )
        }
        respond(id: id, result: ["messages": payloads])
      case "locations.list", "location.get":
        try await handleLocationsList(params: params, id: id)
      case "watch.subscribe":
        let requestedChatIdentifier = stringParam(params["chat_identifier"])
        let requestedChatID = int64Param(params["chat_id"])
        let chatID: Int64?
        if let requestedChatID {
          chatID = requestedChatID
        } else if let requestedChatIdentifier, !requestedChatIdentifier.isEmpty {
          guard let chat = try store.chatInfo(identifierOrGUID: requestedChatIdentifier) else {
            throw RPCError.invalidParams("chat_identifier was not found")
          }
          chatID = chat.id
        } else {
          chatID = nil
        }
        let requestedSinceRowID = int64Param(params["since_rowid"])
        if let requestedSinceRowID, requestedSinceRowID < -1 {
          throw RPCError.invalidParams("since_rowid must be -1 or greater")
        }
        let maxRowID = try store.maxRowID()
        if let requestedSinceRowID, requestedSinceRowID > maxRowID {
          throw RPCError.invalidParams(
            "since_rowid is ahead of the current Messages database; provider reset must be reviewed"
          )
        }
        let sinceRowID = requestedSinceRowID ?? maxRowID
        let providerEpoch = try store.providerEpoch(chatID: chatID)
        let pendingHistoryRegression = try requestedSinceRowID.map {
          try store.pendingHistoryRegresses(afterRowID: $0, chatID: chatID)
        } ?? false
        let participants = stringArrayParam(params["participants"])
        let startISO = stringParam(params["start"])
        let endISO = stringParam(params["end"])
        let includeAttachments = boolParam(params["attachments"]) ?? false
        let filter = try MessageFilter.fromISO(
          participants: participants,
          startISO: startISO,
          endISO: endISO
        )
        let config = MessageWatcherConfiguration(
          replayRecentRevisionsOnStart: requestedSinceRowID != nil
        )
        let subID = nextSubscriptionID
        nextSubscriptionID += 1
        let localStore = store
        let localWatcher = watcher
        let localCache = cache
        let localWriter = output
        let localFilter = filter
        let localChatID = chatID
        let localSinceRowID = sinceRowID
        let localConfig = config
        let localIncludeAttachments = includeAttachments
        let localProviderEpoch = providerEpoch
        let localAutoRead = autoRead
        let localBridgeAvailable = bridgeAvailable
        let localVerbose = verbose
        let localResolver = contactResolver
        // Return the exact baseline before notifications can be emitted. A
        // durable consumer can save this baseline and resume after it without
        // racing the subscription startup.
        respond(
          id: id,
          result: [
            "subscription": subID,
            "since_rowid": sinceRowID,
            "max_rowid": maxRowID,
            "provider_epoch": providerEpoch,
            "pending_history_regression": pendingHistoryRegression,
            "adapter_contract": currentRoseMessagesAdapterContract,
          ]
        )
        let task = Task {
          do {
            for try await message in localWatcher.stream(
              chatID: localChatID,
              sinceRowID: localSinceRowID,
              configuration: localConfig
            ) {
              if Task.isCancelled { return }
              if !localFilter.allows(message) { continue }
              guard localChatID == nil || message.chatID == localChatID else {
                throw NSError(
                  domain: "imsg-plus.RPCServer",
                  code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "Messages subscription scope changed"]
                )
              }
              let currentProviderEpoch = try localStore.providerEpoch(chatID: localChatID)
              guard currentProviderEpoch == localProviderEpoch else {
                throw NSError(
                  domain: "imsg-plus.RPCServer",
                  code: 2,
                  userInfo: [NSLocalizedDescriptionKey: "Messages subscription identity changed"]
                )
              }
              let payload = try buildMessagePayload(
                store: localStore,
                cache: localCache,
                message: message,
                includeAttachments: localIncludeAttachments,
                contactResolver: localResolver
              )
              localWriter.sendNotification(
                method: "message",
                params: ["subscription": subID, "message": payload]
              )
              // Auto-read receipt for incoming messages
              if localAutoRead && localBridgeAvailable {
                if let isFromMe = payload["is_from_me"] as? Bool, !isFromMe {
                  let handle: String? =
                    stringParam(payload["chat_identifier"])
                    ?? stringParam(payload["sender"])
                  if let handle, !handle.isEmpty {
                    Task {
                      do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        try await IMCoreBridge.shared.markAsRead(handle: handle)
                        if localVerbose {
                          FileHandle.standardError.write(
                            Data("[auto-read] marked read for \(handle)\n".utf8))
                        }
                      } catch {
                        if localVerbose {
                          FileHandle.standardError.write(Data("[auto-read] error: \(error)\n".utf8))
                        }
                      }
                    }
                  }
                }
              }
            }
          } catch {
            localWriter.sendNotification(
              method: "error",
              params: [
                "subscription": subID,
                "error": ["message": String(describing: error)],
              ]
            )
          }
        }
        subscriptions[subID] = task
      case "watch.unsubscribe":
        guard let subID = intParam(params["subscription"]) else {
          throw RPCError.invalidParams("subscription is required")
        }
        if let task = subscriptions.removeValue(forKey: subID) {
          task.cancel()
        }
        respond(id: id, result: ["ok": true])
      case "send":
        try await handleSend(params: params, id: id)
      case "typing.set":
        try await handleTypingSet(params: params, id: id)
      case "messages.markRead":
        try await handleMarkRead(params: params, id: id)
      case "tapback.send":
        try await handleTapbackSend(params: params, id: id)
      case "group.create":
        try await handleGroupCreate(params: params, id: id)
      case "group.rename":
        try await handleGroupRename(params: params, id: id)
      case "message.edit":
        try await handleMessageEdit(params: params, id: id)
      case "message.unsend":
        try await handleMessageUnsend(params: params, id: id)
      case "bridge.status":
        let status = try await IMCoreBridge.shared.getStatus()
        respond(id: id, result: status)
      default:
        output.sendError(id: id, error: RPCError.methodNotFound(method))
      }
    } catch let err as RPCError {
      output.sendError(id: id, error: err)
    } catch let err as IMsgError {
      switch err {
      case .invalidService, .invalidChatTarget:
        output.sendError(
          id: id,
          error: RPCError.invalidParams(err.errorDescription ?? "invalid params")
        )
      default:
        output.sendError(id: id, error: RPCError.internalError(err.localizedDescription))
      }
    } catch {
      output.sendError(id: id, error: RPCError.internalError(error.localizedDescription))
    }
  }

  private func respond(id: Any?, result: Any) {
    guard let id else { return }
    output.sendResponse(id: id, result: result)
  }

  private func handleSend(params: [String: Any], id: Any?) async throws {
    let text = stringParam(params["text"]) ?? ""
    let file = stringParam(params["file"]) ?? ""
    if stringParam(params["service"]) != nil {
      throw RPCError.invalidParams(
        "service is no longer supported for send; imsg-plus sends through the IMCore bridge")
    }
    if stringParam(params["region"]) != nil {
      throw RPCError.invalidParams(
        "region is no longer supported for send; imsg-plus sends through the IMCore bridge")
    }

    let chatID = int64Param(params["chat_id"])
    let chatIdentifier = stringParam(params["chat_identifier"]) ?? ""
    let chatGUID = stringParam(params["chat_guid"]) ?? ""
    let hasChatTarget = chatID != nil || !chatIdentifier.isEmpty || !chatGUID.isEmpty
    let recipient = stringParam(params["to"]) ?? ""
    if hasChatTarget && !recipient.isEmpty {
      throw RPCError.invalidParams("use to or chat_*; not both")
    }
    if !hasChatTarget && recipient.isEmpty {
      throw RPCError.invalidParams("to is required for direct sends")
    }

    let markdownText = stringParam(params["markdown_text"])
    let extensionPayload = try parseExtensionPayload(params: params)
    if text.isEmpty && file.isEmpty && (markdownText ?? "").isEmpty && extensionPayload == nil {
      throw RPCError.invalidParams("text, markdown_text, file, or extension payload is required")
    }

    var resolvedChatIdentifier = chatIdentifier
    var resolvedChatGUID = chatGUID
    if let chatID {
      guard let info = try cache.info(chatID: chatID) else {
        throw RPCError.invalidParams("unknown chat_id \(chatID)")
      }
      resolvedChatIdentifier = info.identifier
      resolvedChatGUID = info.guid
    }
    if hasChatTarget && resolvedChatIdentifier.isEmpty && resolvedChatGUID.isEmpty {
      throw RPCError.invalidParams("missing chat identifier or guid")
    }

    // Auto-typing: simulate typing before sending
    if autoTyping && bridgeAvailable {
      let typingHandle = resolveTypingHandle(
        recipient: recipient,
        chatIdentifier: resolvedChatIdentifier,
        chatGUID: resolvedChatGUID
      )
      if let handle = typingHandle {
        do {
          try await IMCoreBridge.shared.setTyping(for: handle, typing: true)
          if verbose {
            FileHandle.standardError.write(Data("[auto-typing] ON for \(handle)\n".utf8))
          }
          // Delay based on message length: ~1.5s base + up to 2.5s for longer messages, cap at 4s
          let charCount = Double(text.count)
          let baseDelay = 1.5
          let extraDelay = min(charCount / 80.0 * 2.5, 2.5)
          let totalDelay = min(baseDelay + extraDelay, 4.0)
          try await Task.sleep(nanoseconds: UInt64(totalDelay * 1_000_000_000))
        } catch {
          if verbose {
            FileHandle.standardError.write(Data("[auto-typing] error: \(error)\n".utf8))
          }
        }
      }
    }

    // Parse optional reply_to_guid
    let replyToGUID = stringParam(params["reply_to_guid"])

    // Parse optional effect
    let effectStr = stringParam(params["effect"])
    var effect: MessageEffect? = nil
    if let effectStr, !effectStr.isEmpty {
      guard let parsed = MessageEffect.from(string: effectStr) else {
        throw RPCError.invalidParams(
          "invalid effect: '\(effectStr)'. Valid: gentle, loud, slam, invisibleink, confetti, balloons, fireworks, heart, lasers, echo, spotlight, sparkles, shootingstar"
        )
      }
      effect = parsed
    }

    guard bridgeAvailable else {
      throw RPCError.internalError("IMCoreBridge not available (required for send)")
    }

    let handle = resolveTypingHandle(
      recipient: recipient,
      chatIdentifier: resolvedChatIdentifier,
      chatGUID: resolvedChatGUID
    )
    guard let handle else {
      throw RPCError.invalidParams("missing send handle")
    }
    let attachment: String? = file.isEmpty ? nil : file

    let sendStartedAt = Date()
    do {
      let bridgeResult = try await bridgeSendMessage(
        handle, text, markdownText, attachment, effect, replyToGUID, extensionPayload)
      let transientGUID =
        stringParam(bridgeResult["guid"])
        ?? stringParam(bridgeResult["message_guid"])
        ?? stringParam(bridgeResult["messageGUID"])
      let messageGUID = await resolvePersistedExtensionGUID(
        chatID: chatID,
        extensionPayload: extensionPayload,
        since: sendStartedAt
      ) ?? transientGUID

      // Turn off typing after send (fire-and-forget)
      if autoTyping && bridgeAvailable {
        let typingHandle = resolveTypingHandle(
          recipient: recipient,
          chatIdentifier: resolvedChatIdentifier,
          chatGUID: resolvedChatGUID
        )
        if let handle = typingHandle {
          let localVerbose = verbose
          Task {
            do {
              try await IMCoreBridge.shared.setTyping(for: handle, typing: false)
              if localVerbose {
                FileHandle.standardError.write(Data("[auto-typing] OFF for \(handle)\n".utf8))
              }
            } catch {
              if localVerbose {
                FileHandle.standardError.write(Data("[auto-typing] off error: \(error)\n".utf8))
              }
            }
          }
        }
      }

      var result: [String: Any] = ["ok": true]
      if let effect {
        result["effect"] = effect.displayName
      }
      if extensionPayload != nil {
        result["extension_payload"] = true
      }
      if let messageGUID, !messageGUID.isEmpty {
        result["guid"] = messageGUID
      }
      if let transientGUID, let messageGUID, transientGUID != messageGUID {
        result["transient_guid"] = transientGUID
      }
      respond(id: id, result: result)
    } catch {
      throw RPCError.internalError(describeBridgeSendError(error))
    }
  }

  private func resolvePersistedExtensionGUID(
    chatID: Int64?,
    extensionPayload: MessageExtensionPayload?,
    since: Date
  ) async -> String? {
    guard let extensionPayload else {
      return nil
    }
    let querySince = since.addingTimeInterval(-5)
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
      if let guid = try? store.recentOutgoingExtensionMessageGUID(
        chatID: chatID,
        balloonBundleID: extensionPayload.balloonBundleID,
        payloadData: extensionPayload.payloadData,
        since: querySince
      ), !guid.isEmpty {
        return guid
      }
      try? await Task.sleep(nanoseconds: 250_000_000)
    }
    return nil
  }

  private static func defaultBridgeSendMessage(
    handle: String,
    text: String,
    markdownText: String?,
    attachment: String?,
    effect: MessageEffect?,
    replyToGUID: String?,
    extensionPayload: MessageExtensionPayload?
  ) async throws -> [String: Any] {
    if let markdownText, !markdownText.isEmpty,
      let attrData = MarkdownComposer.compose(markdownText)
    {
      return try await IMCoreBridge.shared.sendRichMessage(
        handle: handle,
        attributedText: attrData,
        attachment: attachment,
        effect: effect,
        replyToGUID: replyToGUID,
        extensionPayload: extensionPayload
      )
    }

    let sendText = text.isEmpty ? (markdownText ?? "") : text
    return try await IMCoreBridge.shared.sendMessage(
      handle: handle,
      text: sendText,
      attachment: attachment,
      effect: effect,
      replyToGUID: replyToGUID,
      extensionPayload: extensionPayload
    )
  }

  private func parseExtensionPayload(params: [String: Any]) throws -> MessageExtensionPayload? {
    let balloonBundleID = stringParam(params["balloon_bundle_id"]) ?? ""
    let payloadDataBase64 =
      stringParam(params["payload_data_base64"])
      ?? stringParam(params["payload_data"])
      ?? ""
    let payloadFile = stringParam(params["payload_file"]) ?? ""

    if payloadDataBase64.isEmpty && payloadFile.isEmpty {
      if !balloonBundleID.isEmpty {
        throw RPCError.invalidParams(
          "balloon_bundle_id requires payload_data_base64 or payload_file")
      }
      return nil
    }
    if payloadDataBase64.isEmpty == payloadFile.isEmpty {
      throw RPCError.invalidParams("use exactly one of payload_data_base64 or payload_file")
    }
    guard !balloonBundleID.isEmpty else {
      throw RPCError.invalidParams("balloon_bundle_id is required with extension payload data")
    }

    let payloadData: Data
    if !payloadDataBase64.isEmpty {
      guard let decoded = Data(base64Encoded: payloadDataBase64) else {
        throw RPCError.invalidParams("payload_data_base64 is not valid base64")
      }
      payloadData = decoded
    } else {
      do {
        payloadData = try Data(contentsOf: URL(fileURLWithPath: payloadFile))
      } catch {
        throw RPCError.invalidParams("could not read payload_file: \(error.localizedDescription)")
      }
    }

    guard !payloadData.isEmpty else {
      throw RPCError.invalidParams("extension payload data is empty")
    }

    return MessageExtensionPayload(balloonBundleID: balloonBundleID, payloadData: payloadData)
  }

  private func describeBridgeSendError(_ error: Error) -> String {
    if let bridgeError = error as? IMCoreBridgeError {
      return bridgeError.description
    }
    return error.localizedDescription
  }

  private func handleTypingSet(params: [String: Any], id: Any?) async throws {
    guard let handle = stringParam(params["handle"]), !handle.isEmpty else {
      throw RPCError.invalidParams("handle is required")
    }
    guard let state = stringParam(params["state"]), state == "on" || state == "off" else {
      throw RPCError.invalidParams("state must be 'on' or 'off'")
    }
    guard bridgeAvailable else {
      throw RPCError.internalError("IMCoreBridge not available")
    }
    try await IMCoreBridge.shared.setTyping(for: handle, typing: state == "on")
    respond(id: id, result: ["ok": true])
  }

  private func handleMarkRead(params: [String: Any], id: Any?) async throws {
    guard let handle = stringParam(params["handle"]), !handle.isEmpty else {
      throw RPCError.invalidParams("handle is required")
    }
    guard bridgeAvailable else {
      throw RPCError.internalError("IMCoreBridge not available")
    }
    try await IMCoreBridge.shared.markAsRead(handle: handle)
    respond(id: id, result: ["ok": true])
  }

  private func handleTapbackSend(params: [String: Any], id: Any?) async throws {
    guard let handle = stringParam(params["handle"]), !handle.isEmpty else {
      throw RPCError.invalidParams("handle is required")
    }
    guard let guid = stringParam(params["guid"]), !guid.isEmpty else {
      throw RPCError.invalidParams("guid is required (message GUID to react to)")
    }
    guard let typeStr = stringParam(params["type"]), !typeStr.isEmpty else {
      throw RPCError.invalidParams(
        "type is required (love, thumbsup, thumbsdown, haha, emphasis, question, or any emoji)")
    }
    let remove = boolParam(params["remove"]) ?? false
    guard let tapbackType = TapbackType.from(string: typeStr, remove: remove) else {
      throw RPCError.invalidParams(
        "invalid reaction type: '\(typeStr)'. Valid: love, thumbsup, thumbsdown, haha, emphasis, question, or any emoji"
      )
    }
    guard bridgeAvailable else {
      throw RPCError.internalError("IMCoreBridge not available")
    }
    try await IMCoreBridge.shared.sendTapback(to: handle, messageGUID: guid, type: tapbackType)
    var result: [String: Any] = [
      "ok": true,
      "handle": handle,
      "guid": guid,
      "type": tapbackType.displayName,
      "action": remove ? "removed" : "added",
    ]
    if tapbackType.isCustom {
      result["emoji"] = tapbackType.emoji
    }
    respond(id: id, result: result)
  }

  private func handleGroupCreate(params: [String: Any], id: Any?) async throws {
    let addresses = stringArrayParam(params["addresses"])
    if addresses.isEmpty {
      throw RPCError.invalidParams("addresses is required (array of phone/email)")
    }
    guard bridgeAvailable else {
      throw RPCError.internalError("IMCoreBridge not available")
    }
    let name = stringParam(params["name"])
    let text = stringParam(params["text"])
    let service = stringParam(params["service"]) ?? "imessage"
    let result = try await IMCoreBridge.shared.createChat(
      addresses: addresses,
      name: name,
      message: text,
      service: service
    )
    respond(id: id, result: result)
  }

  private func handleGroupRename(params: [String: Any], id: Any?) async throws {
    guard let handle = stringParam(params["handle"]), !handle.isEmpty else {
      throw RPCError.invalidParams("handle is required")
    }
    guard let name = stringParam(params["name"]), !name.isEmpty else {
      throw RPCError.invalidParams("name is required")
    }
    guard bridgeAvailable else {
      throw RPCError.internalError("IMCoreBridge not available")
    }
    try await IMCoreBridge.shared.renameChat(handle: handle, name: name)
    respond(id: id, result: ["ok": true, "handle": handle, "name": name])
  }

  private func handleMessageEdit(params: [String: Any], id: Any?) async throws {
    guard let handle = stringParam(params["handle"]), !handle.isEmpty else {
      throw RPCError.invalidParams("handle is required")
    }
    guard let guid = stringParam(params["guid"]), !guid.isEmpty else {
      throw RPCError.invalidParams("guid is required")
    }
    let text = stringParam(params["text"]) ?? ""
    let markdownText = stringParam(params["markdown_text"])
    let extensionPayload = try parseExtensionPayload(params: params)
    if text.isEmpty && (markdownText ?? "").isEmpty && extensionPayload == nil {
      throw RPCError.invalidParams("text, markdown_text, or extension payload is required")
    }
    guard bridgeAvailable else {
      throw RPCError.internalError("IMCoreBridge not available")
    }
    var attrData: Data? = nil
    if let markdownText, !markdownText.isEmpty {
      attrData = MarkdownComposer.compose(markdownText)
    }
    let editText = text.isEmpty ? (markdownText ?? "") : text
    let bridgeResult = try await IMCoreBridge.shared.editMessage(
      handle: handle,
      messageGUID: guid,
      newText: editText,
      attributedText: attrData,
      extensionPayload: extensionPayload)
    var result: [String: Any] = ["ok": true, "handle": handle, "guid": guid, "action": "edited"]
    if let method = stringParam(bridgeResult["method"]) {
      result["method"] = method
    }
    if extensionPayload != nil {
      result["extension_payload"] = true
    }
    respond(id: id, result: result)
  }

  private func handleMessageUnsend(params: [String: Any], id: Any?) async throws {
    guard let handle = stringParam(params["handle"]), !handle.isEmpty else {
      throw RPCError.invalidParams("handle is required")
    }
    guard let guid = stringParam(params["guid"]), !guid.isEmpty else {
      throw RPCError.invalidParams("guid is required")
    }
    guard bridgeAvailable else {
      throw RPCError.internalError("IMCoreBridge not available")
    }
    let partIndex = intParam(params["part_index"]) ?? 0
    try await IMCoreBridge.shared.unsendMessage(
      handle: handle, messageGUID: guid, partIndex: partIndex)
    respond(
      id: id, result: ["ok": true, "handle": handle, "guid": guid, "action": "unsent"])
  }

  private func handleLocationsList(params: [String: Any], id: Any?) async throws {
    guard bridgeAvailable else {
      throw RPCError.internalError("IMCoreBridge not available")
    }

    let handle = stringParam(params["handle"])
    let raw = boolParam(params["raw"]) ?? false

    if raw {
      let locations = try await getLocationsResponse(handle, true)
      respond(id: id, result: ["locations": locations])
      return
    }

    let locations = try await getLocations(handle).map(locationPayload)
    respond(id: id, result: ["locations": locations])
  }

  /// Resolve the best handle for typing/read from send params
  private func resolveTypingHandle(recipient: String, chatIdentifier: String, chatGUID: String)
    -> String?
  {
    if !recipient.isEmpty { return recipient }
    if !chatIdentifier.isEmpty { return chatIdentifier }
    if !chatGUID.isEmpty { return chatGUID }
    return nil
  }

}

private func buildMessagePayload(
  store: MessageStore,
  cache: ChatCache,
  message: Message,
  includeAttachments: Bool,
  contactResolver: ContactResolving? = nil
) throws -> [String: Any] {
  let chatInfo = try cache.info(chatID: message.chatID)
  let participants = try cache.participants(chatID: message.chatID)
  let attachments = includeAttachments ? try store.attachments(for: message.rowID) : []
  let reactions = includeAttachments ? try store.reactions(for: message.rowID) : []
  let senderName = message.isFromMe ? nil : contactResolver?.resolve(handle: message.sender)
  return messagePayload(
    message: message,
    chatInfo: chatInfo,
    participants: participants,
    attachments: attachments,
    reactions: reactions,
    senderName: senderName,
    markdownText: message.markdownText
  )
}

private final class RPCWriter: RPCOutput, @unchecked Sendable {
  private let queue = DispatchQueue(label: "imsg.rpc.writer")

  func sendResponse(id: Any, result: Any) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
  }

  func sendError(id: Any?, error: RPCError) {
    let payload: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id ?? NSNull(),
      "error": error.asDictionary(),
    ]
    send(payload)
  }

  func sendNotification(method: String, params: Any) {
    send(["jsonrpc": "2.0", "method": method, "params": params])
  }

  private func send(_ object: Any) {
    queue.sync {
      do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        if let output = String(data: data, encoding: .utf8) {
          FileHandle.standardOutput.write(Data(output.utf8))
          FileHandle.standardOutput.write(Data("\n".utf8))
        }
      } catch {
        if let fallback =
          "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"write failed\"}}\n"
          .data(using: .utf8)
        {
          FileHandle.standardOutput.write(fallback)
        }
      }
    }
  }
}

struct RPCError: Error {
  let code: Int
  let message: String
  let data: String?

  static func parseError(_ message: String) -> RPCError {
    RPCError(code: -32700, message: "Parse error", data: message)
  }

  static func invalidRequest(_ message: String) -> RPCError {
    RPCError(code: -32600, message: "Invalid Request", data: message)
  }

  static func methodNotFound(_ method: String) -> RPCError {
    RPCError(code: -32601, message: "Method not found", data: method)
  }

  static func invalidParams(_ message: String) -> RPCError {
    RPCError(code: -32602, message: "Invalid params", data: message)
  }

  static func internalError(_ message: String) -> RPCError {
    RPCError(code: -32603, message: "Internal error", data: message)
  }

  func asDictionary() -> [String: Any] {
    var dict: [String: Any] = [
      "code": code,
      "message": message,
    ]
    if let data {
      dict["data"] = data
    }
    return dict
  }
}

private final class ChatCache: @unchecked Sendable {
  private let store: MessageStore
  private var infoCache: [Int64: ChatInfo] = [:]

  init(store: MessageStore) {
    self.store = store
  }

  func info(chatID: Int64) throws -> ChatInfo? {
    // Chat identity is authority evidence in watch payloads. Refresh it for
    // every delivered row instead of trusting a process-long display cache.
    if let info = try store.chatInfo(chatID: chatID) {
      infoCache[chatID] = info
      return info
    }
    infoCache.removeValue(forKey: chatID)
    return nil
  }

  func participants(chatID: Int64) throws -> [String] {
    // Membership is security evidence, not display metadata. Query it for every
    // delivered row so a long-lived subscription cannot reuse a stale audience.
    try store.participants(chatID: chatID)
  }
}
