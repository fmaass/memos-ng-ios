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
    /// Stores the value only if this namespace holds nothing for the account, and says which
    /// happened. `false` means something was already there and was left alone.
    ///
    /// It exists because "fill it only if it is empty" written as a read and then a write is two
    /// operations with a gap in the middle, and a sign-in on another thread fits through that gap.
    /// The keychain settles it in one call — `SecItemAdd` refuses a duplicate — so the migration
    /// can never overwrite a credential newer than the one it is carrying.
    func add(_ value: String, for account: String) throws -> Bool
}

/// A storage failure no status code reported.
public enum CredentialStoreError: Error, Equatable {
    /// The namespace accepted the write and then could not return the value. It is its own case
    /// because it is not a keychain ERROR — every call answered success — and the only way to see
    /// it is to look.
    case notReadableBack(account: String)
    /// The namespace this store addresses could not be named, so it does nothing at all. Naming
    /// none is not an alternative: a query with no access group reaches into every group the app
    /// can see, which is how a delete meant for one namespace emptied the other.
    case namespaceUnavailable
}

/// The access group this app's keychain items land in when a query names none.
///
/// It is `<team id>.<bundle id>`, and this repository deliberately carries no team id — so it is
/// ASKED FOR rather than assembled. One throwaway item is added under a service nothing else uses,
/// its `kSecAttrAccessGroup` is read back, and it is deleted again BY that group.
///
/// This probe is the only keychain call in the app that names no access group, and it is an ADD of
/// an item that cannot collide with a credential: the one operation that can neither read nor
/// delete one. Everything else — every read, every write, every delete, in both namespaces — names
/// its group explicitly, which is what makes the two namespaces disjoint rather than merely
/// ordered. (They were only ordered once, and a delete crossed between them and took the device's
/// only credential with it.)
public enum KeychainAccessGroup {
    /// Resolved once per process. `nil` means the probe failed, and a namespace that cannot be
    /// named is inert rather than addressed without one.
    public static let appDefault: String? = resolve()

    public static let probeService = "live.discomarder.memosng.access-group-probe"

    private static func resolve() -> String? {
        let account = UUID().uuidString
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecReturnAttributes as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemAdd(insert as CFDictionary, &item) == errSecSuccess,
            let attributes = item as? [String: Any],
            let group = attributes[kSecAttrAccessGroup as String] as? String,
            !group.isEmpty
        else { return nil }
        // Deleted by the group it reported, so even the cleanup names one.
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: group,
            ] as CFDictionary)
        return group
    }
}

/// The device credential's only home.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the deliberate choice: the token must
/// survive a reboot for background work, must never leave this device, and must not be readable
/// while the device is locked from cold boot.
///
/// One instance addresses ONE namespace, and it is ALWAYS named. `accessGroup` is not optional:
/// the shared namespace is the app group the app and its extensions share
/// (`DeviceCredentials.accessGroup`) and the legacy one is `KeychainAccessGroup.appDefault`, where
/// a device signed in before those entitlements existed still holds its token. Both are strings,
/// so every query this type builds carries `kSecAttrAccessGroup` and no operation on one namespace
/// can match an item in the other.
public struct Keychain: CredentialStore, Sendable {
    public enum Failure: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case dataNotUTF8
    }

    public let service: String
    public let accessGroup: String

    public init(service: String, accessGroup: String) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// Every query starts here, which is what makes "the access group is always named" a property
    /// of the type rather than of each call site.
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    private func attributes(for value: String) throws -> [String: Any] {
        guard let data = value.data(using: .utf8) else { throw Failure.dataNotUTF8 }
        return [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    public func set(_ value: String, for account: String) throws {
        let query = baseQuery(account: account)
        let attributes = try attributes(for: value)

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw Failure.unexpectedStatus(updateStatus) }

        var insert = query
        insert.merge(attributes) { current, _ in current }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Failure.unexpectedStatus(addStatus) }
    }

    public func add(_ value: String, for account: String) throws -> Bool {
        var insert = baseQuery(account: account)
        insert.merge(try attributes(for: value)) { current, _ in current }
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw Failure.unexpectedStatus(status) }
        return true
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

/// A namespace that could not be named, and therefore does nothing.
///
/// It stands in for the legacy store when `KeychainAccessGroup.appDefault` will not resolve. The
/// alternative — addressing it with no access group — is the defect this whole file exists to
/// close, so the safe answer is a store that reads nothing, deletes nothing and refuses writes.
public struct InertCredentialStore: CredentialStore {
    public init() {}

    public func set(_ value: String, for account: String) throws {
        throw CredentialStoreError.namespaceUnavailable
    }
    public func add(_ value: String, for account: String) throws -> Bool {
        throw CredentialStoreError.namespaceUnavailable
    }
    public func string(for account: String) throws -> String? { nil }
    public func remove(_ account: String) throws {}
}
