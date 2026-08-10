import Darwin
import Foundation

guard CommandLine.arguments.count == 3 else { exit(2) }
let lockPath = CommandLine.arguments[1]
let readyPath = CommandLine.arguments[2]
let descriptor = lockPath.withCString {
  Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
}
guard descriptor >= 0 else { exit(3) }
defer { Darwin.close(descriptor) }
guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { exit(4) }
guard flock(descriptor, LOCK_EX) == 0 else { exit(5) }
defer { flock(descriptor, LOCK_UN) }

let readyDescriptor = readyPath.withCString {
  Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
}
guard readyDescriptor >= 0 else { exit(6) }
Darwin.close(readyDescriptor)

while true { pause() }
