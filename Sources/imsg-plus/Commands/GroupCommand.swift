import Commander
import Foundation
import IMsgCore

enum GroupCommand {
  static let spec = CommandSpec(
    name: "group",
    abstract: "Create or rename group chats",
    discussion: """
      Create new group conversations or rename existing ones.
      Requires advanced features (SIP disabled, dylib injected).

      Actions:
        create  Create a new group chat with the given addresses
        rename  Rename an existing group chat
        remove  Remove participants from a group chat

      Note: iMessage reuses existing chats for the same participant set.
      To force a unique group, add a temporary 3rd participant, send a
      message, wait for a reply from another participant to finalize the
      group, then remove the extra participant.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(
            label: "action", names: [.long("action")],
            help: "Action: create or rename"),
          .make(
            label: "addresses", names: [.long("addresses")],
            help: "Comma-separated phone numbers or emails (for create)"),
          .make(
            label: "handle", names: [.long("handle")],
            help: "Chat identifier or GUID (for rename)"),
          .make(
            label: "name", names: [.long("name")],
            help: "Display name for the group"),
          .make(
            label: "text", names: [.long("text")],
            help: "Initial message to send (for create)"),
          .make(
            label: "service", names: [.long("service")],
            help: "Service: imessage or sms (default: imessage)"),
          .make(
            label: "region", names: [.long("region")],
            help: "Region for phone normalization (default: US)"),
        ]
      )
    ),
    usageExamples: [
      "imsg-plus group --action create --addresses +14155551234,+14155555678 --name \"Weekend Plans\"",
      "imsg-plus group --action create --addresses +14155551234 --text \"Hey!\"",
      "imsg-plus group --action rename --handle iMessage;+;chat123 --name \"New Name\"",
      "imsg-plus group --action remove --handle iMessage;+;chat123 --addresses user@example.com",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    guard let action = values.option("action") else {
      throw IMsgError.invalidArgument("--action is required (create or rename)")
    }

    let bridge = IMCoreBridge.shared
    let availability = bridge.checkAvailability()

    if !availability.available {
      print("Group management requires advanced features to be enabled.")
      print(availability.message)
      return
    }

    switch action {
    case "create":
      try await runCreate(values: values, runtime: runtime, bridge: bridge)
    case "rename":
      try await runRename(values: values, runtime: runtime, bridge: bridge)
    case "remove":
      try await runRemove(values: values, runtime: runtime, bridge: bridge)
    default:
      throw IMsgError.invalidArgument(
        "Unknown action: \(action). Use 'create', 'rename', or 'remove'.")
    }
  }

  private static func runCreate(
    values: ParsedValues,
    runtime: RuntimeOptions,
    bridge: IMCoreBridge
  ) async throws {
    guard let addressesRaw = values.option("addresses"), !addressesRaw.isEmpty else {
      throw IMsgError.invalidArgument("--addresses is required for create")
    }

    let region = values.option("region") ?? "US"
    let normalizer = PhoneNumberNormalizer()
    let addresses = addressesRaw.split(separator: ",")
      .map { String($0).trimmingCharacters(in: .whitespaces) }
      .map { normalizer.normalize($0, region: region) }

    let name = values.option("name")
    let text = values.option("text")
    let service = values.option("service") ?? "imessage"

    let result = try await bridge.createChat(
      addresses: addresses,
      name: name,
      message: text,
      service: service
    )

    if runtime.jsonOutput {
      print(JSONSerialization.string(from: result))
    } else {
      let guid = result["guid"] as? String ?? ""
      let identifier = result["identifier"] as? String ?? ""
      let participants = result["participants"] as? [String] ?? []
      print("Chat created:")
      print("  GUID: \(guid)")
      print("  Identifier: \(identifier)")
      print("  Participants: \(participants.joined(separator: ", "))")
      if let name {
        print("  Name: \(name)")
      }
    }
  }

  private static func runRemove(
    values: ParsedValues,
    runtime: RuntimeOptions,
    bridge: IMCoreBridge
  ) async throws {
    guard let handle = values.option("handle"), !handle.isEmpty else {
      throw IMsgError.invalidArgument("--handle is required for remove")
    }
    guard let addressesRaw = values.option("addresses"), !addressesRaw.isEmpty else {
      throw IMsgError.invalidArgument("--addresses is required for remove")
    }

    let region = values.option("region") ?? "US"
    let normalizer = PhoneNumberNormalizer()
    let addresses = addressesRaw.split(separator: ",")
      .map { String($0).trimmingCharacters(in: .whitespaces) }
      .map { normalizer.normalize($0, region: region) }

    try await bridge.removeParticipant(handle: handle, addresses: addresses)

    if runtime.jsonOutput {
      let output: [String: Any] = [
        "success": true,
        "handle": handle,
        "removed": addresses,
      ]
      print(JSONSerialization.string(from: output))
    } else {
      print("Removed \(addresses.count) participant(s) from chat")
    }
  }

  private static func runRename(
    values: ParsedValues,
    runtime: RuntimeOptions,
    bridge: IMCoreBridge
  ) async throws {
    guard let handle = values.option("handle"), !handle.isEmpty else {
      throw IMsgError.invalidArgument("--handle is required for rename")
    }
    guard let name = values.option("name"), !name.isEmpty else {
      throw IMsgError.invalidArgument("--name is required for rename")
    }

    try await bridge.renameChat(handle: handle, name: name)

    if runtime.jsonOutput {
      let output: [String: Any] = [
        "success": true,
        "handle": handle,
        "name": name,
      ]
      print(JSONSerialization.string(from: output))
    } else {
      print("Chat renamed to: \(name)")
    }
  }
}
