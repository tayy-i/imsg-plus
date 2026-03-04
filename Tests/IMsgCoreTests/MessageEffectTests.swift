import Testing

@testable import IMsgCore

@Suite("MessageEffect Tests")
struct MessageEffectTests {

  // MARK: - Parsing from string

  @Test("Parse all effect names")
  func allEffectNames() {
    #expect(MessageEffect.from(string: "gentle") == .gentle)
    #expect(MessageEffect.from(string: "slam") == .slam)
    #expect(MessageEffect.from(string: "loud") == .loud)
    #expect(MessageEffect.from(string: "invisibleink") == .invisibleInk)
    #expect(MessageEffect.from(string: "confetti") == .confetti)
    #expect(MessageEffect.from(string: "balloons") == .balloons)
    #expect(MessageEffect.from(string: "fireworks") == .fireworks)
    #expect(MessageEffect.from(string: "heart") == .heart)
    #expect(MessageEffect.from(string: "lasers") == .lasers)
    #expect(MessageEffect.from(string: "echo") == .echo)
    #expect(MessageEffect.from(string: "spotlight") == .spotlight)
    #expect(MessageEffect.from(string: "sparkles") == .sparkles)
    #expect(MessageEffect.from(string: "shootingstar") == .shootingStar)
  }

  @Test("Parse is case-insensitive")
  func caseInsensitive() {
    #expect(MessageEffect.from(string: "GENTLE") == .gentle)
    #expect(MessageEffect.from(string: "Slam") == .slam)
    #expect(MessageEffect.from(string: "INVISIBLEINK") == .invisibleInk)
    #expect(MessageEffect.from(string: "Confetti") == .confetti)
    #expect(MessageEffect.from(string: "SHOOTINGSTAR") == .shootingStar)
    #expect(MessageEffect.from(string: "Balloons") == .balloons)
  }

  @Test("Invalid strings return nil")
  func invalidStrings() {
    #expect(MessageEffect.from(string: "") == nil)
    #expect(MessageEffect.from(string: "invalid") == nil)
    #expect(MessageEffect.from(string: "love") == nil)
    #expect(MessageEffect.from(string: "boom") == nil)
    #expect(MessageEffect.from(string: "invisible ink") == nil)
    #expect(MessageEffect.from(string: "shooting star") == nil)
  }

  // MARK: - expressiveSendStyleId

  @Test("Bubble effects return correct Apple IDs")
  func bubbleEffectIds() {
    #expect(MessageEffect.gentle.expressiveSendStyleId == "com.apple.MobileSMS.expressivesend.gentle")
    #expect(MessageEffect.slam.expressiveSendStyleId == "com.apple.MobileSMS.expressivesend.impact")
    #expect(MessageEffect.loud.expressiveSendStyleId == "com.apple.MobileSMS.expressivesend.loud")
    #expect(
      MessageEffect.invisibleInk.expressiveSendStyleId
        == "com.apple.MobileSMS.expressivesend.invisibleink")
  }

  @Test("Screen effects return correct Apple IDs")
  func screenEffectIds() {
    #expect(
      MessageEffect.confetti.expressiveSendStyleId == "com.apple.messages.effect.CKConfettiEffect")
    #expect(
      MessageEffect.balloons.expressiveSendStyleId
        == "com.apple.messages.effect.CKHappyBirthdayEffect")
    #expect(
      MessageEffect.fireworks.expressiveSendStyleId
        == "com.apple.messages.effect.CKFireworksEffect")
    #expect(
      MessageEffect.heart.expressiveSendStyleId == "com.apple.messages.effect.CKHeartEffect")
    #expect(
      MessageEffect.lasers.expressiveSendStyleId == "com.apple.messages.effect.CKLasersEffect")
    #expect(MessageEffect.echo.expressiveSendStyleId == "com.apple.messages.effect.CKEchoEffect")
    #expect(
      MessageEffect.spotlight.expressiveSendStyleId
        == "com.apple.messages.effect.CKSpotlightEffect")
    #expect(
      MessageEffect.sparkles.expressiveSendStyleId
        == "com.apple.messages.effect.CKSparklesEffect")
    #expect(
      MessageEffect.shootingStar.expressiveSendStyleId
        == "com.apple.messages.effect.CKShootingStarEffect")
  }

  // MARK: - displayName

  @Test("displayName returns human-readable lowercase names")
  func displayNames() {
    #expect(MessageEffect.gentle.displayName == "gentle")
    #expect(MessageEffect.slam.displayName == "slam")
    #expect(MessageEffect.loud.displayName == "loud")
    #expect(MessageEffect.invisibleInk.displayName == "invisibleink")
    #expect(MessageEffect.confetti.displayName == "confetti")
    #expect(MessageEffect.balloons.displayName == "balloons")
    #expect(MessageEffect.fireworks.displayName == "fireworks")
    #expect(MessageEffect.heart.displayName == "heart")
    #expect(MessageEffect.lasers.displayName == "lasers")
    #expect(MessageEffect.echo.displayName == "echo")
    #expect(MessageEffect.spotlight.displayName == "spotlight")
    #expect(MessageEffect.sparkles.displayName == "sparkles")
    #expect(MessageEffect.shootingStar.displayName == "shootingstar")
  }

  // MARK: - CaseIterable

  @Test("All 13 effects are enumerated")
  func allCasesCount() {
    #expect(MessageEffect.allCases.count == 13)
  }

  // MARK: - Round-trip: displayName → from(string:)

  @Test("displayName round-trips through from(string:)")
  func roundTrip() {
    for effect in MessageEffect.allCases {
      let parsed = MessageEffect.from(string: effect.displayName)
      #expect(parsed == effect, "Round-trip failed for \(effect)")
    }
  }
}
