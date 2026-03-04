import Testing

@testable import IMsgCore

@Suite("TapbackType Tests")
struct TapbackTypeTests {

  // MARK: - Standard name parsing

  @Test("Parse standard type names")
  func standardNames() {
    #expect(TapbackType.from(string: "love") == .love)
    #expect(TapbackType.from(string: "heart") == .love)
    #expect(TapbackType.from(string: "thumbsup") == .thumbsUp)
    #expect(TapbackType.from(string: "like") == .thumbsUp)
    #expect(TapbackType.from(string: "thumbsdown") == .thumbsDown)
    #expect(TapbackType.from(string: "dislike") == .thumbsDown)
    #expect(TapbackType.from(string: "haha") == .haha)
    #expect(TapbackType.from(string: "laugh") == .haha)
    #expect(TapbackType.from(string: "emphasis") == .emphasis)
    #expect(TapbackType.from(string: "exclaim") == .emphasis)
    #expect(TapbackType.from(string: "!!") == .emphasis)
    #expect(TapbackType.from(string: "question") == .question)
    #expect(TapbackType.from(string: "?") == .question)
  }

  @Test("Parse standard names is case-insensitive")
  func caseInsensitive() {
    #expect(TapbackType.from(string: "LOVE") == .love)
    #expect(TapbackType.from(string: "ThumbsUp") == .thumbsUp)
    #expect(TapbackType.from(string: "HAHA") == .haha)
  }

  // MARK: - Standard emoji → standard type mapping

  @Test("Standard emoji characters map to standard types")
  func standardEmojiMapping() {
    #expect(TapbackType.from(string: "❤️") == .love)
    #expect(TapbackType.from(string: "❤") == .love)
    #expect(TapbackType.from(string: "👍") == .thumbsUp)
    #expect(TapbackType.from(string: "👎") == .thumbsDown)
    #expect(TapbackType.from(string: "😂") == .haha)
    #expect(TapbackType.from(string: "‼️") == .emphasis)
    #expect(TapbackType.from(string: "‼") == .emphasis)
    #expect(TapbackType.from(string: "❓") == .question)
  }

  // MARK: - Custom emoji parsing

  @Test("Custom emoji maps to customEmoji case")
  func customEmoji() {
    #expect(TapbackType.from(string: "🎉") == .customEmoji("🎉"))
    #expect(TapbackType.from(string: "🔥") == .customEmoji("🔥"))
    #expect(TapbackType.from(string: "👀") == .customEmoji("👀"))
    #expect(TapbackType.from(string: "🫡") == .customEmoji("🫡"))
  }

  // MARK: - Removal variants

  @Test("Standard removal parsing")
  func standardRemoval() {
    #expect(TapbackType.from(string: "love", remove: true) == .removeLove)
    #expect(TapbackType.from(string: "thumbsup", remove: true) == .removeThumbsUp)
    #expect(TapbackType.from(string: "thumbsdown", remove: true) == .removeThumbsDown)
    #expect(TapbackType.from(string: "haha", remove: true) == .removeHaha)
    #expect(TapbackType.from(string: "emphasis", remove: true) == .removeEmphasis)
    #expect(TapbackType.from(string: "question", remove: true) == .removeQuestion)
  }

  @Test("Standard emoji removal")
  func standardEmojiRemoval() {
    #expect(TapbackType.from(string: "❤️", remove: true) == .removeLove)
    #expect(TapbackType.from(string: "👍", remove: true) == .removeThumbsUp)
  }

  @Test("Custom emoji removal")
  func customEmojiRemoval() {
    #expect(TapbackType.from(string: "🎉", remove: true) == .removeCustomEmoji("🎉"))
    #expect(TapbackType.from(string: "🔥", remove: true) == .removeCustomEmoji("🔥"))
  }

  // MARK: - Invalid strings

  @Test("Invalid strings return nil")
  func invalidStrings() {
    #expect(TapbackType.from(string: "invalid") == nil)
    #expect(TapbackType.from(string: "hello") == nil)
    #expect(TapbackType.from(string: "") == nil)
    #expect(TapbackType.from(string: "abc") == nil)
  }

  // MARK: - rawValue

  @Test("rawValue returns correct IMCore values")
  func rawValues() {
    #expect(TapbackType.love.rawValue == 2000)
    #expect(TapbackType.thumbsUp.rawValue == 2001)
    #expect(TapbackType.thumbsDown.rawValue == 2002)
    #expect(TapbackType.haha.rawValue == 2003)
    #expect(TapbackType.emphasis.rawValue == 2004)
    #expect(TapbackType.question.rawValue == 2005)
    #expect(TapbackType.customEmoji("🎉").rawValue == 2006)
    #expect(TapbackType.removeLove.rawValue == 3000)
    #expect(TapbackType.removeThumbsUp.rawValue == 3001)
    #expect(TapbackType.removeCustomEmoji("🎉").rawValue == 3006)
  }

  // MARK: - displayName

  @Test("displayName returns expected values")
  func displayNames() {
    #expect(TapbackType.love.displayName == "love")
    #expect(TapbackType.thumbsUp.displayName == "thumbsup")
    #expect(TapbackType.removeLove.displayName == "love")
    #expect(TapbackType.customEmoji("🎉").displayName == "🎉")
    #expect(TapbackType.removeCustomEmoji("🔥").displayName == "🔥")
  }

  // MARK: - emoji

  @Test("emoji returns correct emoji character")
  func emojiProperty() {
    #expect(TapbackType.love.emoji == "❤️")
    #expect(TapbackType.thumbsUp.emoji == "👍")
    #expect(TapbackType.thumbsDown.emoji == "👎")
    #expect(TapbackType.haha.emoji == "😂")
    #expect(TapbackType.emphasis.emoji == "‼️")
    #expect(TapbackType.question.emoji == "❓")
    #expect(TapbackType.customEmoji("🎉").emoji == "🎉")
    #expect(TapbackType.removeLove.emoji == "❤️")
    #expect(TapbackType.removeCustomEmoji("🔥").emoji == "🔥")
  }

  // MARK: - isCustom / customEmojiString

  @Test("isCustom distinguishes standard from custom")
  func isCustomProperty() {
    #expect(TapbackType.love.isCustom == false)
    #expect(TapbackType.thumbsUp.isCustom == false)
    #expect(TapbackType.removeLove.isCustom == false)
    #expect(TapbackType.customEmoji("🎉").isCustom == true)
    #expect(TapbackType.removeCustomEmoji("🔥").isCustom == true)
  }

  @Test("customEmojiString returns emoji for custom, nil for standard")
  func customEmojiStringProperty() {
    #expect(TapbackType.love.customEmojiString == nil)
    #expect(TapbackType.customEmoji("🎉").customEmojiString == "🎉")
    #expect(TapbackType.removeCustomEmoji("🔥").customEmojiString == "🔥")
  }

  // MARK: - isRemoval

  @Test("isRemoval for removal types")
  func isRemovalProperty() {
    #expect(TapbackType.love.isRemoval == false)
    #expect(TapbackType.customEmoji("🎉").isRemoval == false)
    #expect(TapbackType.removeLove.isRemoval == true)
    #expect(TapbackType.removeCustomEmoji("🎉").isRemoval == true)
  }
}
