import Foundation
import SQLite

extension MessageStore {
  public func recentOutgoingExtensionMessageGUID(
    chatID: Int64?,
    balloonBundleID: String,
    payloadData: Data,
    since: Date
  ) throws -> String? {
    guard !balloonBundleID.isEmpty, !payloadData.isEmpty else {
      return nil
    }

    var sql = """
      SELECT m.guid
      FROM message m
      JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      WHERE m.is_from_me = 1
        AND m.balloon_bundle_id = ?
        AND m.payload_data = ?
        AND m.date >= ?
      """
    var bindings: [Binding?] = [
      balloonBundleID,
      Blob(bytes: [UInt8](payloadData)),
      MessageStore.appleEpoch(since),
    ]
    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID)
    }
    sql += " ORDER BY m.ROWID DESC LIMIT 1"

    return try withConnection { db in
      do {
        for row in try db.prepare(sql, bindings) {
          let guid = stringValue(row[0])
          return guid.isEmpty ? nil : guid
        }
      } catch {
        return nil
      }
      return nil
    }
  }

  public func messages(chatID: Int64, limit: Int) throws -> [Message] {
    return try messages(chatID: chatID, limit: limit, filter: nil)
  }

  public func messages(chatID: Int64, limit: Int, filter: MessageFilter?) throws -> [Message] {
    let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
    let guidColumn = hasReactionColumns ? "m.guid" : "NULL"
    let associatedGuidColumn = hasReactionColumns ? "m.associated_message_guid" : "NULL"
    let associatedTypeColumn = hasReactionColumns ? "m.associated_message_type" : "NULL"
    let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let audioMessageColumn = hasAudioMessageColumn ? "m.is_audio_message" : "0"
    let threadOriginatorColumn = hasThreadOriginator ? "m.thread_originator_guid" : "NULL"
    let threadOriginatorPartColumn = hasThreadOriginator ? "m.thread_originator_part" : "NULL"
    let dateEditedColumn = hasDateEdited ? "m.date_edited" : "NULL"
    let accountGUIDColumn = hasAccountGUID ? "m.account_guid" : "NULL"
    let reactionRevisionColumn =
      hasReactionColumns
      ? """
        CASE WHEN m.is_from_me = 1 THEN (
          SELECT IFNULL(MAX(r.ROWID), 0)
          FROM message r
          WHERE \(Self.reactionAssociationPredicate)
            AND r.associated_message_type >= 2000
            AND r.associated_message_type <= 3006
        ) ELSE 0 END
        """
      : "0"
    let reactionFilter =
      hasReactionColumns
      ? " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      : ""
    var sql = """
      SELECT m.ROWID, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
             \(audioMessageColumn) AS is_audio_message, \(destinationCallerColumn) AS destination_caller_id,
             \(guidColumn) AS guid, \(associatedGuidColumn) AS associated_guid, \(associatedTypeColumn) AS associated_type,
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
             \(bodyColumn) AS body,
             \(threadOriginatorColumn) AS thread_originator_guid,
             \(threadOriginatorPartColumn) AS thread_originator_part,
             \(dateEditedColumn) AS date_edited,
             \(accountGUIDColumn) AS account_guid,
             \(reactionRevisionColumn) AS reaction_revision
      FROM message m
      JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE cmj.chat_id = ?\(reactionFilter)
      """
    var bindings: [Binding?] = [chatID]

    if let filter {
      if let startDate = filter.startDate {
        sql += " AND m.date >= ?"
        bindings.append(MessageStore.appleEpoch(startDate))
      }
      if let endDate = filter.endDate {
        sql += " AND m.date < ?"
        bindings.append(MessageStore.appleEpoch(endDate))
      }
      if !filter.participants.isEmpty {
        let placeholders = Array(repeating: "?", count: filter.participants.count).joined(
          separator: ",")
        // Match current in-memory behavior: Message.sender is either handle.id or destination_caller_id.
        sql +=
          " AND COALESCE(NULLIF(h.id,''), \(destinationCallerColumn)) COLLATE NOCASE IN (\(placeholders))"
        for participant in filter.participants {
          bindings.append(participant)
        }
      }
    }

    sql += " ORDER BY m.date DESC LIMIT ?"
    bindings.append(limit)

    return try withConnection { db in
      var messages: [Message] = []
      for row in try db.prepare(sql, bindings) {
        let rowID = int64Value(row[0]) ?? 0
        let handleID = int64Value(row[1])
        var sender = stringValue(row[2])
        let text = stringValue(row[3])
        let date = appleDate(from: int64Value(row[4]))
        let isFromMe = boolValue(row[5])
        let service = stringValue(row[6])
        let isAudioMessage = boolValue(row[7])
        let destinationCallerID = stringValue(row[8])
        if sender.isEmpty && !destinationCallerID.isEmpty {
          sender = destinationCallerID
        }
        let guid = stringValue(row[9])
        let associatedGuid = stringValue(row[10])
        let associatedType = intValue(row[11])
        let attachments = intValue(row[12]) ?? 0
        let attachmentRevisionEvidence = attachments > 0
          ? try self.attachmentRevisionEvidence(for: rowID)
          : ""
        let body = dataValue(row[13])
        let threadOriginatorGUID = stringValue(row[14])
        let threadOriginatorPart = stringValue(row[15])
        let dateEditedRaw = int64Value(row[16])
        let accountGUID = stringValue(row[17])
        let reactionRevisionEvidence = String(int64Value(row[18]) ?? 0)
        var resolvedText = text
        var markdownText: String?
        if text.isEmpty {
          let parsed = AttributedBodyParser.parse(body)
          resolvedText = parsed.plainText
          markdownText = parsed.markdown != parsed.plainText ? parsed.markdown : nil
        }
        if isAudioMessage, let transcription = try audioTranscription(for: rowID) {
          resolvedText = transcription
          markdownText = nil
        }
        let resolvedReplyToGUID: String? =
          !threadOriginatorGUID.isEmpty
          ? threadOriginatorGUID
          : replyToGUID(associatedGuid: associatedGuid, associatedType: associatedType)
        let isEdited = (dateEditedRaw ?? 0) > 0
        let dateEdited: Date? = isEdited ? appleDate(from: dateEditedRaw) : nil
        messages.append(
          Message(
            rowID: rowID,
            chatID: chatID,
            sender: sender,
            text: resolvedText,
            date: date,
            isFromMe: isFromMe,
            service: service,
            handleID: handleID,
            attachmentsCount: attachments,
            guid: guid,
            replyToGUID: resolvedReplyToGUID,
            markdownText: markdownText,
            isEdited: isEdited,
            dateEdited: dateEdited,
            threadOriginatorGUID: threadOriginatorGUID.isEmpty ? nil : threadOriginatorGUID,
            threadOriginatorPart: threadOriginatorPart.isEmpty ? nil : threadOriginatorPart,
            accountGUID: accountGUID,
            attachmentRevisionEvidence: attachmentRevisionEvidence,
            reactionRevisionEvidence: reactionRevisionEvidence
          ))
      }
      return messages
    }
  }

  public func messagesAfter(afterRowID: Int64, chatID: Int64?, limit: Int) throws -> [Message] {
    let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
    let guidColumn = hasReactionColumns ? "m.guid" : "NULL"
    let associatedGuidColumn = hasReactionColumns ? "m.associated_message_guid" : "NULL"
    let associatedTypeColumn = hasReactionColumns ? "m.associated_message_type" : "NULL"
    let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let audioMessageColumn = hasAudioMessageColumn ? "m.is_audio_message" : "0"
    let threadOriginatorColumn = hasThreadOriginator ? "m.thread_originator_guid" : "NULL"
    let threadOriginatorPartColumn = hasThreadOriginator ? "m.thread_originator_part" : "NULL"
    let dateEditedColumn = hasDateEdited ? "m.date_edited" : "NULL"
    let accountGUIDColumn = hasAccountGUID ? "m.account_guid" : "NULL"
    let reactionRevisionColumn =
      hasReactionColumns
      ? """
        CASE WHEN m.is_from_me = 1 THEN (
          SELECT IFNULL(MAX(r.ROWID), 0)
          FROM message r
          WHERE \(Self.reactionAssociationPredicate)
            AND r.associated_message_type >= 2000
            AND r.associated_message_type <= 3006
        ) ELSE 0 END
        """
      : "0"
    let reactionFilter =
      hasReactionColumns
      ? " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      : ""
    var sql = """
      SELECT m.ROWID, cmj.chat_id, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
             \(audioMessageColumn) AS is_audio_message, \(destinationCallerColumn) AS destination_caller_id,
             \(guidColumn) AS guid, \(associatedGuidColumn) AS associated_guid, \(associatedTypeColumn) AS associated_type,
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
             \(bodyColumn) AS body,
             \(threadOriginatorColumn) AS thread_originator_guid,
             \(threadOriginatorPartColumn) AS thread_originator_part,
             \(dateEditedColumn) AS date_edited,
             \(accountGUIDColumn) AS account_guid,
             \(reactionRevisionColumn) AS reaction_revision
      FROM message m
      LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE m.ROWID > ?\(reactionFilter)
      """
    var bindings: [Binding?] = [afterRowID]
    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID)
    }
    sql += " ORDER BY m.ROWID ASC LIMIT ?"
    bindings.append(limit)

    return try withConnection { db in
      var messages: [Message] = []
      for row in try db.prepare(sql, bindings) {
        let rowID = int64Value(row[0]) ?? 0
        let resolvedChatID = int64Value(row[1]) ?? chatID ?? 0
        let handleID = int64Value(row[2])
        var sender = stringValue(row[3])
        let text = stringValue(row[4])
        let date = appleDate(from: int64Value(row[5]))
        let isFromMe = boolValue(row[6])
        let service = stringValue(row[7])
        let isAudioMessage = boolValue(row[8])
        let destinationCallerID = stringValue(row[9])
        if sender.isEmpty && !destinationCallerID.isEmpty {
          sender = destinationCallerID
        }
        let guid = stringValue(row[10])
        let associatedGuid = stringValue(row[11])
        let associatedType = intValue(row[12])
        let attachments = intValue(row[13]) ?? 0
        let attachmentRevisionEvidence = attachments > 0
          ? try self.attachmentRevisionEvidence(for: rowID)
          : ""
        let body = dataValue(row[14])
        let threadOriginatorGUID = stringValue(row[15])
        let threadOriginatorPart = stringValue(row[16])
        let dateEditedRaw = int64Value(row[17])
        let accountGUID = stringValue(row[18])
        let reactionRevisionEvidence = String(int64Value(row[19]) ?? 0)
        var resolvedText = text
        var markdownText: String?
        if text.isEmpty {
          let parsed = AttributedBodyParser.parse(body)
          resolvedText = parsed.plainText
          markdownText = parsed.markdown != parsed.plainText ? parsed.markdown : nil
        }
        if isAudioMessage, let transcription = try audioTranscription(for: rowID) {
          resolvedText = transcription
          markdownText = nil
        }
        let resolvedReplyToGUID: String? =
          !threadOriginatorGUID.isEmpty
          ? threadOriginatorGUID
          : replyToGUID(associatedGuid: associatedGuid, associatedType: associatedType)
        let isEdited = (dateEditedRaw ?? 0) > 0
        let dateEdited: Date? = isEdited ? appleDate(from: dateEditedRaw) : nil
        messages.append(
          Message(
            rowID: rowID,
            chatID: resolvedChatID,
            sender: sender,
            text: resolvedText,
            date: date,
            isFromMe: isFromMe,
            service: service,
            handleID: handleID,
            attachmentsCount: attachments,
            guid: guid,
            replyToGUID: resolvedReplyToGUID,
            markdownText: markdownText,
            isEdited: isEdited,
            dateEdited: dateEdited,
            threadOriginatorGUID: threadOriginatorGUID.isEmpty ? nil : threadOriginatorGUID,
            threadOriginatorPart: threadOriginatorPart.isEmpty ? nil : threadOriginatorPart,
            accountGUID: accountGUID,
            attachmentRevisionEvidence: attachmentRevisionEvidence,
            reactionRevisionEvidence: reactionRevisionEvidence
          ))
      }
      return messages
    }
  }

  /// Reloads an exact bounded set of rows. The watcher uses this for a
  /// round-robin revision scan so an older observed message is not forgotten
  /// merely because newer rows arrived.
  public func messages(rowIDs: [Int64], chatID: Int64?) throws -> [Message] {
    let uniqueRowIDs = Array(Set(rowIDs.filter { $0 > 0 })).sorted()
    guard !uniqueRowIDs.isEmpty else { return [] }
    let bodyColumn = hasAttributedBody ? "m.attributedBody" : "NULL"
    let guidColumn = hasReactionColumns ? "m.guid" : "NULL"
    let associatedGuidColumn = hasReactionColumns ? "m.associated_message_guid" : "NULL"
    let associatedTypeColumn = hasReactionColumns ? "m.associated_message_type" : "NULL"
    let destinationCallerColumn = hasDestinationCallerID ? "m.destination_caller_id" : "NULL"
    let audioMessageColumn = hasAudioMessageColumn ? "m.is_audio_message" : "0"
    let threadOriginatorColumn = hasThreadOriginator ? "m.thread_originator_guid" : "NULL"
    let threadOriginatorPartColumn = hasThreadOriginator ? "m.thread_originator_part" : "NULL"
    let dateEditedColumn = hasDateEdited ? "m.date_edited" : "NULL"
    let accountGUIDColumn = hasAccountGUID ? "m.account_guid" : "NULL"
    let reactionRevisionColumn =
      hasReactionColumns
      ? """
        CASE WHEN m.is_from_me = 1 THEN (
          SELECT IFNULL(MAX(r.ROWID), 0)
          FROM message r
          WHERE \(Self.reactionAssociationPredicate)
            AND r.associated_message_type >= 2000
            AND r.associated_message_type <= 3006
        ) ELSE 0 END
        """
      : "0"
    let reactionFilter =
      hasReactionColumns
      ? " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      : ""
    let placeholders = Array(repeating: "?", count: uniqueRowIDs.count).joined(separator: ",")
    var sql = """
      SELECT m.ROWID, cmj.chat_id, m.handle_id, h.id, IFNULL(m.text, '') AS text, m.date, m.is_from_me, m.service,
             \(audioMessageColumn) AS is_audio_message, \(destinationCallerColumn) AS destination_caller_id,
             \(guidColumn) AS guid, \(associatedGuidColumn) AS associated_guid, \(associatedTypeColumn) AS associated_type,
             (SELECT COUNT(*) FROM message_attachment_join maj WHERE maj.message_id = m.ROWID) AS attachments,
             \(bodyColumn) AS body,
             \(threadOriginatorColumn) AS thread_originator_guid,
             \(threadOriginatorPartColumn) AS thread_originator_part,
             \(dateEditedColumn) AS date_edited,
             \(accountGUIDColumn) AS account_guid,
             \(reactionRevisionColumn) AS reaction_revision
      FROM message m
      LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      LEFT JOIN handle h ON m.handle_id = h.ROWID
      WHERE m.ROWID IN (\(placeholders))\(reactionFilter)
      """
    var bindings: [Binding?] = uniqueRowIDs.map { $0 }
    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID)
    }
    sql += " ORDER BY m.ROWID ASC"

    return try withConnection { db in
      var messages: [Message] = []
      for row in try db.prepare(sql, bindings) {
        let rowID = int64Value(row[0]) ?? 0
        let resolvedChatID = int64Value(row[1]) ?? chatID ?? 0
        let handleID = int64Value(row[2])
        var sender = stringValue(row[3])
        let text = stringValue(row[4])
        let date = appleDate(from: int64Value(row[5]))
        let isFromMe = boolValue(row[6])
        let service = stringValue(row[7])
        let isAudioMessage = boolValue(row[8])
        let destinationCallerID = stringValue(row[9])
        if sender.isEmpty && !destinationCallerID.isEmpty {
          sender = destinationCallerID
        }
        let guid = stringValue(row[10])
        let associatedGuid = stringValue(row[11])
        let associatedType = intValue(row[12])
        let attachments = intValue(row[13]) ?? 0
        let attachmentRevisionEvidence = attachments > 0
          ? try self.attachmentRevisionEvidence(for: rowID)
          : ""
        let body = dataValue(row[14])
        let threadOriginatorGUID = stringValue(row[15])
        let threadOriginatorPart = stringValue(row[16])
        let dateEditedRaw = int64Value(row[17])
        let accountGUID = stringValue(row[18])
        let reactionRevisionEvidence = String(int64Value(row[19]) ?? 0)
        var resolvedText = text
        var markdownText: String?
        if text.isEmpty {
          let parsed = AttributedBodyParser.parse(body)
          resolvedText = parsed.plainText
          markdownText = parsed.markdown != parsed.plainText ? parsed.markdown : nil
        }
        if isAudioMessage, let transcription = try audioTranscription(for: rowID) {
          resolvedText = transcription
          markdownText = nil
        }
        let resolvedReplyToGUID: String? =
          !threadOriginatorGUID.isEmpty
          ? threadOriginatorGUID
          : replyToGUID(associatedGuid: associatedGuid, associatedType: associatedType)
        let isEdited = (dateEditedRaw ?? 0) > 0
        let dateEdited: Date? = isEdited ? appleDate(from: dateEditedRaw) : nil
        messages.append(
          Message(
            rowID: rowID,
            chatID: resolvedChatID,
            sender: sender,
            text: resolvedText,
            date: date,
            isFromMe: isFromMe,
            service: service,
            handleID: handleID,
            attachmentsCount: attachments,
            guid: guid,
            replyToGUID: resolvedReplyToGUID,
            markdownText: markdownText,
            isEdited: isEdited,
            dateEdited: dateEdited,
            threadOriginatorGUID: threadOriginatorGUID.isEmpty ? nil : threadOriginatorGUID,
            threadOriginatorPart: threadOriginatorPart.isEmpty ? nil : threadOriginatorPart,
            accountGUID: accountGUID,
            attachmentRevisionEvidence: attachmentRevisionEvidence,
            reactionRevisionEvidence: reactionRevisionEvidence
          ))
      }
      return messages
    }
  }

  /// Returns rows that can change in place in ascending order. Provider edits
  /// expose `date_edited`; attachment-bearing rows must also be revisited because
  /// Messages can add or replace an attachment association without changing it.
  /// Unlike a newest-N scan, this recovers offline changes to old rows.
  public func revisedMessages(
    afterRowID: Int64,
    atOrBeforeRowID rowID: Int64,
    chatID: Int64?,
    reactionReplayAfter: Date?,
    limit: Int
  ) throws -> [Message] {
    guard limit > 0, rowID >= 0 else { return [] }
    let editedPredicate = hasDateEdited ? "IFNULL(m.date_edited, 0) > 0" : "0"
    let reactedPredicate =
      hasReactionColumns && reactionReplayAfter != nil
      ? """
        (
          m.is_from_me = 1
          AND m.date >= ?
          AND EXISTS (
          SELECT 1
          FROM message r
          WHERE \(Self.reactionAssociationPredicate)
            AND r.associated_message_type >= 2000
            AND r.associated_message_type <= 3006
          )
        )
        """
      : "0"
    var sql = """
      SELECT m.ROWID
      FROM message m
      LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      WHERE m.ROWID > ? AND m.ROWID <= ?
        AND (
          \(editedPredicate)
          OR EXISTS (
            SELECT 1 FROM message_attachment_join maj WHERE maj.message_id = m.ROWID
          )
          OR \(reactedPredicate)
        )
      """
    var bindings: [Binding?] = [afterRowID, rowID]
    if hasReactionColumns, let reactionReplayAfter {
      bindings.append(MessageStore.appleEpoch(reactionReplayAfter))
    }
    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID)
    }
    sql += " ORDER BY m.ROWID ASC LIMIT ?"
    bindings.append(limit)
    let rowIDs = try withConnection { db in
      try db.prepare(sql, bindings).compactMap { int64Value($0[0]) }
    }
    return try messages(rowIDs: rowIDs, chatID: chatID)
  }

  /// Returns the newest bounded set at or below a durable row cursor. The
  /// watcher uses this to notice edits and retractions, which keep their
  /// original row ID in Messages.
  public func recentMessages(
    atOrBeforeRowID rowID: Int64,
    chatID: Int64?,
    limit: Int
  ) throws -> [Message] {
    guard limit > 0, rowID >= 0 else { return [] }
    let reactionFilter =
      hasReactionColumns
      ? " AND (m.associated_message_type IS NULL OR m.associated_message_type < 2000 OR m.associated_message_type > 3006)"
      : ""
    var sql = """
      SELECT m.ROWID
      FROM message m
      LEFT JOIN chat_message_join cmj ON m.ROWID = cmj.message_id
      WHERE m.ROWID <= ?\(reactionFilter)
      """
    var bindings: [Binding?] = [rowID]
    if let chatID {
      sql += " AND cmj.chat_id = ?"
      bindings.append(chatID)
    }
    sql += " ORDER BY m.ROWID DESC LIMIT ?"
    bindings.append(limit)

    let lowerBound = try withConnection { db -> Int64? in
      var oldest: Int64?
      for row in try db.prepare(sql, bindings) {
        oldest = int64Value(row[0])
      }
      return oldest
    }
    guard let lowerBound else { return [] }
    return try messagesAfter(
      afterRowID: lowerBound - 1,
      chatID: chatID,
      limit: limit
    ).filter { $0.rowID <= rowID }
  }
}
