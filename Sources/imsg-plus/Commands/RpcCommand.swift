import Commander
import Foundation
import IMsgCore

enum RpcCommand {
  static let spec = CommandSpec(
    name: "rpc",
    abstract: "Run JSON-RPC over stdin/stdout",
    discussion: nil,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(
            label: "allowedChat", names: [.long("allowed-chat")],
            help: "Lock subscriptions and outbound Messages operations to one exact chat"),
          .make(
            label: "expectedLocalAccountFingerprint",
            names: [.long("expected-local-account-fingerprint")],
            help: "Require the enrolled local Messages account fingerprint"),
          .make(
            label: "expectedHelperSHA256", names: [.long("expected-helper-sha256")],
            help: "Require the enrolled loaded helper SHA-256"),
          .make(
            label: "expectedChatFingerprint", names: [.long("expected-chat-fingerprint")],
            help: "Require the enrolled direct-chat fingerprint"),
        ],
        flags: [
          .make(
            label: "noAutoRead", names: [.long("no-auto-read")],
            help: "Disable automatic read receipts"),
          .make(
            label: "noAutoTyping", names: [.long("no-auto-typing")],
            help: "Disable automatic typing indicators on send"),
        ]
      )
    ),
    usageExamples: [
      "imsg rpc",
      "imsg rpc --db ~/Library/Messages/chat.db",
      "imsg rpc --no-auto-read",
      "imsg rpc --no-auto-typing",
      "imsg rpc --allowed-chat user@example.com",
    ]
  ) { values, runtime in
    let dbPath = values.option("db") ?? MessageStore.defaultPath
    let store = try MessageStore(path: dbPath)
    let autoRead: Bool? = values.flag("noAutoRead") ? false : nil
    let autoTyping: Bool? = values.flag("noAutoTyping") ? false : nil
    let allowedChat = values.option("allowedChat")?.trimmingCharacters(in: .whitespacesAndNewlines)
    if values.option("allowedChat") != nil && (allowedChat ?? "").isEmpty {
      throw IMsgError.invalidArgument("allowed-chat must not be empty")
    }
    let expectedLocalAccountFingerprint = values.option("expectedLocalAccountFingerprint")
    let expectedHelperSHA256 = values.option("expectedHelperSHA256")
    let expectedChatFingerprint = values.option("expectedChatFingerprint")
    if allowedChat != nil {
      guard isSHA256(expectedLocalAccountFingerprint), isSHA256(expectedHelperSHA256) else {
        throw IMsgError.invalidArgument(
          "allowed-chat requires expected-local-account-fingerprint and expected-helper-sha256")
      }
      if expectedChatFingerprint != nil && !isSHA256(expectedChatFingerprint) {
        throw IMsgError.invalidArgument("expected-chat-fingerprint must be a lowercase SHA-256")
      }
    } else if expectedLocalAccountFingerprint != nil || expectedHelperSHA256 != nil
      || expectedChatFingerprint != nil
    {
      throw IMsgError.invalidArgument("identity fingerprints require allowed-chat")
    }
    let server = RPCServer(
      store: store,
      verbose: runtime.verbose,
      autoRead: autoRead,
      autoTyping: autoTyping,
      allowedChat: allowedChat,
      expectedLocalAccountFingerprint: expectedLocalAccountFingerprint,
      expectedHelperSHA256: expectedHelperSHA256,
      expectedChatFingerprint: expectedChatFingerprint
    )
    try await server.run()
  }

  private static func isSHA256(_ value: String?) -> Bool {
    guard let value, value.count == 64 else { return false }
    return value.allSatisfy { "0123456789abcdef".contains($0) }
  }
}
