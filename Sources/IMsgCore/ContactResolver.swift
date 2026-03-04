import Contacts
import Foundation

public protocol ContactResolving: Sendable {
  func resolve(handle: String) -> String?
}

public final class ContactResolver: ContactResolving, @unchecked Sendable {
  private var store: CNContactStore?
  private let queue = DispatchQueue(label: "imsg.contact.resolver")
  private var cache: [String: String?] = [:]
  private var checkedAccess = false
  private var accessGranted = false

  public init() {}

  public func resolve(handle: String) -> String? {
    return queue.sync {
      if !checkedAccess {
        checkedAccess = true
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized {
          accessGranted = true
          store = CNContactStore()
        }
      }
      guard accessGranted else { return nil }
      if let cached = cache[handle] {
        return cached
      }
      let name = lookupName(for: handle)
      cache[handle] = name
      return name
    }
  }

  private func lookupName(for handle: String) -> String? {
    let keysToFetch: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactNicknameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor,
      CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    // Try phone number lookup
    if looksLikePhoneNumber(handle) {
      let phoneNumber = CNPhoneNumber(stringValue: handle)
      let predicate = CNContact.predicateForContacts(matching: phoneNumber)
      if let contact = fetchFirst(predicate: predicate, keys: keysToFetch) {
        return displayName(for: contact)
      }
    }

    // Try email lookup
    if handle.contains("@") {
      let predicate = CNContact.predicateForContacts(matchingEmailAddress: handle)
      if let contact = fetchFirst(predicate: predicate, keys: keysToFetch) {
        return displayName(for: contact)
      }
    }

    return nil
  }

  private func fetchFirst(predicate: NSPredicate, keys: [CNKeyDescriptor]) -> CNContact? {
    do {
      let contacts = try store?.unifiedContacts(matching: predicate, keysToFetch: keys)
      return contacts?.first
    } catch {
      return nil
    }
  }

  private func displayName(for contact: CNContact) -> String? {
    if !contact.nickname.isEmpty {
      return contact.nickname
    }
    let given = contact.givenName
    let family = contact.familyName
    if given.isEmpty && family.isEmpty {
      return nil
    }
    if family.isEmpty { return given }
    if given.isEmpty { return family }
    return "\(given) \(family)"
  }

  private func looksLikePhoneNumber(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return false }
    if trimmed.hasPrefix("+") { return true }
    let digits = trimmed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
    return digits.count >= 7
  }
}
