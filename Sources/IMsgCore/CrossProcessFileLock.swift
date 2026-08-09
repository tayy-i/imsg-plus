import Darwin
import Foundation

enum CrossProcessFileLock {
  static func withExclusiveLock<T>(at path: String, _ body: () throws -> T) throws -> T {
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
    try lock(descriptor)
    defer { unlock(descriptor) }

    return try body()
  }

  private static func lock(_ descriptor: Int32) throws {
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else {
        throw CrossProcessFileLockError.lockFailed
      }
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
}
