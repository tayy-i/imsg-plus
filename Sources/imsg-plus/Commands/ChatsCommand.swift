import Commander
import Foundation
import IMsgCore

enum ChatsCommand {
  static let spec = CommandSpec(
    name: "chats",
    abstract: "List recent conversations",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "limit", names: [.long("limit")], help: "Number of chats to list")
        ]
      )
    ),
    usageExamples: [
      "imsg chats --limit 5",
      "imsg chats --limit 5 --json",
    ]
  ) { values, runtime in
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let limit = values.optionInt("limit") ?? 20
    let store = try MessageStore(path: dbPath)
    let chats = try store.listChats(limit: limit)

    if runtime.jsonOutput {
      let resolver = ContactResolver()
      for chat in chats {
        let participants = (try? store.participants(chatID: chat.id)) ?? []
        var names: [String: String] = [:]
        for handle in participants {
          if let name = resolver.resolve(handle: handle) {
            names[handle] = name
          }
        }
        try JSONLines.print(ChatPayload(chat: chat, participantNames: names.isEmpty ? nil : names))
      }
      return
    }

    for chat in chats {
      let last = CLIISO8601.format(chat.lastMessageAt)
      Swift.print("[\(chat.id)] \(chat.name) (\(chat.identifier)) last=\(last)")
    }
  }
}
