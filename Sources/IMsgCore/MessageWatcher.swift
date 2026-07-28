import Darwin
import Foundation

public struct MessageWatcherConfiguration: Sendable, Equatable {
  public var debounceInterval: TimeInterval
  public var batchLimit: Int
  public var revisionScanLimit: Int
  public var replayRecentRevisionsOnStart: Bool
  public var fallbackPollInterval: TimeInterval

  public init(
    debounceInterval: TimeInterval = 0.25,
    batchLimit: Int = 100,
    revisionScanLimit: Int = 256,
    replayRecentRevisionsOnStart: Bool = false,
    fallbackPollInterval: TimeInterval = 1
  ) {
    self.debounceInterval = debounceInterval
    self.batchLimit = batchLimit
    self.revisionScanLimit = revisionScanLimit
    self.replayRecentRevisionsOnStart = replayRecentRevisionsOnStart
    self.fallbackPollInterval = fallbackPollInterval
  }
}

public final class MessageWatcher: @unchecked Sendable {
  private let store: MessageStore

  public init(store: MessageStore) {
    self.store = store
  }

  public func stream(
    chatID: Int64? = nil,
    sinceRowID: Int64? = nil,
    configuration: MessageWatcherConfiguration = MessageWatcherConfiguration()
  ) -> AsyncThrowingStream<Message, Error> {
    AsyncThrowingStream { continuation in
      let state = WatchState(
        store: store,
        chatID: chatID,
        sinceRowID: sinceRowID,
        configuration: configuration,
        continuation: continuation
      )
      state.start()
      continuation.onTermination = { _ in
        state.stop()
      }
    }
  }
}

private final class WatchState: @unchecked Sendable {
  // Rose approvals expire after five minutes. A ten-minute recovery window
  // covers a restart around that deadline without replaying lifetime tapbacks.
  private static let reactionReplayWindow: TimeInterval = 10 * 60

  private let store: MessageStore
  private let chatID: Int64?
  private let configuration: MessageWatcherConfiguration
  private let continuation: AsyncThrowingStream<Message, Error>.Continuation
  private let queue = DispatchQueue(label: "imsg.watch", qos: .userInitiated)
  private let hasExplicitCursor: Bool

  private var cursor: Int64
  private var sources: [DispatchSourceFileSystemObject] = []
  private var fallbackTimer: DispatchSourceTimer?
  private var pending = false
  private var revisionFingerprints: [Int64: String] = [:]
  private var trackedRevisionOffset = 0
  private var latestProviderDate: Date?

  init(
    store: MessageStore,
    chatID: Int64?,
    sinceRowID: Int64?,
    configuration: MessageWatcherConfiguration,
    continuation: AsyncThrowingStream<Message, Error>.Continuation
  ) {
    self.store = store
    self.chatID = chatID
    self.configuration = configuration
    self.continuation = continuation
    self.hasExplicitCursor = sinceRowID != nil
    self.cursor = sinceRowID ?? 0
  }

  func start() {
    queue.async {
      do {
        if !self.hasExplicitCursor {
          self.cursor = try self.store.maxRowID()
        }
        self.latestProviderDate = try self.latestDateAtCursor()
        try self.scanRecentRevisions(
          emitChanges: self.configuration.replayRecentRevisionsOnStart
        )
        if self.hasExplicitCursor && self.configuration.replayRecentRevisionsOnStart {
          try self.replayProviderEditsAtStartup()
        }
        self.pollNewRows()
      } catch {
        self.continuation.finish(throwing: error)
      }
    }

    let paths = [store.path, store.path + "-wal", store.path + "-shm"]
    for path in paths {
      if let source = makeSource(path: path) {
        sources.append(source)
      }
    }

    if configuration.fallbackPollInterval > 0 {
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(
        deadline: .now() + configuration.fallbackPollInterval,
        repeating: configuration.fallbackPollInterval
      )
      timer.setEventHandler { [weak self] in
        self?.poll()
      }
      timer.resume()
      fallbackTimer = timer
    }

  }

  func stop() {
    queue.async {
      for source in self.sources {
        source.cancel()
      }
      self.sources.removeAll()
      self.fallbackTimer?.cancel()
      self.fallbackTimer = nil
    }
  }

