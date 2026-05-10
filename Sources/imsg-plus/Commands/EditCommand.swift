import Commander
import Foundation
import IMsgCore

enum EditCommand {
  static let spec = CommandSpec(
    name: "edit",
    abstract: "Edit or unsend a message",
    discussion: """
      Edit the text of a previously sent message, or unsend it entirely.
      Requires the message GUID (from history or watch commands) and the
      chat handle.

      Note: Requires advanced permissions (SIP disabled) for full functionality.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(
            label: "handle", names: [.long("handle")],
            help: "Phone number, email, or chat identifier"),
          .make(label: "guid", names: [.long("guid")], help: "Message GUID to edit"),
          .make(label: "text", names: [.long("text")], help: "New message text"),
          .make(
            label: "balloonBundleID", names: [.long("balloon-bundle-id")],
            help: "experimental replacement Messages app-extension balloon bundle id"),
          .make(
            label: "payloadDataBase64", names: [.long("payload-data-base64")],
            help: "experimental replacement Messages app-extension payload_data blob"),
          .make(
            label: "payloadFile", names: [.long("payload-file")],
            help: "experimental replacement Messages app-extension payload_data file"),
        ],
        flags: [
          .make(
            label: "unsend", names: [.long("unsend")],
            help: "Unsend (retract) the message instead of editing"),
          .make(
            label: "markdown", names: [.long("markdown")],
            help: "Parse text as markdown and send with formatting"),
        ]
      )
    ),
    usageExamples: [
      "imsg edit --handle +14155551234 --guid ABC123-456 --text \"corrected text\"",
      "imsg edit --handle +14155551234 --guid ABC123-456 --unsend",
      "imsg edit --handle +14155551234 --guid ABC123-456 --text \"**bold**\" --markdown",
      "imsg edit --handle chat123 --guid ABC123-456 --balloon-bundle-id com.apple.messages.MSMessageExtensionBalloonPlugin:TEAMID:com.example.MessagesExtension --payload-file payload.bplist",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let handle = values.option("handle") else {
      throw IMsgError.invalidArgument("--handle is required")
    }
    guard let guid = values.option("guid") else {
      throw IMsgError.invalidArgument("--guid is required")
    }

    let unsend = values.flag("unsend")
    let text = values.option("text") ?? ""
    let useMarkdown = values.flag("markdown")
    let extensionPayload = try parseExtensionPayload(values: values)

    if unsend && (!text.isEmpty || extensionPayload != nil) {
      throw IMsgError.invalidArgument("--unsend and edit content are mutually exclusive")
    }
    if !unsend && text.isEmpty && extensionPayload == nil {
      throw IMsgError.invalidArgument("--text, extension payload, or --unsend is required")
    }

    let bridge = IMCoreBridge.shared
    let availability = bridge.checkAvailability()

    if !availability.available {
      print("⚠️  \(availability.message)")
      print("\nEdit/unsend requires advanced features to be enabled.")
      return
    }

    do {
      if unsend {
        try await bridge.unsendMessage(handle: handle, messageGUID: guid)

        if runtime.jsonOutput {
          let output: [String: Any] = [
            "success": true,
            "handle": handle,
            "message_guid": guid,
            "action": "unsent",
          ]
          print(JSONSerialization.string(from: output))
        } else {
          print("Unsent message \(guid)")
        }
      } else {
        var attrData: Data? = nil
        if useMarkdown {
          attrData = MarkdownComposer.compose(text)
        }
        let bridgeResult = try await bridge.editMessage(
          handle: handle,
          messageGUID: guid,
          newText: text,
          attributedText: attrData,
          extensionPayload: extensionPayload)

        if runtime.jsonOutput {
          var output: [String: Any] = [
            "success": true,
            "handle": handle,
            "message_guid": guid,
            "action": "edited",
          ]
          if useMarkdown { output["markdown"] = true }
          if extensionPayload != nil { output["extension_payload"] = true }
          if let method = bridgeResult["method"] as? String { output["method"] = method }
          print(JSONSerialization.string(from: output))
        } else {
          print("Edited message \(guid)")
        }
      }
    } catch let error as IMCoreBridgeError {
      if runtime.jsonOutput {
        let output: [String: Any] = [
          "success": false,
          "error": error.description,
          "handle": handle,
          "message_guid": guid,
        ]
        print(JSONSerialization.string(from: output))
      } else {
        print("❌ \(error)")
      }
      throw error
    }
  }

  private static func parseExtensionPayload(values: ParsedValues) throws -> MessageExtensionPayload?
  {
    let balloonBundleID = values.option("balloonBundleID") ?? ""
    let payloadDataBase64 = values.option("payloadDataBase64") ?? ""
    let payloadFile = values.option("payloadFile") ?? ""

    if payloadDataBase64.isEmpty && payloadFile.isEmpty {
      if !balloonBundleID.isEmpty {
        throw IMsgError.invalidArgument(
          "--balloon-bundle-id requires --payload-data-base64 or --payload-file")
      }
      return nil
    }
    if payloadDataBase64.isEmpty == payloadFile.isEmpty {
      throw IMsgError.invalidArgument("Use exactly one of --payload-data-base64 or --payload-file")
    }
    guard !balloonBundleID.isEmpty else {
      throw IMsgError.invalidArgument("--balloon-bundle-id is required with extension payload data")
    }

    let payloadData: Data
    if !payloadDataBase64.isEmpty {
      guard let decoded = Data(base64Encoded: payloadDataBase64) else {
        throw IMsgError.invalidArgument("--payload-data-base64 is not valid base64")
      }
      payloadData = decoded
    } else {
      do {
        payloadData = try Data(contentsOf: URL(fileURLWithPath: payloadFile))
      } catch {
        throw IMsgError.invalidArgument(
          "Could not read --payload-file: \(error.localizedDescription)")
      }
    }

    guard !payloadData.isEmpty else {
      throw IMsgError.invalidArgument("extension payload data is empty")
    }

    return MessageExtensionPayload(balloonBundleID: balloonBundleID, payloadData: payloadData)
  }
}
