import Foundation

/// Tapback reaction types for iMessage
///
/// These values correspond to Apple's IMCore framework's `associatedMessageType` field.
/// - 2000-2005: Add tapback reactions (love, thumbsup, thumbsdown, haha, emphasis, question)
/// - 3000-3005: Remove tapback reactions (add 1000 to the base type)
///
/// Source: BlueBubbles IMCore documentation
/// https://docs.bluebubbles.app/private-api/imcore-documentation
public enum TapbackType: Int, Sendable {
  case love = 2000
  case thumbsUp = 2001
  case thumbsDown = 2002
  case haha = 2003
  case emphasis = 2004
  case question = 2005

  case removeLove = 3000
  case removeThumbsUp = 3001
  case removeThumbsDown = 3002
  case removeHaha = 3003
  case removeEmphasis = 3004
  case removeQuestion = 3005

  public var displayName: String {
    switch self {
    case .love, .removeLove: return "love"
    case .thumbsUp, .removeThumbsUp: return "thumbsup"
    case .thumbsDown, .removeThumbsDown: return "thumbsdown"
    case .haha, .removeHaha: return "haha"
    case .emphasis, .removeEmphasis: return "emphasis"
    case .question, .removeQuestion: return "question"
    }
  }

  public static func from(string: String, remove: Bool = false) -> TapbackType? {
    let offset = remove ? 1000 : 0
    switch string.lowercased() {
    case "love", "heart": return TapbackType(rawValue: 2000 + offset)
    case "thumbsup", "like": return TapbackType(rawValue: 2001 + offset)
    case "thumbsdown", "dislike": return TapbackType(rawValue: 2002 + offset)
    case "haha", "laugh": return TapbackType(rawValue: 2003 + offset)
    case "emphasis", "exclaim", "!!": return TapbackType(rawValue: 2004 + offset)
    case "question", "?": return TapbackType(rawValue: 2005 + offset)
    default: return nil
    }
  }
}

public enum IMCoreBridgeError: Error, CustomStringConvertible {
  case frameworkNotAvailable
  case dylibNotFound
  case connectionFailed(String)
  case chatNotFound(String)
  case messageNotFound(String)
  case operationFailed(String)

  public var description: String {
    switch self {
    case .frameworkNotAvailable:
      return "IMCore framework not available. Advanced features require SIP disabled."
    case .dylibNotFound:
      return
        "imsg-plus-helper.dylib not found. Build with: make build-dylib"
    case .connectionFailed(let error):
      return "Connection to Messages.app failed: \(error)"
    case .chatNotFound(let id):
      return "Chat not found: \(id)"
    case .messageNotFound(let guid):
      return "Message not found: \(guid)"
    case .operationFailed(let reason):
      return "Operation failed: \(reason)"
    }
  }
}

/// Bridge to IMCore via DYLD injection into Messages.app
///
/// This bridge communicates with an injected dylib inside Messages.app
/// via Unix socket IPC. The dylib has full access to IMCore because
/// it runs within the Messages.app context with proper entitlements.
public final class IMCoreBridge: @unchecked Sendable {
  public static let shared = IMCoreBridge()

  private let launcher = MessagesLauncher.shared

  public var isAvailable: Bool {
    // Check if dylib exists
    let possiblePaths = [
      ".build/release/imsg-plus-helper.dylib",
      ".build/debug/imsg-plus-helper.dylib",
      "/usr/local/lib/imsg-plus-helper.dylib",
    ]

    for path in possiblePaths {
      if FileManager.default.fileExists(atPath: path) {
        return true
      }
    }
    return false
  }

  private init() {}

  /// Send a command to the injected helper via MessagesLauncher
  private func sendCommand(action: String, params: [String: Any]) async throws -> [String: Any] {
    do {
      let response = try await launcher.sendCommand(action: action, params: params)

      if response["success"] as? Bool == true {
        return response
      } else {
        let error = response["error"] as? String ?? "Unknown error"

        // Map specific errors
        if error.contains("Chat not found") {
          let handle = params["handle"] as? String ?? "unknown"
          throw IMCoreBridgeError.chatNotFound(handle)
        } else if error.contains("Message not found") {
          let guid = params["guid"] as? String ?? "unknown"
          throw IMCoreBridgeError.messageNotFound(guid)
        }

        throw IMCoreBridgeError.operationFailed(error)
      }
    } catch let error as MessagesLauncherError {
      throw IMCoreBridgeError.connectionFailed(error.description)
    }
  }

