import Foundation
import Testing

@testable import IMsgCore

@Suite("FriendLocation Tests")
struct FriendLocationTests {

  @Test("Init from dictionary with full data")
  func initFromFullDict() {
    let dict: [String: Any] = [
      "handle": "+14155551234",
      "latitude": 37.7749,
      "longitude": -122.4194,
      "altitude": 15.0,
      "horizontal_accuracy": 10.0,
      "vertical_accuracy": 5.0,
      "timestamp": "2026-04-03T12:00:00Z",
      "address": "1 Apple Park Way, Cupertino, CA",
      "formatted_address_lines": ["1 Apple Park Way", "Cupertino, CA"],
      "locality": "Cupertino",
      "state": "CA",
      "country": "United States",
      "street": "1 Apple Park Way",
      "label": "Work",
      "labels": ["_$!<work>!$_"],
      "is_old": false,
      "is_inaccurate": false,
    ]

    let loc = FriendLocation(from: dict)
    #expect(loc.handle == "+14155551234")
    #expect(loc.latitude == 37.7749)
    #expect(loc.longitude == -122.4194)
    #expect(loc.altitude == 15.0)
    #expect(loc.horizontalAccuracy == 10.0)
    #expect(loc.verticalAccuracy == 5.0)
    #expect(loc.timestamp == "2026-04-03T12:00:00Z")
    #expect(loc.address == "1 Apple Park Way, Cupertino, CA")
    #expect(loc.formattedAddressLines == ["1 Apple Park Way", "Cupertino, CA"])
    #expect(loc.locality == "Cupertino")
    #expect(loc.state == "CA")
    #expect(loc.country == "United States")
    #expect(loc.street == "1 Apple Park Way")
    #expect(loc.label == "Work")
    #expect(loc.labels == ["Work"])
    #expect(loc.isOld == false)
    #expect(loc.isInaccurate == false)
    #expect(loc.hasCoordinates == true)
  }

  @Test("Init from dictionary with missing location")
  func initFromPartialDict() {
    let dict: [String: Any] = [
      "handle": "john@example.com"
    ]

    let loc = FriendLocation(from: dict)
    #expect(loc.handle == "john@example.com")
    #expect(loc.latitude == nil)
    #expect(loc.longitude == nil)
    #expect(loc.address == nil)
    #expect(loc.hasCoordinates == false)
    #expect(loc.isOld == false)
    #expect(loc.isInaccurate == false)
  }

  @Test("Init from dictionary with stale/inaccurate flags")
  func initWithFlags() {
    let dict: [String: Any] = [
      "handle": "+1234",
      "latitude": 0.0,
      "longitude": 0.0,
      "is_old": true,
      "is_inaccurate": true,
    ]

    let loc = FriendLocation(from: dict)
    #expect(loc.isOld == true)
    #expect(loc.isInaccurate == true)
    #expect(loc.hasCoordinates == true)
  }

  @Test("Direct initializer")
  func directInit() {
    let loc = FriendLocation(
      handle: "+14155551234",
      latitude: 37.7749,
      longitude: -122.4194,
      address: "Cupertino",
      formattedAddressLines: ["1 Infinite Loop", "Cupertino, CA"],
      labels: ["_$!<home>!$_"]
    )
    #expect(loc.handle == "+14155551234")
    #expect(loc.hasCoordinates == true)
    #expect(loc.altitude == nil)
    #expect(loc.address == "Cupertino")
    #expect(loc.formattedAddressLines == ["1 Infinite Loop", "Cupertino, CA"])
    #expect(loc.labels == ["Home"])
  }

  @Test("Label tokens are normalized")
  func labelTokensNormalized() {
    let dict: [String: Any] = [
      "handle": "+1234",
      "label": "_$!<work>!$_",
      "labels": ["_$!<home>!$_", "_$!<favorite_coffee_shop>!$_", "_$!<home>!$_"],
    ]

    let loc = FriendLocation(from: dict)
    #expect(loc.label == "Work")
    #expect(loc.labels == ["Home", "Favorite Coffee Shop"])
  }

  @Test("Empty dictionary defaults")
  func emptyDict() {
    let loc = FriendLocation(from: [:])
    #expect(loc.handle == "")
    #expect(loc.hasCoordinates == false)
  }
}
