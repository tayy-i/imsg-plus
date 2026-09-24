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
    private enum TokenKind: Int {
      case bold
      case italic
      case strikethrough
      case underline
      case link
    }

    private static func parseMarkdown(_ markdown: String) -> NSAttributedString {
      let result = NSMutableAttributedString()

      // Tokenize and build attributed string
      var remaining = markdown

      while !remaining.isEmpty {
        var candidates: [(kind: TokenKind, range: Range<String.Index>)] = []
        let patterns: [(TokenKind, String)] = [
          (.bold, "\\*\\*(.+?)\\*\\*"),
          (.italic, "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)"),
          (.strikethrough, "~~(.+?)~~"),
          (.underline, "__(.+?)__"),
          (.link, "\\[([^\\]]+)\\]\\(([^)]+)\\)"),
        ]
        for (kind, pattern) in patterns {
          if let range = remaining.range(of: pattern, options: .regularExpression) {
            candidates.append((kind, range))
          }
        }
        guard
          let next = candidates.min(by: { lhs, rhs in
            if lhs.range.lowerBound == rhs.range.lowerBound {
              return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.range.lowerBound < rhs.range.lowerBound
          })
        else {
          result.append(NSAttributedString(string: remaining))
          break
        }

        let before = String(remaining[remaining.startIndex..<next.range.lowerBound])
        if !before.isEmpty {
          result.append(NSAttributedString(string: before))
        }
        let matched = String(remaining[next.range])
        switch next.kind {
        case .bold:
          let inner = matched.dropFirst(2).dropLast(2)
          result.append(parseStyledText(String(inner), attribute: kIMBold))
        case .italic:
          let inner = matched.dropFirst().dropLast()
          result.append(parseStyledText(String(inner), attribute: kIMItalic))
        case .strikethrough:
          let inner = matched.dropFirst(2).dropLast(2)
          result.append(parseStyledText(String(inner), attribute: kIMStrikethrough))
        case .underline:
          let inner = matched.dropFirst(2).dropLast(2)
          result.append(parseStyledText(String(inner), attribute: kIMUnderline))
        case .link:
          if let textRange = matched.range(
            of: "(?<=\\[)[^\\]]+(?=\\])", options: .regularExpression),
            let urlRange = matched.range(
              of: "(?<=\\()[^)]+(?=\\))", options: .regularExpression)
          {
            let linkText = String(matched[textRange])
            let urlString = String(matched[urlRange])
            let label = NSMutableAttributedString(attributedString: parseMarkdown(linkText))
            if let url = URL(string: urlString) {
              label.addAttribute(
                kIMLink, value: url, range: NSRange(location: 0, length: label.length))
            }
            result.append(label)
          }
        }
        remaining = String(remaining[next.range.upperBound...])
      }

      return result
    }

    private static func parseStyledText(
      _ text: String, attribute: NSAttributedString.Key
    ) -> NSAttributedString {
      let result = NSMutableAttributedString(attributedString: parseMarkdown(text))
      result.addAttribute(attribute, value: 1, range: NSRange(location: 0, length: result.length))
      return result
    }

    @available(macOS, deprecated: 10.13)
    private static func archiveAttributedString(_ attrString: NSAttributedString) -> Data? {
      return NSArchiver.archivedData(withRootObject: attrString)
    }
  #endif
}
