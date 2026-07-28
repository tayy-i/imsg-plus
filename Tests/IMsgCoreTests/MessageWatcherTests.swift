import Foundation
import SQLite
import Testing

@testable import IMsgCore

private enum WatcherTestDatabase {
  static func appleEpoch(_ date: Date) -> Int64 {
    let seconds = date.timeIntervalSince1970 - MessageStore.appleEpochOffset
    return Int64(seconds * 1_000_000_000)
  }

  static func makeStore() throws -> MessageStore {
    try makeMutableStore().store
  }

  static func makeMutableStore() throws -> (store: MessageStore, db: Connection) {
    let db = try Connection(.inMemory)
    try db.execute(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY,
        handle_id INTEGER,
        text TEXT,
        guid TEXT,
        associated_message_guid TEXT,
        associated_message_type INTEGER,
        date INTEGER,
        is_from_me INTEGER,
        service TEXT,
        date_edited INTEGER
      );
      """
    )
    try db.execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);")
    try db.execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);")
    try db.execute(
      "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);")
    try db.execute(
      """
      CREATE TABLE attachment (
        ROWID INTEGER PRIMARY KEY,
        filename TEXT,
        transfer_name TEXT,
        uti TEXT,
        mime_type TEXT,
        total_bytes INTEGER,
        is_sticker INTEGER
      );
      """
    )

    let now = Date()
    try db.run("INSERT INTO handle(ROWID, id) VALUES (1, '+123')")
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, guid, date, is_from_me, service)
      VALUES (1, 1, 'hello', 'message-guid-1', ?, 0, 'iMessage')
      """,
      appleEpoch(now)
    )
    try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 1)")

    let store = try MessageStore(
      connection: db, path: ":memory:", hasAttributedBody: false, hasReactionColumns: true)
    return (store, db)
  }
}

@Test
func messageWatcherEmitsAnOutgoingMessageRevisionWhenATapbackChanges() async throws {
  let (store, db) = try WatcherTestDatabase.makeMutableStore()
  try db.run("UPDATE message SET is_from_me = 1 WHERE ROWID = 1")
  let stream = MessageWatcher(store: store).stream(
    chatID: 1,
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      batchLimit: 10,
      revisionScanLimit: 10,
      fallbackPollInterval: 0.01
    )
  )
  var iterator = stream.makeAsyncIterator()
  let original = try await iterator.next()
  #expect(original?.rowID == 1)
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid,
      associated_message_type, date, is_from_me, service
    ) VALUES (2, 1, 'Liked', 'reaction-guid-1', 'p:0/message-guid-1', 2001, ?, 0, 'iMessage')
    """,
    WatcherTestDatabase.appleEpoch(Date().addingTimeInterval(1))
  )

  let reacted = try await iterator.next()
  #expect(reacted?.rowID == 1)
  #expect(reacted?.guid == "message-guid-1")
  #expect(reacted?.isFromMe == true)
  #expect(reacted?.isNewProviderRow == false)
  #expect(reacted?.reactionRevisionEvidence == "2")
}

@Test
func offlineReactionReplayStaysWithinThePendingApprovalWindow() throws {
  let (store, db) = try WatcherTestDatabase.makeMutableStore()
  let now = Date()
  try db.run(
    "UPDATE message SET is_from_me = 1, date = ? WHERE ROWID = 1",
    WatcherTestDatabase.appleEpoch(now.addingTimeInterval(-3_600))
  )
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, guid, date, is_from_me, service)
    VALUES (2, 1, 'recent approval', 'message-guid-2', ?, 1, 'iMessage')
    """,
    WatcherTestDatabase.appleEpoch(now.addingTimeInterval(-60))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid,
      associated_message_type, date, is_from_me, service
    ) VALUES (3, 1, 'Liked', 'old-reaction', 'p:0/message-guid-1', 2001, ?, 1, 'iMessage')
    """,
    WatcherTestDatabase.appleEpoch(now.addingTimeInterval(-30))
  )
  try db.run(
    """
    INSERT INTO message(
      ROWID, handle_id, text, guid, associated_message_guid,
      associated_message_type, date, is_from_me, service
    ) VALUES (4, 1, 'Liked', 'recent-reaction', 'p:0/message-guid-2', 2001, ?, 1, 'iMessage')
    """,
    WatcherTestDatabase.appleEpoch(now.addingTimeInterval(-20))
  )

  let replayed = try store.revisedMessages(
    afterRowID: 0,
    atOrBeforeRowID: 4,
    chatID: 1,
    reactionReplayAfter: now.addingTimeInterval(-600),
    limit: 10
  )

  #expect(replayed.map(\.rowID) == [2])
}

@Test
func messageWatcherMarksFirstObservedEditedRowAsNew() async throws {
  let (store, db) = try WatcherTestDatabase.makeMutableStore()
  try db.run(
    "UPDATE message SET text = 'edited while offline', date_edited = ? WHERE ROWID = 1",
    WatcherTestDatabase.appleEpoch(Date().addingTimeInterval(1))
  )
  let stream = MessageWatcher(store: store).stream(
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      batchLimit: 10,
      revisionScanLimit: 10,
      fallbackPollInterval: 0.01
    )
  )
  var iterator = stream.makeAsyncIterator()
  let message = try await iterator.next()

  #expect(message?.text == "edited while offline")
  #expect(message?.isEdited == true)
  #expect(message?.isNewProviderRow == true)
}

@Test
func messageWatcherDrainsRapidArrivalsBeyondOneBatch() async throws {
  let (store, db) = try WatcherTestDatabase.makeMutableStore()
  let now = Date()
  for rowID in 2...7 {
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (?, 1, ?, ?, 0, 'iMessage')
      """,
      Int64(rowID), "message-\(rowID)", WatcherTestDatabase.appleEpoch(now)
    )
    try db.run(
      "INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)",
      Int64(rowID)
    )
  }
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      batchLimit: 2,
      fallbackPollInterval: 0.01
    )
  )

  var iterator = stream.makeAsyncIterator()
  var rowIDs: [Int64] = []
  for _ in 0..<7 {
    if let message = try await iterator.next() {
      rowIDs.append(message.rowID)
    }
  }
  #expect(rowIDs == [1, 2, 3, 4, 5, 6, 7])
}

