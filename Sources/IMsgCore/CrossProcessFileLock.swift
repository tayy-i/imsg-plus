import Darwin
import Foundation

enum CrossProcessFileLock {
  static let defaultTimeout: TimeInterval = 5

  static func withExclusiveLock<T>(
    at path: String,
    timeout: TimeInterval = defaultTimeout,
    _ body: () throws -> T
  ) throws -> T {
    let flags = O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW
    let descriptor = path.withCString {
      Darwin.open($0, flags, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else {
      throw CrossProcessFileLockError.openFailed
    }
    defer { Darwin.close(descriptor) }

    guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
      throw CrossProcessFileLockError.permissionFailed
    }
    try lock(descriptor, timeout: timeout)
    defer { unlock(descriptor) }

    return try body()
  }

  private static func lock(_ descriptor: Int32, timeout: TimeInterval) throws {
    guard timeout > 0 else { throw CrossProcessFileLockError.timedOut }
    let deadline = Date().addingTimeInterval(timeout)
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      if errno == EINTR { continue }
      guard errno == EWOULDBLOCK || errno == EAGAIN else {
        throw CrossProcessFileLockError.lockFailed
      }
      guard Date() < deadline else {
        throw CrossProcessFileLockError.timedOut
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  private static func unlock(_ descriptor: Int32) {
    while flock(descriptor, LOCK_UN) != 0 && errno == EINTR {}
  }
}

enum CrossProcessFileLockError: Error {
  case openFailed
  case permissionFailed
  case lockFailed
  case timedOut
}
