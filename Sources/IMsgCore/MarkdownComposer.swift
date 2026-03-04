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

public enum MarkdownComposer {

  /// Convert markdown text to NSAttributedString data (base64-ready for IPC)
  /// Returns nil if no markdown formatting detected or AppKit unavailable
  public static func compose(_ markdown: String) -> Data? {
    #if canImport(AppKit)
      let attrString = parseMarkdown(markdown)
      return archiveAttributedString(attrString)
    #else
      return nil
    #endif
  }

  /// Strip markdown markers and return plain text
  public static func stripMarkdown(_ markdown: String) -> String {
    var text = markdown

    // Links: [text](url) -> text
    let linkPattern = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^)]+\\)")
    if let linkPattern {
      text = linkPattern.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    // Bold: **text** -> text
    let boldPattern = try? NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
    if let boldPattern {
      text = boldPattern.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    // Italic: *text* -> text
    let italicPattern = try? NSRegularExpression(
      pattern: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)")
    if let italicPattern {
      text = italicPattern.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    // Strikethrough: ~~text~~ -> text
    let strikePattern = try? NSRegularExpression(pattern: "~~(.+?)~~")
    if let strikePattern {
      text = strikePattern.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    // Underline: __text__ -> text
    let underlinePattern = try? NSRegularExpression(pattern: "__(.+?)__")
    if let underlinePattern {
      text = underlinePattern.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
    }

    return text
  }

  #if canImport(AppKit)
    private static func parseMarkdown(_ markdown: String) -> NSAttributedString {
      let result = NSMutableAttributedString()

      // Tokenize and build attributed string
      var remaining = markdown

      while !remaining.isEmpty {
        // Bold: **text**
        if let match = remaining.range(of: "\\*\\*(.+?)\\*\\*", options: .regularExpression) {
          let before = String(remaining[remaining.startIndex..<match.lowerBound])
          if !before.isEmpty {
            result.append(NSAttributedString(string: before))
          }
          let inner = String(remaining[match]).dropFirst(2).dropLast(2)
          result.append(
            NSAttributedString(string: String(inner), attributes: [kIMBold: 1]))
          remaining = String(remaining[match.upperBound...])
          continue
        }

        // Italic: *text*
        if let match = remaining.range(
          of: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)", options: .regularExpression)
        {
          let before = String(remaining[remaining.startIndex..<match.lowerBound])
          if !before.isEmpty {
            result.append(NSAttributedString(string: before))
          }
          let inner = String(remaining[match]).dropFirst(1).dropLast(1)
          result.append(
            NSAttributedString(string: String(inner), attributes: [kIMItalic: 1]))
          remaining = String(remaining[match.upperBound...])
          continue
        }

        // Strikethrough: ~~text~~
        if let match = remaining.range(of: "~~(.+?)~~", options: .regularExpression) {
          let before = String(remaining[remaining.startIndex..<match.lowerBound])
          if !before.isEmpty {
            result.append(NSAttributedString(string: before))
          }
          let inner = String(remaining[match]).dropFirst(2).dropLast(2)
          result.append(
            NSAttributedString(
              string: String(inner), attributes: [kIMStrikethrough: 1]))
          remaining = String(remaining[match.upperBound...])
          continue
        }

        // Underline: __text__
        if let match = remaining.range(of: "__(.+?)__", options: .regularExpression) {
          let before = String(remaining[remaining.startIndex..<match.lowerBound])
          if !before.isEmpty {
            result.append(NSAttributedString(string: before))
          }
          let inner = String(remaining[match]).dropFirst(2).dropLast(2)
          result.append(
            NSAttributedString(
              string: String(inner), attributes: [kIMUnderline: 1]))
          remaining = String(remaining[match.upperBound...])
          continue
        }

        // Link: [text](url)
        if let match = remaining.range(
          of: "\\[([^\\]]+)\\]\\(([^)]+)\\)", options: .regularExpression)
        {
          let before = String(remaining[remaining.startIndex..<match.lowerBound])
          if !before.isEmpty {
            result.append(NSAttributedString(string: before))
          }
          let matched = String(remaining[match])
          if let textRange = matched.range(
            of: "(?<=\\[)[^\\]]+(?=\\])", options: .regularExpression),
            let urlRange = matched.range(
              of: "(?<=\\()[^)]+(?=\\))", options: .regularExpression)
          {
            let linkText = String(matched[textRange])
            let urlString = String(matched[urlRange])
            var attrs: [NSAttributedString.Key: Any] = [:]
            if let url = URL(string: urlString) {
              attrs[kIMLink] = url
            }
            result.append(NSAttributedString(string: linkText, attributes: attrs))
          }
          remaining = String(remaining[match.upperBound...])
          continue
        }

        // No match found at current position - consume one character
        let nextChar = String(remaining.prefix(1))
        result.append(NSAttributedString(string: nextChar))
        remaining = String(remaining.dropFirst())
      }

      return result
    }

    @available(macOS, deprecated: 10.13)
    private static func archiveAttributedString(_ attrString: NSAttributedString) -> Data? {
      return NSArchiver.archivedData(withRootObject: attrString)
    }
  #endif
}
