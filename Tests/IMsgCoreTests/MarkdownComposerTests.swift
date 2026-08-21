import AppKit
import XCTest

@testable import IMsgCore

final class MarkdownComposerTests: XCTestCase {
  func testLinkBeforeLaterFormattingKeepsBothAttributes() throws {
    let data = try XCTUnwrap(
      MarkdownComposer.compose("See [Rose](https://example.com/rose) and **more**")
    )
    let attributed = try XCTUnwrap(
      NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString
    )

    XCTAssertEqual(attributed.string, "See Rose and more")
    XCTAssertEqual(
      attributed.attribute(
        NSAttributedString.Key("__kIMLinkAttributeName"),
        at: 4,
        effectiveRange: nil
      ) as? URL,
      URL(string: "https://example.com/rose")
    )
    XCTAssertEqual(
      attributed.attribute(
        NSAttributedString.Key("__kIMTextBoldAttributeName"),
        at: 13,
        effectiveRange: nil
      ) as? Int,
      1
    )
  }
}
