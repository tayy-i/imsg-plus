import AppKit
import XCTest

@testable import IMsgCore

final class MarkdownComposerTests: XCTestCase {
  func testStylesAroundLinksAndInsideLabelsPreserveBothAttributes() throws {
    let styles = [
      ("**", "__kIMTextBoldAttributeName"),
      ("*", "__kIMTextItalicAttributeName"),
      ("__", "__kIMTextUnderlineAttributeName"),
      ("~~", "__kIMTextStrikethroughAttributeName"),
    ]
    let url = try XCTUnwrap(URL(string: "https://example.com/maps?q=cafe&lang=en"))
    let linkKey = NSAttributedString.Key("__kIMLinkAttributeName")
    for (marker, key) in styles {
      for link in [
        "\(marker)[café ☕️](\(url.absoluteString))\(marker)",
        "[\(marker)café ☕️\(marker)](\(url.absoluteString))",
      ] {
        let attributed = try decode("See \(link) today")
        XCTAssertEqual(attributed.string, "See café ☕️ today")
        let labelRange = (attributed.string as NSString).range(of: "café ☕️")
        for index in labelRange.location..<NSMaxRange(labelRange) {
          XCTAssertEqual(attributed.attribute(linkKey, at: index, effectiveRange: nil) as? URL, url)
          XCTAssertEqual(
            attributed.attribute(NSAttributedString.Key(key), at: index, effectiveRange: nil)
              as? Int,
            1
          )
        }
        for index in [0, attributed.length - 1] {
          XCTAssertNil(attributed.attribute(linkKey, at: index, effectiveRange: nil))
          XCTAssertNil(
            attributed.attribute(NSAttributedString.Key(key), at: index, effectiveRange: nil))
        }
      }
    }
  }

  func testNestedStylesApplyOnlyToTheirLinkLabelRanges() throws {
    let attributed = try decode(
      "**[Rose *tea*](https://example.com/tea)** and [coffee](https://example.com/coffee)"
    )
    XCTAssertEqual(attributed.string, "Rose tea and coffee")
    let linkKey = NSAttributedString.Key("__kIMLinkAttributeName")
    let boldKey = NSAttributedString.Key("__kIMTextBoldAttributeName")
    let italicKey = NSAttributedString.Key("__kIMTextItalicAttributeName")
    for index in 0..<8 {
      XCTAssertEqual(
        attributed.attribute(linkKey, at: index, effectiveRange: nil) as? URL,
        URL(string: "https://example.com/tea")
      )
      XCTAssertEqual(attributed.attribute(boldKey, at: index, effectiveRange: nil) as? Int, 1)
      XCTAssertEqual(
        attributed.attribute(italicKey, at: index, effectiveRange: nil) as? Int,
        index >= 5 ? 1 : nil
      )
    }
    for index in 8..<attributed.length {
      XCTAssertNil(attributed.attribute(boldKey, at: index, effectiveRange: nil))
      XCTAssertNil(attributed.attribute(italicKey, at: index, effectiveRange: nil))
      XCTAssertEqual(
        attributed.attribute(linkKey, at: index, effectiveRange: nil) as? URL,
        index >= 13 ? URL(string: "https://example.com/coffee") : nil
      )
    }
  }

  private func decode(_ text: String) throws -> NSAttributedString {
    let data = try XCTUnwrap(MarkdownComposer.compose(text))
    return try XCTUnwrap(NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString)
  }

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
