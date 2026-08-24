import Foundation
import Security

/// What a session needs from secure storage.
///
/// The seam exists so the session's own rules — validate before storing, and wipe on sign-out
/// only when the revoke actually settled the token's fate — are testable without a Keychain,
/// which behaves differently in a test runner than on a device and would make those tests about
/// entitlements instead.
public protocol CredentialStore: Sendable {
    func set(_ value: String, for account: String) throws
    func string(for account: String) throws -> String?
    func remove(_ account: String) throws
}

/// The device credential's only home.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the deliberate choice: the token must
/// survive a reboot for background work, must never leave this device, and must not be readable
/// while the device is locked from cold boot.
///
/// One instance addresses ONE namespace. `accessGroup` names the app group the app and its
/// extensions share (`DeviceCredentials.accessGroup`); `nil` is the default namespace a device
/// signed in before those entitlements existed still holds its token in. They are two instances
/// rather than one flag because setting `kSecAttrAccessGroup` without the matching Keychain
/// Sharing entitlement fails EVERY call with `errSecMissingEntitlement` — a fallback has to be
/// able to ask the other namespace, not the same one differently.
public struct Keychain: CredentialStore, Sendable {
    public enum Failure: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case dataNotUTF8
    }

    public let service: String
    public let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func set(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else { throw Failure.dataNotUTF8 }
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw Failure.unexpectedStatus(updateStatus) }

        var insert = query
        insert.merge(attributes) { current, _ in current }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure.unexpectedStatus(addStatus) }
    }

    public func string(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.unexpectedStatus(status) }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removing a credential that was never there is success, not an error: sign-out must leave
    /// nothing behind whatever state it started from.
    public func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.unexpectedStatus(status)
        }
    }
}
