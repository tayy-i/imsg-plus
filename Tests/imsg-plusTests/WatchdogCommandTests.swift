import Foundation
import Testing

@testable import imsg_plus

private func matchesWatchdogRestartPattern(_ line: String) -> Bool {
  WatchdogCommand.matchingErrorPattern(in: line) != nil
}

@Test
func watchdogIgnoresBenignXPCInvalidations() {
  #expect(
    !matchesWatchdogRestartPattern(
      "[com.apple.xpc:connection] invalidated because the current process cancelled the connection by calling xpc_connection_cancel()"
    )
  )
  #expect(
    !matchesWatchdogRestartPattern(
      "Error communicating with persistent store service proxy: Sandbox restriction for com.apple.contactsd.persistence"
    )
  )
}

@Test
func watchdogKeepsSpecificSendFailureSignals() {
  #expect(matchesWatchdogRestartPattern("Unable to send to server"))
  #expect(matchesWatchdogRestartPattern("PSC out of sync"))
}

@Test
func watchdogReadsOnlyTheBoundedLogTailForStatus() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  var data = Data(repeating: 0xFF, count: Int(WatchdogCommand.incidentScanBytes) + 1)
  data.append(0x0A)
  data.append(contentsOf: "[2026-08-10T00:00:00Z] ERROR DETECTED: Unable to send to server\n".utf8)
  try data.write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }

  #expect(
    WatchdogCommand.getLastIncident(path: url.path)
      == "[2026-08-10T00:00:00Z] ERROR DETECTED: Unable to send to server"
  )
}

@Test
func watchdogTruncatesAnOversizedLogBeforeStart() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  let data = Data(repeating: 0x41, count: Int(WatchdogCommand.maximumLogBytes) + 1)
  try data.write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }

  try WatchdogCommand.truncateOversizedLogBeforeStart(path: url.path)

  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  #expect((attributes[.size] as? NSNumber)?.uint64Value == 0)
}

@Test
func watchdogLogIsVisibleBeforeTheWriterExits() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  FileManager.default.createFile(atPath: url.path, contents: nil)
  let output = try FileHandle(forWritingTo: url)
  defer {
    try? output.close()
    try? FileManager.default.removeItem(at: url)
  }

  WatchdogCommand.log("live incident", to: output)

  let content = try String(contentsOf: url, encoding: .utf8)
  #expect(content.contains("live incident"))
}