@Test
func messageWatcherFailsClosedWhenOlderHistoryIsAppendedLive() async throws {
  let (store, db) = try WatcherTestDatabase.makeMutableStore()
  let stream = MessageWatcher(store: store).stream(
    chatID: 1,
    sinceRowID: 1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      batchLimit: 10,
      revisionScanLimit: 10,
      fallbackPollInterval: 0.01
    )
  )
  let oldDate = Date().addingTimeInterval(-86_400)
  try db.run(
    "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service) VALUES (2, 1, 'imported old request', ?, 0, 'iMessage')",
    WatcherTestDatabase.appleEpoch(oldDate)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")
  try db.run(
    "INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service) VALUES (3, 1, 'later request', ?, 0, 'iMessage')",
    WatcherTestDatabase.appleEpoch(Date().addingTimeInterval(1))
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 3)")

  var iterator = stream.makeAsyncIterator()
  do {
    _ = try await iterator.next()
    Issue.record("Expected imported live history to stop the stream")
  } catch {
    #expect(String(describing: error).contains("older than the durable cursor"))
  }
}

@Test
func messageWatcherEmitsOneChangedFingerprintForSameRowRevision() async throws {
  let (store, db) = try WatcherTestDatabase.makeMutableStore()
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      batchLimit: 10,
      revisionScanLimit: 10,
      fallbackPollInterval: 0.01
    )
  )
  var iterator = stream.makeAsyncIterator()
  let original = try await iterator.next()
  #expect(original?.text == "hello")

  let editedAt = WatcherTestDatabase.appleEpoch(Date().addingTimeInterval(1))
  try db.run(
    "UPDATE message SET text = 'corrected', date_edited = ? WHERE ROWID = 1",
    editedAt
  )
  let revised = try await iterator.next()
  #expect(revised?.rowID == original?.rowID)
  #expect(revised?.text == "corrected")
  #expect(revised?.revisionFingerprint != original?.revisionFingerprint)

  try await Task.sleep(nanoseconds: 50_000_000)
  let currentFingerprint = try store.recentMessages(
    atOrBeforeRowID: 1,
    chatID: nil,
    limit: 1
  ).first?.revisionFingerprint
  #expect(revised?.revisionFingerprint == currentFingerprint)
}

