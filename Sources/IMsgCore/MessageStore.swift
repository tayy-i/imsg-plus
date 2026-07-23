import CryptoKit
import Foundation
import SQLite

public final class MessageStore: @unchecked Sendable {
  public static let appleEpochOffset: TimeInterval = 978_307_200

  public static var defaultPath: String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return NSString(string: home).appendingPathComponent("Library/Messages/chat.db")
  }

  public let path: String

  private let connection: Connection
  private let queue: DispatchQueue
  private let queueKey = DispatchSpecificKey<Void>()
  let hasAttributedBody: Bool
  let hasReactionColumns: Bool
  let hasDestinationCallerID: Bool
  let hasAudioMessageColumn: Bool
  let hasAttachmentUserInfo: Bool
  let hasThreadOriginator: Bool
  let hasDateEdited: Bool
  let hasAccountGUID: Bool

  public init(path: String = MessageStore.defaultPath) throws {
    let normalized = NSString(string: path).expandingTildeInPath
    self.path = normalized
    self.queue = DispatchQueue(label: "imsg.db", qos: .userInitiated)
    self.queue.setSpecific(key: queueKey, value: ())
    do {
      let uri = URL(fileURLWithPath: normalized).absoluteString
      let location = Connection.Location.uri(uri, parameters: [.mode(.readOnly)])
      self.connection = try Connection(location, readonly: true)
      self.connection.busyTimeout = 5
      self.hasAttributedBody = MessageStore.detectAttributedBody(connection: self.connection)
      self.hasReactionColumns = MessageStore.detectReactionColumns(connection: self.connection)
      self.hasDestinationCallerID = MessageStore.detectDestinationCallerID(
        connection: self.connection
      )
      self.hasAudioMessageColumn = MessageStore.detectAudioMessageColumn(
        connection: self.connection
      )
      self.hasAttachmentUserInfo = MessageStore.detectAttachmentUserInfo(
        connection: self.connection
      )
      self.hasThreadOriginator = MessageStore.detectThreadOriginatorColumn(
        connection: self.connection
      )
      self.hasDateEdited = MessageStore.detectDateEditedColumn(
        connection: self.connection
      )
      self.hasAccountGUID = MessageStore.detectMessageAccountGUID(
        connection: self.connection
      )
    } catch {
      throw MessageStore.enhance(error: error, path: normalized)
    }
  }

  init(
    connection: Connection,
    path: String,
    hasAttributedBody: Bool? = nil,
    hasReactionColumns: Bool? = nil,
    hasDestinationCallerID: Bool? = nil,
    hasAudioMessageColumn: Bool? = nil,
    hasAttachmentUserInfo: Bool? = nil,
    hasThreadOriginator: Bool? = nil,
    hasDateEdited: Bool? = nil,
    hasAccountGUID: Bool? = nil
  ) throws {
    self.path = path
    self.queue = DispatchQueue(label: "imsg.db.test", qos: .userInitiated)
    self.queue.setSpecific(key: queueKey, value: ())
    self.connection = connection
    self.connection.busyTimeout = 5
    if let hasAttributedBody {
      self.hasAttributedBody = hasAttributedBody
    } else {
      self.hasAttributedBody = MessageStore.detectAttributedBody(connection: connection)
    }
    if let hasReactionColumns {
      self.hasReactionColumns = hasReactionColumns
    } else {
      self.hasReactionColumns = MessageStore.detectReactionColumns(connection: connection)
    }
    if let hasDestinationCallerID {
      self.hasDestinationCallerID = hasDestinationCallerID
    } else {
      self.hasDestinationCallerID = MessageStore.detectDestinationCallerID(connection: connection)
    }
    if let hasAudioMessageColumn {
      self.hasAudioMessageColumn = hasAudioMessageColumn
    } else {
      self.hasAudioMessageColumn = MessageStore.detectAudioMessageColumn(connection: connection)
    }
    if let hasAttachmentUserInfo {
      self.hasAttachmentUserInfo = hasAttachmentUserInfo
    } else {
      self.hasAttachmentUserInfo = MessageStore.detectAttachmentUserInfo(connection: connection)
    }
    if let hasThreadOriginator {
      self.hasThreadOriginator = hasThreadOriginator
    } else {
      self.hasThreadOriginator = MessageStore.detectThreadOriginatorColumn(connection: connection)
    }
    if let hasDateEdited {
      self.hasDateEdited = hasDateEdited
    } else {
      self.hasDateEdited = MessageStore.detectDateEditedColumn(connection: connection)
    }
    if let hasAccountGUID {
      self.hasAccountGUID = hasAccountGUID
    } else {
      self.hasAccountGUID = MessageStore.detectMessageAccountGUID(connection: connection)
    }
  }

  public func listChats(limit: Int) throws -> [Chat] {
    let sql = """
      SELECT c.ROWID, IFNULL(c.display_name, c.chat_identifier) AS name, c.chat_identifier, c.service_name,
             MAX(m.date) AS last_date
      FROM chat c
      JOIN chat_message_join cmj ON c.ROWID = cmj.chat_id
      JOIN message m ON m.ROWID = cmj.message_id
      GROUP BY c.ROWID
      ORDER BY last_date DESC
      LIMIT ?
      """
    return try withConnection { db in
      var chats: [Chat] = []
      for row in try db.prepare(sql, limit) {
        let id = int64Value(row[0]) ?? 0
        let name = stringValue(row[1])
        let identifier = stringValue(row[2])
        let service = stringValue(row[3])
        let lastDate = appleDate(from: int64Value(row[4]))
        chats.append(
          Chat(
            id: id, identifier: identifier, name: name, service: service, lastMessageAt: lastDate))
      }
      return chats
    }
  }

  public func chatInfo(chatID: Int64) throws -> ChatInfo? {
    let sql = """
      SELECT c.ROWID, IFNULL(c.chat_identifier, '') AS identifier, IFNULL(c.guid, '') AS guid,
             IFNULL(c.display_name, c.chat_identifier) AS name, IFNULL(c.service_name, '') AS service
      FROM chat c
      WHERE c.ROWID = ?
      LIMIT 1
      """
    return try withConnection { db in
      for row in try db.prepare(sql, chatID) {
        let id = int64Value(row[0]) ?? 0
        let identifier = stringValue(row[1])
        let guid = stringValue(row[2])
        let name = stringValue(row[3])
        let service = stringValue(row[4])
        return ChatInfo(
          id: id,
          identifier: identifier,
          guid: guid,
          name: name,
          service: service
        )
      }
      return nil
    }
  }

  public func chatInfo(identifierOrGUID value: String) throws -> ChatInfo? {
    let sql = """
      SELECT c.ROWID, IFNULL(c.chat_identifier, '') AS identifier, IFNULL(c.guid, '') AS guid,
             IFNULL(c.display_name, c.chat_identifier) AS name, IFNULL(c.service_name, '') AS service
      FROM chat c
      WHERE c.chat_identifier = ? OR c.guid = ?
      ORDER BY CASE WHEN c.chat_identifier = ? THEN 0 ELSE 1 END, c.ROWID ASC
      LIMIT 1
      """
    return try withConnection { db in
      for row in try db.prepare(sql, value, value, value) {
        return ChatInfo(
          id: int64Value(row[0]) ?? 0,
          identifier: stringValue(row[1]),
          guid: stringValue(row[2]),
          name: stringValue(row[3]),
          service: stringValue(row[4])
        )
      }
      return nil
    }
  }

  public func participants(chatID: Int64) throws -> [String] {
    let sql = """
      SELECT h.id
      FROM chat_handle_join chj
      JOIN handle h ON h.ROWID = chj.handle_id
      WHERE chj.chat_id = ?
      ORDER BY h.id ASC
      """
    return try withConnection { db in
      var results: [String] = []
      var seen = Set<String>()
      for row in try db.prepare(sql, chatID) {
        let handle = stringValue(row[0])
        if handle.isEmpty { continue }
        if seen.insert(handle).inserted {
          results.append(handle)
        }
      }
      return results
    }
  }

  func withConnection<T>(_ block: (Connection) throws -> T) throws -> T {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return try block(connection)
    }
    return try queue.sync {
      try block(connection)
    }
  }
}

