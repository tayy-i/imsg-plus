import Foundation

enum ProviderIdentity {
  static func databaseEpoch(
    volumeUUID: String,
    fileNumber: UInt64,
    creationDate: Date
  ) throws -> String {
    let normalizedVolumeUUID = volumeUUID.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !normalizedVolumeUUID.isEmpty else {
      throw NSError(
        domain: "IMsgCore.ProviderIdentity",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Messages database volume identity is unavailable"]
      )
    }
    let creationIdentity = String(
      format: "%016llx",
      creationDate.timeIntervalSinceReferenceDate.bitPattern
    )
    return "messages-db-v4:\(normalizedVolumeUUID):\(fileNumber):\(creationIdentity)"
  }
}
