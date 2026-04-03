import Commander
import Foundation
import IMsgCore

enum LocationCommand {
  static let spec = CommandSpec(
    name: "location",
    abstract: "Get shared locations from FindMy friends",
    discussion: """
      Retrieve the current location of friends who are sharing their location
      with you via FindMy. Requires the IMCore bridge (Messages.app with
      injected dylib) since FindMy entitlements are needed.

      Optionally filter by a specific handle (phone number or email).
      Use --raw with --json to include a private-api debug dump of the
      underlying location and placemark objects.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: [
          .make(
            label: "handle", names: [.long("handle")],
            help: "Filter by phone number or email (substring match)")
        ],
        flags: [
          .make(
            label: "raw", names: [.long("raw")],
            help: "Include raw location/address object fields for debugging")
        ]
      )
    ),
    usageExamples: [
      "imsg-plus location",
      "imsg-plus location --handle +14155551234",
      "imsg-plus location --handle john@example.com",
      "imsg-plus location --json",
      "imsg-plus location --json --raw",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }

  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let bridge = IMCoreBridge.shared
    let availability = bridge.checkAvailability()

    if !availability.available {
      print("Location requires advanced features (IMCore bridge).")
      print("Run: imsg-plus launch")
      return
    }

    let handle = values.option("handle")
    let raw = values.flags.contains("raw")

    do {
      if runtime.jsonOutput {
        if raw {
          let rawLocations = try await bridge.getLocationsResponse(
            handle: handle, includeDebugRaw: true)
          for location in rawLocations {
            print(JSONSerialization.string(from: location))
          }
        } else {
          let locations = try await bridge.getLocations(handle: handle)
          for loc in locations {
            let payload = LocationPayload(location: loc)
            try JSONLines.print(payload)
          }
        }
      } else {
        let locations = try await bridge.getLocations(handle: handle)

        if locations.isEmpty {
          print("No friends are currently sharing their location with you.")
          return
        }

        for loc in locations {
          printLocation(loc)
          if raw {
            print("  Raw: use --json --raw for the full object dump")
          }
          print()
        }
      }
    } catch let error as IMCoreBridgeError {
      if runtime.jsonOutput {
        let output: [String: Any] = [
          "success": false,
          "error": error.description,
        ]
        print(JSONSerialization.string(from: output))
      } else {
        print("Error: \(error)")
      }
      throw error
    }
  }

  private static func printLocation(_ loc: FriendLocation) {
    var header = loc.handle
    if let first = loc.firstName {
      let name = [first, loc.lastName].compactMap { $0 }.joined(separator: " ")
      header = "\(name) (\(loc.handle))"
    }
    print(header)

    if let label = loc.label {
      print("  Label: \(label)")
    }
    if let labels = loc.labels, !labels.isEmpty {
      print("  Labels: \(labels.joined(separator: ", "))")
    }

    if let lat = loc.latitude, let lng = loc.longitude {
      print("  Coordinates: \(lat), \(lng)")
    } else {
      print("  Coordinates: unavailable")
    }

    if let address = loc.address {
      print("  Address: \(address)")
    } else {
      var parts: [String] = []
      if let street = loc.street { parts.append(street) }
      if let locality = loc.locality { parts.append(locality) }
      if let state = loc.state { parts.append(state) }
      if let country = loc.country { parts.append(country) }
      if !parts.isEmpty {
        print("  Address: \(parts.joined(separator: ", "))")
      }
    }
    if let formattedAddressLines = loc.formattedAddressLines, !formattedAddressLines.isEmpty {
      print("  Address Lines: \(formattedAddressLines.joined(separator: " | "))")
    }

    if let alt = loc.altitude {
      print("  Altitude: \(String(format: "%.1f", alt))m")
    }
    if let acc = loc.horizontalAccuracy {
      print("  Accuracy: \(String(format: "%.0f", acc))m")
    }
    if let ts = loc.timestamp {
      print("  Updated: \(ts)")
    }

    var flags: [String] = []
    if loc.isOld { flags.append("stale") }
    if loc.isInaccurate { flags.append("inaccurate") }
    if !flags.isEmpty {
      print("  Status: \(flags.joined(separator: ", "))")
    }
  }
}
