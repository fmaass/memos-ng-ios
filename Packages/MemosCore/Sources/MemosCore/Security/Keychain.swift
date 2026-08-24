import Foundation
import Security
import Synchronization

/// ONE keychain access group, addressed BY NAME.
///
/// An instance addresses one namespace and always names it: every query this type builds carries
/// `kSecAttrAccessGroup`, so no operation on one namespace can match an item in another. That is
/// what makes the namespaces disjoint rather than merely ordered — they were only ordered once,
/// and a delete crossed between them and took the device's only credential with it.
///
/// Synchronous on purpose. The state machine above this — `CredentialVault` — is an actor, and an
/// `await` inside an actor is a suspension point another task can enter through. A namespace call
/// that suspended would reopen the very interleaving that actor exists to close, so these calls
/// never suspend: they are `SecItem*` calls, microseconds long, and they run to completion inside
/// the vault's isolation.
public protocol KeychainNamespaceStore: Sendable {
    func set(_ value: String, for account: String) throws
    func string(for account: String) throws -> String?
    func remove(_ account: String) throws
    /// Stores the value only if this namespace holds nothing for the account, and says which
    /// happened. `false` means something was already there and was left alone.
    ///
    /// It exists because "fill it only if it is empty" written as a read and then a write is two
    /// operations with a gap in the middle. The keychain settles it in one call — `SecItemAdd`
    /// refuses a duplicate — so a migration can never overwrite a credential newer than the one
    /// it is carrying, whatever else is happening on the device.
    func add(_ value: String, for account: String) throws -> Bool
}

/// A storage failure no status code reported.
public enum CredentialStoreError: Error, Equatable {
    /// The namespace accepted the write and then could not return the value. It is its own case
    /// because it is not a keychain ERROR — every call answered success — and the only way to see
    /// it is to look.
    case notReadableBack(account: String)
    /// No namespace could be named, so nothing was read, written or deleted. Naming none is not
    /// an alternative: a query with no access group reaches into every group the app can see,
    /// which is how a delete meant for one namespace emptied the other.
    case namespaceUnavailable
    /// The token's home is not the group the entitlement names, so no new credential is stored.
    /// Reading and clearing still work — a device already holding a token keeps working — but an
    /// entitlement that did not arrive is a change of security policy, and quietly writing the
    /// token somewhere weaker is how such a change goes unnoticed.
    case storageDegraded
}

/// The access group an unqualified keychain add lands in under THIS build's entitlements.
///
/// It is not "the team-prefixed bundle group" as a matter of definition. Apple's rule is that the
/// default is the FIRST group of the effective access-group list: the first entry of
/// `keychain-access-groups` when the build has that entitlement, and the application identifier
/// when it does not. Adding, removing or reordering that entitlement changes what this reports.
/// That is exactly why it is PROBED rather than assembled, and why what it reports is treated as
/// evidence about the current build — `DeviceCredentials.plan(default:)` reads the answer to work
/// out which of this app's three namespaces the token is entitled to live in.
enum KeychainAccessGroup {
    /// A service nothing else uses, so a probe item can never collide with a credential.
    static let probeService = "live.discomarder.memosng.access-group-probe"

    /// What one probe found.
    enum Probe: Equatable, Sendable {
        case resolved(String)
        /// The keychain refused, and this is the status it refused with. The ordinary one is
        /// `errSecInteractionNotAllowed`: an item protected by `AfterFirstUnlock` is unreachable
        /// between a reboot and the first unlock, and a background launch happens in that window.
        /// It says nothing about entitlements and everything about the moment, which is why
        /// nothing remembers it.
        case unavailable(OSStatus)
        /// The add succeeded and reported no access group at all. There is nothing to name.
        case unnamed
    }

    private static let resolver = AccessGroupResolver(probe: { KeychainAccessGroup.probe() })

    /// The resolved group, or `nil` while it cannot be resolved. Only a SUCCESS is remembered.
    static var appDefault: String? { resolver.resolved() }