@Test
func messageWatcherStillFindsAnOldRevisionAfterMoreThanTheRecentScanLimit() async throws {
  let (store, db) = try WatcherTestDatabase.makeMutableStore()
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      batchLimit: 10,
      revisionScanLimit: 2,
      fallbackPollInterval: 0.01
    )
  )
  var iterator = stream.makeAsyncIterator()
  let original = try await iterator.next()
  #expect(original?.rowID == 1)

  let now = Date()
  for rowID in 2...6 {
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (?, 1, ?, ?, 0, 'iMessage')
      """,
      Int64(rowID), "message-\(rowID)", WatcherTestDatabase.appleEpoch(now)
    )
    try db.run(
      "INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)",
      Int64(rowID)
    )
  }
  for expectedRowID in 2...6 {
    let arrived = try await iterator.next()
    #expect(arrived?.rowID == Int64(expectedRowID))
  }

  let editedAt = WatcherTestDatabase.appleEpoch(Date().addingTimeInterval(1))
  try db.run(
    "UPDATE message SET text = 'old but corrected', date_edited = ? WHERE ROWID = 1",
    editedAt
  )
  let revised = try await iterator.next()
  #expect(revised?.rowID == 1)
  #expect(revised?.text == "old but corrected")
  #expect(revised?.revisionFingerprint != original?.revisionFingerprint)
}

@Test
func messageWatcherRedeliversWhenSameRowAttachmentBecomesAvailable() async throws {
  let (store, db) = try WatcherTestDatabase.makeMutableStore()
  let attachmentURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("imsg-watcher-\(UUID().uuidString).txt")
  defer { try? FileManager.default.removeItem(at: attachmentURL) }
  try db.run(
    """
    INSERT INTO attachment(ROWID, filename, transfer_name, uti, mime_type, total_bytes, is_sticker)
    VALUES (1, ?, 'arrival.txt', 'public.plain-text', 'text/plain', 4, 0)
    """,
    attachmentURL.path
  )
  try db.run(
    "INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (1, 1)"
  )

  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      batchLimit: 10,
      revisionScanLimit: 10,
      fallbackPollInterval: 0.01
    )
  )
  var iterator = stream.makeAsyncIterator()
  let unavailable = try await iterator.next()
  #expect(unavailable?.rowID == 1)

  try Data("file".utf8).write(to: attachmentURL)
  let available = try await iterator.next()
  #expect(available?.rowID == unavailable?.rowID)
  #expect(available?.attachmentRevisionEvidence != unavailable?.attachmentRevisionEvidence)
  #expect(available?.revisionFingerprint != unavailable?.revisionFingerprint)
}

@Test
func messageWatcherReplaysBoundedRowsAtDurableCursorAfterRestart() async throws {
  let store = try WatcherTestDatabase.makeStore()
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    sinceRowID: 1,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      batchLimit: 10,
      revisionScanLimit: 10,
      replayRecentRevisionsOnStart: true,
      fallbackPollInterval: 0.01
    )
  )

  var iterator = stream.makeAsyncIterator()
  let replayed = try await iterator.next()
  #expect(replayed?.rowID == 1)
  #expect(replayed?.isEdited == true)
  #expect(replayed?.revisionFingerprint.isEmpty == false)
}

@Test
func messageWatcherMarksEveryBaselineHistoryReplayAsARevision() async throws {
  let (store, db) = try WatcherTestDatabase.makeMutableStore()
  let now = Date()
  try db.run(
    """
    INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
    VALUES (2, 1, 'old attachment', ?, 0, 'iMessage')
    """,
    WatcherTestDatabase.appleEpoch(now)
  )
  try db.run("INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, 2)")
  let attachmentURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("imsg-baseline-history-\(UUID().uuidString).txt")
  defer { try? FileManager.default.removeItem(at: attachmentURL) }
  try Data("old".utf8).write(to: attachmentURL)
  try db.run(
    """
    INSERT INTO attachment(ROWID, filename, transfer_name, uti, mime_type, total_bytes, is_sticker)
    VALUES (1, ?, 'old.txt', 'public.plain-text', 'text/plain', 3, 0)
    """,
    attachmentURL.path
  )
  try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (2, 1)")

  // A first launch stores maxRowID 2 as its baseline without emitting rows 1-2.
  // On restart both the plain recent row and attachment-bearing row are history,
  // never new requests.
  let stream = MessageWatcher(store: store).stream(
    sinceRowID: 2,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      batchLimit: 10,
      revisionScanLimit: 10,
      replayRecentRevisionsOnStart: true,
      fallbackPollInterval: 0.01
    )
  )
  var iterator = stream.makeAsyncIterator()
  var replayed: [Message] = []
  for _ in 0..<2 {
    if let message = try await iterator.next() { replayed.append(message) }
  }

  #expect(Set(replayed.map(\.rowID)) == Set([Int64(1), Int64(2)]))
  #expect(replayed.allSatisfy { $0.isEdited })
}

@Test
func messageWatcherReplaysAnOfflineEditOlderThanTheRecentRestartWindow() async throws {
  let (store, db) = try WatcherTestDatabase.makeMutableStore()
  let now = Date()
  for rowID in 2...300 {
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (?, 1, ?, ?, 0, 'iMessage')
      """,
      Int64(rowID), "message-\(rowID)", WatcherTestDatabase.appleEpoch(now)
    )
    try db.run(
      "INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)",
      Int64(rowID)
    )
  }
  try db.run(
    "UPDATE message SET text = 'edited while offline', date_edited = ? WHERE ROWID = 1",
    WatcherTestDatabase.appleEpoch(now.addingTimeInterval(1))
  )

  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    sinceRowID: 300,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      batchLimit: 32,
      revisionScanLimit: 2,
      replayRecentRevisionsOnStart: true,
      fallbackPollInterval: 0.01
    )
  )
  var iterator = stream.makeAsyncIterator()
  var replayed: [Message] = []
  for _ in 0..<3 {
    if let message = try await iterator.next() { replayed.append(message) }
  }
  #expect(replayed.contains { $0.rowID == 1 && $0.text == "edited while offline" })
}