extension MessageStore {
  func attachmentRevisionEvidence(for messageID: Int64) throws -> String {
    let attachments = try attachments(for: messageID)
    let fields = attachments.map { attachment -> String in
      let availableBytes: Int64
      if attachment.missing {
        availableBytes = -1
      } else if
        let attributes = try? FileManager.default.attributesOfItem(
          atPath: attachment.originalPath
        ),
        let size = attributes[.size] as? NSNumber
      {
        availableBytes = size.int64Value
      } else {
        availableBytes = -1
      }
      return [
        String(attachment.rowID),
        attachment.filename,
        attachment.transferName,
        attachment.uti,
        attachment.mimeType,
        String(attachment.totalBytes),
        attachment.isSticker ? "1" : "0",
        attachment.originalPath,
        attachment.missing ? "1" : "0",
        String(availableBytes),
      ].joined(separator: "\u{1E}")
    }
    return fields.sorted().joined(separator: "\u{1D}")
  }

  public func attachments(for messageID: Int64) throws -> [AttachmentMeta] {
    let sql = """
      SELECT a.ROWID, a.filename, a.transfer_name, a.uti, a.mime_type, a.total_bytes, a.is_sticker
      FROM message_attachment_join maj
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id = ?
      """
    return try withConnection { db in
      var metas: [AttachmentMeta] = []
      for row in try db.prepare(sql, messageID) {
        let rowID = int64Value(row[0]) ?? 0
        let filename = stringValue(row[1])
        let transferName = stringValue(row[2])
        let uti = stringValue(row[3])
        let mimeType = stringValue(row[4])
        let totalBytes = int64Value(row[5]) ?? 0
        let isSticker = boolValue(row[6])
        let resolved = AttachmentResolver.resolve(filename)
        metas.append(
          AttachmentMeta(
            rowID: rowID,
            filename: filename,
            transferName: transferName,
            uti: uti,
            mimeType: mimeType,
            totalBytes: totalBytes,
            isSticker: isSticker,
            originalPath: resolved.resolved,
            missing: resolved.missing
          ))
      }
      return metas
    }
  }