    /// Adds one throwaway item under a service nothing else uses, reads its access group back and
    /// deletes it again BY that group.
    ///
    /// This is the only keychain call in the app that names no access group, and it is an ADD of
    /// an item that cannot collide with a credential: the one operation that can neither read nor
    /// delete one. Everything else — every read, every write, every delete, in all three
    /// namespaces — names its group explicitly.
    static func probe() -> Probe {
        let account = UUID().uuidString
        let insert: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemAdd(insert as CFDictionary, &item)
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let attributes = item as? [String: Any],
            let group = attributes[kSecAttrAccessGroup as String] as? String,
            !group.isEmpty
        else {
            // The item is left where it is. Deleting it would take a query naming no access
            // group, and a zero-byte item under a service nothing reads is the cheaper of those
            // two prices by a wide margin. Said out loud because every repeat probe leaves
            // another one, and a keychain that reports no group for its own add is a fault
            // nobody should have to infer from a namespace quietly not resolving.
            MemosLog.session.error("the keychain reported no access group for an add of its own")
            return .unnamed
        }
        // Deleted by the group it reported, so even the cleanup names one.
        SecItemDelete(
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: group,
                kSecAttrSynchronizable as String: false,
            ] as CFDictionary)
        return .resolved(group)
    }
}

/// Probes until one probe succeeds, and then stops.
///
/// Only a success is remembered. A failed probe is a fact about this moment, not about this
/// build: `AfterFirstUnlockThisDeviceOnly` items are documented as unreachable between a reboot
/// and the first unlock, and a background launch can land there. Remembering that failure for the
/// life of the process is how a woken app would carry an inert credential store until somebody
/// force-quit it — so the next caller probes again.
final class AccessGroupResolver: Sendable {
    private let probe: @Sendable () -> KeychainAccessGroup.Probe
    private let cached = Mutex<String?>(nil)

    init(probe: @escaping @Sendable () -> KeychainAccessGroup.Probe) {
        self.probe = probe
    }

    func resolved() -> String? {
        if let group = cached.withLock({ $0 }) { return group }
        guard case .resolved(let group) = probe(), !group.isEmpty else { return nil }
        cached.withLock { $0 = group }
        return group
    }
}

/// The device credential's home, one namespace of it.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the deliberate choice: the token must
/// survive a reboot for background work, must never leave this device, and must not be readable
/// while the device is locked from cold boot. `kSecAttrSynchronizable: false` is stated rather
/// than defaulted, because "this token is not in anybody's iCloud keychain" is a security
/// property and a security property that depends on an API default is one nobody can see.
struct Keychain: KeychainNamespaceStore, Sendable {
    enum Failure: Error, Equatable {
        case unexpectedStatus(OSStatus)
        /// `errSecMissingEntitlement`: this build cannot reach data it owns. Its own case because
        /// it is the status that must never be read as "nothing here" — a namespace answering it
        /// may be holding the credential, and the app has merely lost the right to look.
        case notEntitled
        case dataNotUTF8
        /// The keychain returned an item that is not data. Like `dataNotUTF8` this is CORRUPTION,
        /// and corruption is not absence: answering `nil` here would tell a session nobody is
        /// signed in on the evidence that something unreadable is stored.
        case itemNotData
    }

    let service: String
    let accessGroup: String

    init(service: String, accessGroup: String) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// The one place a status becomes an error, so `errSecMissingEntitlement` cannot be reported
    /// as an ordinary failure by one call site and as a distinct one by another.
    private static func failure(_ status: OSStatus) -> Failure {
        status == errSecMissingEntitlement ? .notEntitled : .unexpectedStatus(status)
    }

    /// Every query starts here, which is what makes "the access group is always named" a property
    /// of the type rather than of each call site.
    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func attributes(for value: String) throws -> [String: Any] {
        guard let data = value.data(using: .utf8) else { throw Failure.dataNotUTF8 }
        return [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    func set(_ value: String, for account: String) throws {
        let query = baseQuery(account: account)
        let attributes = try attributes(for: value)

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw Self.failure(updateStatus) }

        var insert = query
        insert.merge(attributes) { current, _ in current }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw Self.failure(addStatus) }
    }

    func add(_ value: String, for account: String) throws -> Bool {
        var insert = baseQuery(account: account)
        insert.merge(try attributes(for: value)) { current, _ in current }
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw Self.failure(status) }
        return true
    }

    /// `nil` means the namespace holds nothing for this account, and NOTHING else. Every other
    /// answer — a status, an item of the wrong type, bytes that are not UTF-8 — is thrown, so a
    /// caller can tell "there is no credential" from "there is one and it will not come back".
    func string(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.failure(status) }
        guard let data = item as? Data else { throw Failure.itemNotData }
        guard let value = String(data: data, encoding: .utf8) else { throw Failure.dataNotUTF8 }
        return value
    }

    /// Removing a credential that was never there is success, not an error: sign-out must leave
    /// nothing behind whatever state it started from.
    func remove(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.failure(status)
        }
    }
}