  private func makeSource(path: String) -> DispatchSourceFileSystemObject? {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return nil }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .extend, .rename, .delete],
      queue: queue
    )
    source.setEventHandler { [weak self] in
      self?.schedulePoll()
    }
    source.setCancelHandler {
      close(fd)
    }
    source.resume()
    return source
  }

  private func schedulePoll() {
    if pending { return }
    pending = true
    let delay = configuration.debounceInterval
    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.pending = false
      self.poll()
    }
  }

  private func poll() {
    do {
      try scanRecentRevisions(emitChanges: true)
      try scanTrackedRevisions()
      pollNewRows()
    } catch {
      continuation.finish(throwing: error)
    }
  }

  private func pollNewRows() {
    let batchLimit = max(configuration.batchLimit, 1)
    while true {
      do {
        let messages = try store.messagesAfter(
          afterRowID: cursor,
          chatID: chatID,
          limit: batchLimit
        )
        for message in messages {
          if let latestProviderDate, message.date < latestProviderDate {
            throw NSError(
              domain: "IMsgCore.MessageWatcher",
              code: 1,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "Messages provider appended history older than the durable cursor"
              ]
            )
          }
          emitIfChanged(message)
          cursor = max(cursor, message.rowID)
          if latestProviderDate == nil || message.date > latestProviderDate! {
            latestProviderDate = message.date
          }
        }
        if messages.count < batchLimit {
          return
        }
      } catch {
        continuation.finish(throwing: error)
        return
      }
    }
  }

  private func latestDateAtCursor() throws -> Date? {
    try store.latestProviderDate(atOrBeforeRowID: cursor, chatID: chatID)
  }

  private func scanRecentRevisions(emitChanges: Bool) throws {
    let scanLimit = max(configuration.revisionScanLimit, 0)
    guard scanLimit > 0 else { return }
    let messages = try store.recentMessages(
      atOrBeforeRowID: cursor,
      chatID: chatID,
      limit: scanLimit
    )
    for message in messages {
      if emitChanges {
        emitIfChanged(message)
      } else {
        revisionFingerprints[message.rowID] = message.revisionFingerprint
      }
    }
  }

  /// Revisit every row observed by this watcher in bounded round-robin
  /// batches. The recent scan above keeps fresh attachment arrivals quick;
  /// this scan ensures an older edit or retraction remains observable after
  /// more than `revisionScanLimit` newer rows arrive.
  private func scanTrackedRevisions() throws {
    let scanLimit = max(configuration.revisionScanLimit, 0)
    guard scanLimit > 0 else { return }
    let trackedRowIDs = revisionFingerprints.keys.sorted()
    guard trackedRowIDs.count > scanLimit else { return }

    trackedRevisionOffset %= trackedRowIDs.count
    var rowIDs: [Int64] = []
    rowIDs.reserveCapacity(scanLimit)
    for index in 0..<scanLimit {
      rowIDs.append(trackedRowIDs[(trackedRevisionOffset + index) % trackedRowIDs.count])
    }
    trackedRevisionOffset = (trackedRevisionOffset + scanLimit) % trackedRowIDs.count
    for message in try store.messages(rowIDs: rowIDs, chatID: chatID) {
      emitIfChanged(message)
    }
  }

  private func replayProviderEditsAtStartup() throws {
    let batchLimit = max(configuration.batchLimit, 1)
    var afterRowID: Int64 = 0
    while true {
      let messages = try store.revisedMessages(
        afterRowID: afterRowID,
        atOrBeforeRowID: cursor,
        chatID: chatID,
        reactionReplayAfter: Date().addingTimeInterval(-Self.reactionReplayWindow),
        limit: batchLimit
      )
      for message in messages {
        emitIfChanged(message)
        afterRowID = max(afterRowID, message.rowID)
      }
      if messages.count < batchLimit { return }
    }
  }

  private func emitIfChanged(_ message: Message) {
    let fingerprint = message.revisionFingerprint
    guard revisionFingerprints[message.rowID] != fingerprint else { return }
    revisionFingerprints[message.rowID] = fingerprint
    // Rows at or behind the durable cursor are replayed only to expose an edit,
    // retraction, or attachment revision. They can never be a new request: any
    // unacknowledged created row would necessarily be ahead of that cursor.
    // Marking all such replays as revisions prevents a first-install baseline
    // from executing old Messages history on the next launch.
    continuation.yield(
      message.rowID <= cursor ? message.asProviderRevision : message.asNewProviderRow
    )
  }
}

private extension Message {
  var asNewProviderRow: Message {
    Message(
      rowID: rowID,
      chatID: chatID,
      sender: sender,
      text: text,
      date: date,
      isFromMe: isFromMe,
      service: service,
      handleID: handleID,
      attachmentsCount: attachmentsCount,
      guid: guid,
      replyToGUID: replyToGUID,
      markdownText: markdownText,
      isEdited: isEdited,
      dateEdited: dateEdited,
      threadOriginatorGUID: threadOriginatorGUID,
      threadOriginatorPart: threadOriginatorPart,
      accountGUID: accountGUID,
      attachmentRevisionEvidence: attachmentRevisionEvidence,
      reactionRevisionEvidence: reactionRevisionEvidence,
      isNewProviderRow: true
    )
  }

  var asProviderRevision: Message {
    Message(
      rowID: rowID,
      chatID: chatID,
      sender: sender,
      text: text,
      date: date,
      isFromMe: isFromMe,
      service: service,
      handleID: handleID,
      attachmentsCount: attachmentsCount,
      guid: guid,
      replyToGUID: replyToGUID,
      markdownText: markdownText,
      isEdited: true,
      dateEdited: dateEdited,
      threadOriginatorGUID: threadOriginatorGUID,
      threadOriginatorPart: threadOriginatorPart,
      accountGUID: accountGUID,
      attachmentRevisionEvidence: attachmentRevisionEvidence,
      reactionRevisionEvidence: reactionRevisionEvidence,
      isNewProviderRow: false
    )
  }
}