  func audioTranscription(for messageID: Int64) throws -> String? {
    guard hasAttachmentUserInfo else { return nil }
    let sql = """
      SELECT a.user_info
      FROM message_attachment_join maj
      JOIN attachment a ON a.ROWID = maj.attachment_id
      WHERE maj.message_id = ?
      LIMIT 1
      """
    return try withConnection { db in
      for row in try db.prepare(sql, messageID) {
        let info = dataValue(row[0])
        guard !info.isEmpty else { continue }
        if let transcription = parseAudioTranscription(from: info) {
          return transcription
        }
      }
      return nil
    }
  }

  private func parseAudioTranscription(from data: Data) -> String? {
    do {
      let plist = try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      )
      guard
        let dict = plist as? [String: Any],
        let transcription = dict["audio-transcription"] as? String,
        !transcription.isEmpty
      else {
        return nil
      }
      return transcription
    } catch {
      return nil
    }
  }

  public func maxRowID() throws -> Int64 {
    return try withConnection { db in
      let value = try db.scalar("SELECT MAX(ROWID) FROM message")
      return int64Value(value) ?? 0
    }
  }

  /// Stable identity for the current Messages database file and subscribed
  /// chat/account scope. A database replacement, chat change, or account
  /// reassociation gets a different identity even when ROWIDs overlap.
  public func providerEpoch(chatID: Int64? = nil) throws -> String {
    let databaseEpoch: String
    if path == ":memory:" {
      databaseEpoch = "messages-db-v2:memory"
    } else {
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      guard
        let systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
        let creationDate = attributes[.creationDate] as? Date
      else {
        throw NSError(
          domain: "IMsgCore.MessageStore",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Messages database identity is unavailable"]
        )
      }
      let createdMilliseconds = Int64(creationDate.timeIntervalSince1970 * 1_000)
      databaseEpoch = "messages-db-v2:\(systemNumber):\(fileNumber):\(createdMilliseconds)"
    }

    guard let chatID else { return databaseEpoch }
    guard let chat = try chatInfo(chatID: chatID) else {
      throw NSError(
        domain: "IMsgCore.MessageStore",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Messages chat scope is unavailable"]
      )
    }
    let accountGUIDs: [String]
    if hasAccountGUID {
      accountGUIDs = try withConnection { db in
        var values = Set<String>()
        for row in try db.prepare(
          """
          SELECT DISTINCT IFNULL(m.account_guid, '')
          FROM message m
          JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
          WHERE cmj.chat_id = ? AND IFNULL(m.account_guid, '') != ''
          ORDER BY IFNULL(m.account_guid, '') ASC
          """,
          chatID
        ) {
          let value = stringValue(row[0])
          if !value.isEmpty { values.insert(value) }
        }
        return values.sorted()
      }
    } else {
      accountGUIDs = []
    }
    let scope = ([
      String(chat.id),
      chat.identifier,
      chat.guid,
      chat.service,
    ] + accountGUIDs).joined(separator: "\0")
    let digest = SHA256.hash(data: Data(scope.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    return "\(databaseEpoch):scope:\(digest)"
  }

  /// Detects an appended backlog whose provider timestamps precede the row at
  /// the durable cursor. This is quarantined as imported/restored history rather
  /// than silently treating it as new host-time input.
  public func pendingHistoryRegresses(afterRowID rowID: Int64, chatID: Int64? = nil) throws -> Bool {
    guard rowID >= 0 else { return false }
    return try withConnection { db in
      let join = chatID == nil ? "" : " JOIN chat_message_join cmj ON cmj.message_id = m.ROWID"
      let scope = chatID == nil ? "" : " AND cmj.chat_id = ?"
      let cursorBindings: [Binding?] = chatID.map { [rowID, $0] } ?? [rowID]
      let pendingBindings: [Binding?] = chatID.map { [rowID, $0] } ?? [rowID]
      let cursorDate = try db.prepare(
        "SELECT MAX(m.date) FROM message m\(join) WHERE m.ROWID <= ?\(scope)",
        cursorBindings
      ).compactMap { int64Value($0[0]) }.first
      let oldestPendingDate = try db.prepare(
        "SELECT MIN(m.date) FROM message m\(join) WHERE m.ROWID > ?\(scope)",
        pendingBindings
      ).compactMap { int64Value($0[0]) }.first
      guard let oldestPendingDate else { return false }
      guard let cursorDate else { return true }
      return oldestPendingDate < cursorDate
    }
  }

  public func latestProviderDate(atOrBeforeRowID rowID: Int64, chatID: Int64? = nil) throws
    -> Date?
  {
    guard rowID >= 0 else { return nil }
    return try withConnection { db in
      let join = chatID == nil ? "" : " JOIN chat_message_join cmj ON cmj.message_id = m.ROWID"
      let scope = chatID == nil ? "" : " AND cmj.chat_id = ?"
      let bindings: [Binding?] = chatID.map { [rowID, $0] } ?? [rowID]
      let raw = try db.prepare(
        "SELECT MAX(m.date) FROM message m\(join) WHERE m.ROWID <= ?\(scope)",
        bindings
      ).compactMap { int64Value($0[0]) }.first
      return raw.map { appleDate(from: $0) }
    }
  }

  public func reactions(for messageID: Int64) throws -> [Reaction] {
    guard hasReactionColumns else { return [] }
    // Reactions are stored as messages with associated_message_type in range 2000-2006
    // 2000-2005 are standard tapbacks, 2006 is custom emoji reactions
    // They reference the original message via associated_message_guid which has format "p:X/GUID"
    // where X is the part index (0 for single-part messages) and GUID matches the original message's guid
    let bodyColumn = hasAttributedBody ? "r.attributedBody" : "NULL"
    let sql = """
      SELECT r.ROWID, r.associated_message_type, h.id, r.is_from_me, r.date, IFNULL(r.text, '') as text,
             \(bodyColumn) AS body
      FROM message m
      JOIN message r ON r.associated_message_guid = m.guid
        OR r.associated_message_guid LIKE '%/' || m.guid
      LEFT JOIN handle h ON r.handle_id = h.ROWID
      WHERE m.ROWID = ?
        AND m.guid IS NOT NULL
        AND m.guid != ''
        AND r.associated_message_type >= 2000
        AND r.associated_message_type <= 3006
      ORDER BY r.date ASC
      """
    return try withConnection { db in
      var reactions: [Reaction] = []
      var reactionIndex: [ReactionKey: Int] = [:]
      for row in try db.prepare(sql, messageID) {
        let rowID = int64Value(row[0]) ?? 0
        let typeValue = intValue(row[1]) ?? 0
        let sender = stringValue(row[2])
        let isFromMe = boolValue(row[3])
        let date = appleDate(from: int64Value(row[4]))
        let text = stringValue(row[5])
        let body = dataValue(row[6])
        let resolvedText = text.isEmpty ? TypedStreamParser.parseAttributedBody(body) : text

        if ReactionType.isReactionRemove(typeValue) {
          let customEmoji = typeValue == 3006 ? extractCustomEmoji(from: resolvedText) : nil
          let reactionType = ReactionType.fromRemoval(typeValue, customEmoji: customEmoji)
          if let reactionType {
            let key = ReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
            if let index = reactionIndex.removeValue(forKey: key) {
              reactions.remove(at: index)
              reactionIndex = ReactionKey.reindex(reactions: reactions)
            }
            continue
          }
          if typeValue == 3006 {
            if let index = reactions.firstIndex(where: {
              $0.sender == sender && $0.isFromMe == isFromMe && $0.reactionType.isCustom
            }) {
              reactions.remove(at: index)
              reactionIndex = ReactionKey.reindex(reactions: reactions)
            }
          }
          continue
        }

        let customEmoji: String? = typeValue == 2006 ? extractCustomEmoji(from: resolvedText) : nil
        guard let reactionType = ReactionType(rawValue: typeValue, customEmoji: customEmoji) else {
          continue
        }

        let key = ReactionKey(sender: sender, isFromMe: isFromMe, reactionType: reactionType)
        if let index = reactionIndex[key] {
          reactions[index] = Reaction(
            rowID: rowID,
            reactionType: reactionType,
            sender: sender,
            isFromMe: isFromMe,
            date: date,
            associatedMessageID: messageID
          )
        } else {
          reactionIndex[key] = reactions.count
          reactions.append(
            Reaction(
              rowID: rowID,
              reactionType: reactionType,
              sender: sender,
              isFromMe: isFromMe,
              date: date,
              associatedMessageID: messageID
            ))
        }
      }
      return reactions
    }
  }

  /// Extract custom emoji from reaction message text like "Reacted 🎉 to "original message""
  private func extractCustomEmoji(from text: String) -> String? {
    // Format: "Reacted X to "..." where X is the emoji. Fallback to first emoji in text.
    guard
      let reactedRange = text.range(of: "Reacted "),
      let toRange = text.range(of: " to ", range: reactedRange.upperBound..<text.endIndex)
    else {
      return extractFirstEmoji(from: text)
    }
    let emoji = String(text[reactedRange.upperBound..<toRange.lowerBound])
    return emoji.isEmpty ? extractFirstEmoji(from: text) : emoji
  }

  private func extractFirstEmoji(from text: String) -> String? {
    for character in text {
      if character.unicodeScalars.contains(where: {
        $0.properties.isEmojiPresentation || $0.properties.isEmoji
      }) {
        return String(character)
      }
    }
    return nil
  }

  private static func detectReactionColumns(connection: Connection) -> Bool {
    do {
      let rows = try connection.prepare("PRAGMA table_info(message)")
      var columns = Set<String>()
      for row in rows {
        if let name = row[1] as? String {
          columns.insert(name.lowercased())
        }
      }
      return columns.contains("guid")
        && columns.contains("associated_message_guid")
        && columns.contains("associated_message_type")
    } catch {
      return false
    }
  }

  private struct ReactionKey: Hashable {
    let sender: String
    let isFromMe: Bool
    let reactionType: ReactionType

    static func reindex(reactions: [Reaction]) -> [ReactionKey: Int] {
      var index: [ReactionKey: Int] = [:]
      for (offset, reaction) in reactions.enumerated() {
        let key = ReactionKey(
          sender: reaction.sender,
          isFromMe: reaction.isFromMe,
          reactionType: reaction.reactionType
        )
        index[key] = offset
      }
      return index
    }
  }
}