  /// Set typing indicator for a conversation
  public func setTyping(for handle: String, typing: Bool) async throws {
    let params =
      [
        "handle": handle,
        "typing": typing,
      ] as [String: Any]

    _ = try await sendCommand(action: "typing", params: params)
  }

  /// Mark all messages as read in a conversation
  public func markAsRead(handle: String) async throws {
    let params = ["handle": handle]
    _ = try await sendCommand(action: "read", params: params)
  }

  /// Send a tapback reaction to a message
  public func sendTapback(
    to handle: String,
    messageGUID: String,
    type: TapbackType
  ) async throws {
    let params =
      [
        "handle": handle,
        "guid": messageGUID,
        "type": type.rawValue,
      ] as [String: Any]

    _ = try await sendCommand(action: "react", params: params)
  }

  /// List all available chats (for debugging)
  public func listChats() async throws -> [[String: Any]] {
    let response = try await sendCommand(action: "list_chats", params: [:])
    return response["chats"] as? [[String: Any]] ?? []
  }

  /// Check the availability and status of the IMCore bridge
  public func checkAvailability() -> (available: Bool, message: String) {
    // Check if dylib exists
    let possiblePaths = [
      ".build/release/imsg-plus-helper.dylib",
      ".build/debug/imsg-plus-helper.dylib",
      "/usr/local/lib/imsg-plus-helper.dylib",
    ]

    var dylibPath: String?
    for path in possiblePaths {
      if FileManager.default.fileExists(atPath: path) {
        dylibPath = path
        break
      }
    }

    guard dylibPath != nil else {
      return (
        false,
        """
        imsg-plus-helper.dylib not found. To build:
        1. make build-dylib
        2. Restart imsg

        Note: Advanced features require:
        - SIP disabled (for DYLD injection)
        - Full Disk Access granted to Terminal
        """
      )
    }

    // Check if already connected
    if launcher.isInjectedAndReady() {
      return (true, "Connected to Messages.app. IMCore features available.")
    }

    // Try to get status
    do {
      try launcher.ensureRunning()
      return (true, "Messages.app launched with injection. IMCore features available.")
    } catch let error as MessagesLauncherError {
      return (false, error.description)
    } catch {
      return (false, "Failed to connect to Messages.app: \(error.localizedDescription)")
    }
  }

  /// Get detailed status from the injected helper
  public func getStatus() async throws -> [String: Any] {
    return try await sendCommand(action: "status", params: [:])
  }

  /// Create a new chat with the given addresses
  public func createChat(
    addresses: [String],
    name: String? = nil,
    message: String? = nil,
    service: String = "imessage"
  ) async throws -> [String: Any] {
    var params: [String: Any] = [
      "addresses": addresses,
      "service": service,
    ]
    if let name, !name.isEmpty {
      params["name"] = name
    }
    if let message, !message.isEmpty {
      params["text"] = message
    }
    return try await sendCommand(action: "create_chat", params: params)
  }

  /// Rename an existing chat
  public func renameChat(handle: String, name: String) async throws {
    let params: [String: Any] = [
      "handle": handle,
      "name": name,
    ]
    _ = try await sendCommand(action: "rename_chat", params: params)
  }

  /// Remove participants from a group chat
  public func removeParticipant(
    handle: String, addresses: [String]
  ) async throws {
    let params: [String: Any] = [
      "handle": handle,
      "addresses": addresses,
    ]
    _ = try await sendCommand(action: "remove_participant", params: params)
  }

  /// Send a rich text message (with attributed text)
  public func sendRichMessage(handle: String, attributedText: Data) async throws {
    let params: [String: Any] = [
      "handle": handle,
      "attributed_text": attributedText.base64EncodedString(),
    ]
    _ = try await sendCommand(action: "send_message", params: params)
  }
}
