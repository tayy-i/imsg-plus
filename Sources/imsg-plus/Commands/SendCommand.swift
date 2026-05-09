import Commander
import Foundation
import IMsgCore

enum SendCommand {
  static let spec = CommandSpec(
    name: "send",
    abstract: "Send a message (text and/or attachment)",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "to", names: [.long("to")], help: "phone number or email"),
          .make(label: "chatID", names: [.long("chat-id")], help: "chat rowid"),
          .make(
            label: "chatIdentifier", names: [.long("chat-identifier")],
            help: "chat identifier (e.g. iMessage;+;chat...)"),
          .make(label: "chatGUID", names: [.long("chat-guid")], help: "chat guid"),
          .make(label: "text", names: [.long("text")], help: "message body"),
          .make(label: "file", names: [.long("file")], help: "path to attachment"),
          .make(
            label: "effect", names: [.long("effect")],
            help:
              "Send effect: gentle, loud, slam, invisibleink, confetti, balloons, fireworks, heart, lasers, echo, spotlight, sparkles, shootingstar"
          ),
          .make(
            label: "replyTo", names: [.long("reply-to")],
            help: "Message GUID to reply to (thread reply)"),
        ],
        flags: [
          .make(
            label: "markdown", names: [.long("markdown")],
            help: "Parse text as markdown and send with formatting")
        ]
      )
    ),
    usageExamples: [
      "imsg send --to +14155551212 --text \"hi\"",
      "imsg send --to +14155551212 --text \"hi\" --file ~/Desktop/pic.jpg",
      "imsg send --chat-id 1 --text \"hi\"",
      "imsg send --to +14155551212 --text \"happy birthday!\" --effect balloons",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(
    values: ParsedValues,
    runtime: RuntimeOptions,
    bridgeAvailable: Bool = IMCoreBridge.shared.isAvailable,
    bridgeSendMessage:
      @escaping (
        String, String, String?, String?, MessageEffect?, String?
      ) async throws -> Void = SendCommand.defaultBridgeSendMessage,
    storeFactory: @escaping (String) throws -> MessageStore = { try MessageStore(path: $0) }
  ) async throws {
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let recipient = values.option("to") ?? ""
    let chatID = values.optionInt64("chatID")
    let chatIdentifier = values.option("chatIdentifier") ?? ""
    let chatGUID = values.option("chatGUID") ?? ""
    let hasChatTarget = chatID != nil || !chatIdentifier.isEmpty || !chatGUID.isEmpty
    if hasChatTarget && !recipient.isEmpty {
      throw ParsedValuesError.invalidOption("to")
    }
    if !hasChatTarget && recipient.isEmpty {
      throw ParsedValuesError.missingOption("to")
    }

    let text = values.option("text") ?? ""
    let file = values.option("file") ?? ""
    if text.isEmpty && file.isEmpty {
      throw ParsedValuesError.missingOption("text or file")
    }
    var resolvedChatIdentifier = chatIdentifier
    var resolvedChatGUID = chatGUID
    if let chatID {
      let store = try storeFactory(dbPath)
      guard let info = try store.chatInfo(chatID: chatID) else {
        throw IMsgError.invalidChatTarget("Unknown chat id \(chatID)")
      }
      resolvedChatIdentifier = info.identifier
      resolvedChatGUID = info.guid
    }
    if hasChatTarget && resolvedChatIdentifier.isEmpty && resolvedChatGUID.isEmpty {
      throw IMsgError.invalidChatTarget("Missing chat identifier or guid")
    }

    let useMarkdown = values.flag("markdown")
    let replyToGUID = values.option("replyTo") ?? ""
    let effectStr = values.option("effect") ?? ""
    var effect: MessageEffect? = nil
    if !effectStr.isEmpty {
      guard let parsed = MessageEffect.from(string: effectStr) else {
        throw IMsgError.invalidArgument(
          "Unknown effect '\(effectStr)'. Valid: gentle, loud, slam, invisibleink, confetti, balloons, fireworks, heart, lasers, echo, spotlight, sparkles, shootingstar"
        )
      }
      effect = parsed
    }

    let replyGUID: String? = replyToGUID.isEmpty ? nil : replyToGUID
    let attachment: String? = file.isEmpty ? nil : file

    let handle =
      resolvedChatGUID.isEmpty
      ? (resolvedChatIdentifier.isEmpty ? recipient : resolvedChatIdentifier)
      : resolvedChatGUID

    guard !handle.isEmpty else {
      throw IMsgError.invalidChatTarget("Missing send handle")
    }
    guard bridgeAvailable else {
      throw IMsgError.invalidArgument("IMCoreBridge not available. Run `imsg-plus launch` before sending.")
    }

    let markdownText = useMarkdown ? text : nil
    let sendText = useMarkdown ? "" : text
    do {
      try await bridgeSendMessage(handle, sendText, markdownText, attachment, effect, replyGUID)
    } catch {
      throw IMsgError.invalidArgument(describeBridgeSendError(error))
    }

    if runtime.jsonOutput {
      var result: [String: String] = ["status": "sent"]
      if useMarkdown { result["markdown"] = "true" }
      if let effect { result["effect"] = effect.displayName }
      try JSONLines.print(result)
    } else {
      var parts = ["sent"]
      if useMarkdown { parts.append("with formatting") }
      if let effect { parts.append("with \(effect.displayName) effect") }
      Swift.print(parts.joined(separator: " "))
    }
  }

  private static func defaultBridgeSendMessage(
    handle: String,
    text: String,
    markdownText: String?,
    attachment: String?,
    effect: MessageEffect?,
    replyToGUID: String?
  ) async throws {
    if let markdownText, !markdownText.isEmpty,
      let attrData = MarkdownComposer.compose(markdownText)
    {
      try await IMCoreBridge.shared.sendRichMessage(
        handle: handle,
        attributedText: attrData,
        attachment: attachment,
        effect: effect,
        replyToGUID: replyToGUID
      )
      return
    }

    let sendText = text.isEmpty ? (markdownText ?? "") : text
    try await IMCoreBridge.shared.sendMessage(
      handle: handle,
      text: sendText,
      attachment: attachment,
      effect: effect,
      replyToGUID: replyToGUID
    )
  }

  private static func describeBridgeSendError(_ error: Error) -> String {
    if let bridgeError = error as? IMCoreBridgeError {
      return bridgeError.description
    }
    return error.localizedDescription
  }
}