@Test
func messageWatcherReplaysAnOfflineAttachmentAssociationOlderThanTheRecentWindow() async throws {
  let (store, db) = try WatcherTestDatabase.makeMutableStore()
  let now = Date()
  for rowID in 2...300 {
    try db.run(
      """
      INSERT INTO message(ROWID, handle_id, text, date, is_from_me, service)
      VALUES (?, 1, ?, ?, 0, 'iMessage')
      """,
      Int64(rowID), "message-\(rowID)", WatcherTestDatabase.appleEpoch(now)
    )
    try db.run(
      "INSERT INTO chat_message_join(chat_id, message_id) VALUES (1, ?)",
      Int64(rowID)
    )
  }
  let attachmentURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("imsg-offline-association-\(UUID().uuidString).txt")
  defer { try? FileManager.default.removeItem(at: attachmentURL) }
  try Data("late".utf8).write(to: attachmentURL)
  try db.run(
    """
    INSERT INTO attachment(ROWID, filename, transfer_name, uti, mime_type, total_bytes, is_sticker)
    VALUES (1, ?, 'late.txt', 'public.plain-text', 'text/plain', 4, 0)
    """,
    attachmentURL.path
  )
  try db.run("INSERT INTO message_attachment_join(message_id, attachment_id) VALUES (1, 1)")

  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    sinceRowID: 300,
    configuration: MessageWatcherConfiguration(
      debounceInterval: 0.01,
      batchLimit: 32,
      revisionScanLimit: 2,
      replayRecentRevisionsOnStart: true,
      fallbackPollInterval: 0.01
    )
  )
  var iterator = stream.makeAsyncIterator()
  var replayed: [Message] = []
  for _ in 0..<3 {
    if let message = try await iterator.next() { replayed.append(message) }
  }
  #expect(replayed.contains {
    $0.rowID == 1 && $0.attachmentsCount == 1 && !$0.attachmentRevisionEvidence.isEmpty
  })
}

@Test
func messageWatcherYieldsExistingMessages() async throws {
  let store = try WatcherTestDatabase.makeStore()
  let watcher = MessageWatcher(store: store)
  let stream = watcher.stream(
    chatID: nil,
    sinceRowID: -1,
    configuration: MessageWatcherConfiguration(debounceInterval: 0.01, batchLimit: 10)
  )

  let task = Task { () throws -> Message? in
    var iterator = stream.makeAsyncIterator()
    return try await iterator.next()
  }

  let message = try await task.value
  #expect(message?.text == "hello")
}
