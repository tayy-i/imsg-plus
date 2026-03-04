import Foundation

#if canImport(AppKit)
  import AppKit
#endif

// iMessage custom attribute keys
private let kIMBold = NSAttributedString.Key("__kIMTextBoldAttributeName")
private let kIMItalic = NSAttributedString.Key("__kIMTextItalicAttributeName")
private let kIMUnderline = NSAttributedString.Key("__kIMTextUnderlineAttributeName")
private let kIMStrikethrough = NSAttributedString.Key(
  "__kIMTextStrikethroughAttributeName")
private let kIMLink = NSAttributedString.Key("__kIMLinkAttributeName")

public struct ParsedMessageBody: Sendable {
  public let plainText: String
  public let markdown: String
}

public enum AttributedBodyParser {

  public static func parse(_ data: Data) -> ParsedMessageBody {
    guard !data.isEmpty else {
      return ParsedMessageBody(plainText: "", markdown: "")
    }

    #if canImport(AppKit)
      if let result = parseViaUnarchiver(data) {
        return result
      }
    #endif

    // Fallback to existing TypedStreamParser
    let plain = TypedStreamParser.parseAttributedBody(data)
    return ParsedMessageBody(plainText: plain, markdown: plain)
  }

  #if canImport(AppKit)
    @available(macOS, deprecated: 10.13)
    private static func parseViaUnarchiver(_ data: Data) -> ParsedMessageBody? {
      guard let obj = NSUnarchiver.unarchiveObject(with: data) else {
        return nil
      }

      guard let attrString = obj as? NSAttributedString, attrString.length > 0 else {
        return nil
      }

      let plainText = attrString.string
      let markdown = convertToMarkdown(attrString)

      return ParsedMessageBody(plainText: plainText, markdown: markdown)
    }

    private static func convertToMarkdown(_ attrString: NSAttributedString) -> String {
      var result = ""
      let fullRange = NSRange(location: 0, length: attrString.length)

      attrString.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
        let substring =
          (attrString.string as NSString).substring(with: range)

        var isBold = false
        var isItalic = false
        var isStrikethrough = false
        var isUnderline = false
        var linkURL: String?

        // Check iMessage custom attributes
        if let val = attrs[kIMBold] as? Int, val != 0 {
          isBold = true
        }
        if let val = attrs[kIMItalic] as? Int, val != 0 {
          isItalic = true
        }
        if let val = attrs[kIMStrikethrough] as? Int, val != 0 {
          isStrikethrough = true
        }
        if let val = attrs[kIMUnderline] as? Int, val != 0 {
          isUnderline = true
        }

        // Check iMessage link attribute
        if let link = attrs[kIMLink] {
          if let url = link as? URL {
            linkURL = url.absoluteString
          } else if let urlString = link as? String {
            linkURL = urlString
          }
        }

        // Fallback: check standard AppKit attributes
        if !isBold && !isItalic {
          if let font = attrs[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            if traits.contains(.bold) { isBold = true }
            if traits.contains(.italic) { isItalic = true }
          }
        }
        if !isStrikethrough {
          if let val = attrs[.strikethroughStyle] as? Int, val != 0 {
            isStrikethrough = true
          }
        }
        if !isUnderline {
          if let val = attrs[.underlineStyle] as? Int, val != 0 {
            isUnderline = true
          }
        }
        if linkURL == nil {
          if let link = attrs[.link] {
            if let url = link as? URL {
              linkURL = url.absoluteString
            } else if let urlString = link as? String {
              linkURL = urlString
            }
          }
        }

        var text = substring

        // Apply markdown formatting (inner to outer)
        if let url = linkURL {
          text = "[\(text)](\(url))"
        } else {
          if isStrikethrough {
            text = "~~\(text)~~"
          }
          if isUnderline {
            text = "__\(text)__"
          }
          if isItalic {
            text = "*\(text)*"
          }
          if isBold {
            text = "**\(text)**"
          }
        }

        result += text
      }

      return result
    }
  #endif
}
