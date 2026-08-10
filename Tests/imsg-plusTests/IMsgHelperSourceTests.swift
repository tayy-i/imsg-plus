import Foundation
import Testing

@Test
func composedMessagesProvideTheirPersistedGUID() throws {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let helperSource =
    packageRoot
    .appendingPathComponent("Sources/IMsgHelper/IMsgInjected.m")
  let source = try String(contentsOf: helperSource, encoding: .utf8)

  #expect(source.contains("NSString *firstGUID = [[NSUUID UUID] UUIDString];"))
  #expect(
    source.range(
      of: #"messagesSelector,\s*firstGUID,\s*service"#,
      options: .regularExpression
    ) != nil
  )
}
