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
func crossProcessFileLockSerializesSeparateOpenHandles() throws {
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
