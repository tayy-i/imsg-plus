import Commander
import Foundation
import IMsgCore

enum ReactCommand {
  static let spec = CommandSpec(
    name: "react",
    abstract: "Send tapback reactions to messages",
    discussion: """
      Add or remove tapback reactions to specific messages. Use the message GUID
      from history or watch commands.

      Standard reaction types:
      • love/heart - ❤️
      • thumbsup/like - 👍
      • thumbsdown/dislike - 👎
      • haha/laugh - 😂
      • emphasis/!! - ‼️
      • question/? - ❓

      You can also use any emoji as a custom reaction (e.g. 🎉, 🔥, 👀).

      Add --remove flag to remove an existing reaction.

      Note: Requires advanced permissions (SIP disabled) for full functionality.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(
            label: "handle", names: [.long("handle")],
            help: "Phone number, email, or chat identifier"),
          .make(label: "guid", names: [.long("guid")], help: "Message GUID to react to"),
          .make(
            label: "type", names: [.long("type")],
            help: "Reaction type: love, thumbsup, thumbsdown, haha, emphasis, question, or any emoji"),
        ],
        flags: [
          .make(
            label: "remove", names: [.long("remove")],
            help: "Remove the reaction instead of adding it")
        ]
      )
    ),
    usageExamples: [
      "imsg-plus react --handle +14155551234 --guid ABC123-456 --type love",
      "imsg-plus react --handle john@example.com --guid XYZ789 --type thumbsup",
      "imsg-plus react --handle +14155551234 --guid ABC123-456 --type haha --remove",
      "imsg-plus react --handle chat123456789 --guid MSG-001 --type question",
      "imsg-plus react --handle +14155551234 --guid ABC123-456 --type 🎉",
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
    guard let typeStr = values.option("type") else {
      throw IMsgError.invalidArgument("--type is required")
    }
    let remove = values.flag("remove")

    guard let tapbackType = TapbackType.from(string: typeStr, remove: remove) else {
      throw IMsgError.invalidArgument(
        """
        Invalid reaction type: '\(typeStr)'
        Valid types: love, thumbsup, thumbsdown, haha, emphasis, question, or any emoji
        """)
    }

    let bridge = IMCoreBridge.shared
    let availability = bridge.checkAvailability()

    if !availability.available {
      print("⚠️  \(availability.message)")
      print("\nTapback reactions require advanced features to be enabled.")
      print("See: https://github.com/steipete/imsg#advanced-features")
      return
    }

    do {
      try await bridge.sendTapback(to: handle, messageGUID: guid, type: tapbackType)

      let action = remove ? "removed" : "added"
      let emoji = tapbackType.emoji

      if runtime.jsonOutput {
        let output: [String: Any] = [
          "success": true,
          "handle": handle,
          "message_guid": guid,
          "reaction": tapbackType.displayName,
          "action": action,
          "emoji": emoji,
          "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        print(JSONSerialization.string(from: output))
      } else {
        print("\(emoji) Reaction \(action): \(tapbackType.displayName) on message \(guid)")
      }
    } catch let error as IMCoreBridgeError {
      if runtime.jsonOutput {
        let output: [String: Any] = [
          "success": false,
          "error": error.description,
          "handle": handle,
          "message_guid": guid,
          "reaction": tapbackType.displayName,
        ]
        print(JSONSerialization.string(from: output))
      } else {
        print("❌ \(error)")
      }
      throw error
    }
  }

}
