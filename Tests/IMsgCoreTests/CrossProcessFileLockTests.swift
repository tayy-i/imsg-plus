import Foundation
import Testing

@testable import IMsgCore

private final class LockTestResult: @unchecked Sendable {
  private let lock = NSLock()
  private var failures = 0

  func recordFailure() {
    lock.withLock {
      failures += 1
    }
  }

  var didFail: Bool {
    lock.withLock { failures > 0 }
  }
}

@Test
func fileLockSerializesSeparateOpenHandlesInOneProcess() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let path = directory.appendingPathComponent("command.lock").path
  let firstEntered = DispatchSemaphore(value: 0)
  let releaseFirst = DispatchSemaphore(value: 0)
  let secondEntered = DispatchSemaphore(value: 0)
  let finished = DispatchSemaphore(value: 0)
  let result = LockTestResult()

  DispatchQueue.global().async {
    do {
      _ = try CrossProcessFileLock.withExclusiveLock(at: path) {
        firstEntered.signal()
        releaseFirst.wait()
      }
    } catch {
      result.recordFailure()
    }
    finished.signal()
  }

  #expect(firstEntered.wait(timeout: .now() + 2) == .success)

  DispatchQueue.global().async {
    do {
      _ = try CrossProcessFileLock.withExclusiveLock(at: path) {
        secondEntered.signal()
      }
    } catch {
      result.recordFailure()
    }
    finished.signal()
  }

  #expect(secondEntered.wait(timeout: .now() + 0.2) == .timedOut)
  releaseFirst.signal()
  #expect(secondEntered.wait(timeout: .now() + 2) == .success)
  #expect(finished.wait(timeout: .now() + 2) == .success)
  #expect(finished.wait(timeout: .now() + 2) == .success)
  #expect(result.didFail == false)

  let attributes = try FileManager.default.attributesOfItem(atPath: path)
  let permissions = attributes[.posixPermissions] as? NSNumber
  #expect(permissions?.intValue == 0o600)
}

@Test
func fileLockStopsWaitingAtItsDeadline() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let path = directory.appendingPathComponent("command.lock").path
  let firstEntered = DispatchSemaphore(value: 0)
  let releaseFirst = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    _ = try? CrossProcessFileLock.withExclusiveLock(at: path) {
      firstEntered.signal()
      releaseFirst.wait()
    }
  }
  #expect(firstEntered.wait(timeout: .now() + 2) == .success)
  defer { releaseFirst.signal() }

  #expect(throws: CrossProcessFileLockError.self) {
    try CrossProcessFileLock.withExclusiveLock(at: path, timeout: 0.1) {}
  }
}

@Test
func fileLockIsReleasedWhenAnotherProcessTerminates() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let path = directory.appendingPathComponent("command.lock").path
  let readyPath = directory.appendingPathComponent("holder.ready").path
  let holder = Process()
  holder.executableURL = try lockHolderFixtureURL()
  holder.arguments = [path, readyPath]
  holder.standardOutput = FileHandle.nullDevice
  holder.standardError = FileHandle.nullDevice
  try holder.run()
  defer {
    if holder.isRunning {
      holder.terminate()
      holder.waitUntilExit()
    }
  }

  let readyDeadline = Date().addingTimeInterval(5)
  while !FileManager.default.fileExists(atPath: readyPath), Date() < readyDeadline {
    Thread.sleep(forTimeInterval: 0.02)
  }
  #expect(FileManager.default.fileExists(atPath: readyPath))
  #expect(throws: CrossProcessFileLockError.self) {
    try CrossProcessFileLock.withExclusiveLock(at: path, timeout: 0.1) {}
  }

  holder.terminate()
  holder.waitUntilExit()
  var acquired = false
  try CrossProcessFileLock.withExclusiveLock(at: path, timeout: 1) {
    acquired = true
  }
  #expect(acquired)
}

private func lockHolderFixtureURL() throws -> URL {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let buildRoot = packageRoot.appendingPathComponent(".build")
  let architectureRoots = try FileManager.default.contentsOfDirectory(
    at: buildRoot,
    includingPropertiesForKeys: nil
  )
  let candidates = [buildRoot.appendingPathComponent("debug/LockHolderFixture")]
    + architectureRoots.map { $0.appendingPathComponent("debug/LockHolderFixture") }
  if let executable = candidates.first(where: {
    FileManager.default.isExecutableFile(atPath: $0.path)
  }) {
    return executable
  }
  throw CocoaError(.fileNoSuchFile)
}
