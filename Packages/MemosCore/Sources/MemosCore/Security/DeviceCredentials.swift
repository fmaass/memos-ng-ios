import Foundation

/// Where the device credential lives, and how it got there from where it used to live.
///
/// The credential moved into the app group's keychain namespace when the entitlements arrived, so
/// that the app and its extensions can read one token instead of each holding their own. A device
/// that was signed in BEFORE that move still has its token in the default namespace, and a person
/// who is already signed in must not be signed out by an app update — hence the migrating store
/// below rather than a straight switch.
public enum DeviceCredentials {
    /// The keychain service both namespaces use. Unchanged by the move: only the access group is
    /// new, and changing both at once would make the old items unfindable.
    public static let service = "live.discomarder.memosng"

    /// The app group, which doubles as the keychain access group. An app group identifier is used
    /// verbatim — unlike a bare access group, it takes no team-id prefix, which is what lets this
    /// repository carry the entitlement without carrying a team id.
    public static let accessGroup = "group.live.discomarder.memosng"

    /// The store the app signs in through: the shared namespace, with the pre-entitlement one
    /// behind it for as long as a device might still be carrying a token there.
    public static func keychain() -> any CredentialStore {
        MigratingCredentialStore(
            primary: Keychain(service: service, accessGroup: accessGroup),
            legacy: Keychain(service: service, accessGroup: nil)
        )
    }
}

/// Two credential namespaces, read newest-first, with whatever is found in the old one moved into
/// the new one on the way past.
///
/// The migration happens on READ rather than at launch on purpose: a launch-time sweep would have
/// to run before anything else could touch the keychain, and it would run on every launch forever.
/// This one costs a second lookup exactly until the first read finds nothing left to move.
///
/// Two rules hold it together, and both exist because of one shipped defect: the token was written
/// to the shared namespace and instantly deleted again by the very call meant to clear the OLD one.
/// A `SecItemDelete` whose query names no access group matches items in EVERY group the app can
/// reach, so "drop the legacy copy" dropped the copy just made. Hence: an ungrouped delete NEVER
/// runs after a write, and no write counts until the value reads back.
public struct MigratingCredentialStore: CredentialStore {
    private let primary: any CredentialStore
    private let legacy: any CredentialStore

    public init(primary: any CredentialStore, legacy: any CredentialStore) {
        self.primary = primary
        self.legacy = legacy
    }

    /// New credentials go to the shared namespace, and the old copy is dropped once they are
    /// PROVABLY there: a token left behind is a second credential nobody is tracking, and a token
    /// dropped in favour of one that cannot be read back is no credential at all.
    ///
    /// The read-back is the whole of this method. `SecItemAdd` answers `errSecSuccess` for an item
    /// that the very next `SecItemCopyMatching` cannot find when the access group it names is not
    /// one the build is entitled to — so a store that believed the status code reported a
    /// credential as saved while the keychain held nothing readable. The session did not notice,
    /// because it keeps its client in memory; the OUTBOX did, because it reads the token back from
    /// the keychain on every drain, and it refused every capture from then on.
    public func set(_ value: String, for account: String) throws {
        // The old copy goes FIRST, and that order is the whole fix. The legacy namespace is
        // addressed with NO access group, and a keychain delete that names no group matches every
        // group the app can reach — so clearing it after the new write deleted the new write.
        try? legacy.remove(account)
        if (try? Self.write(value, for: account, to: primary)) != nil {
            return
        }
        // The shared namespace would not hold it. The app's own namespace is the fallback rather
        // than the failure: a credential only this app can read is worth strictly more than none,
        // and it is where a device signed in before the entitlements existed keeps its token
        // anyway. If neither namespace holds it, THAT is worth throwing — the sign-in says so.
        try? primary.remove(account)
        try Self.write(value, for: account, to: legacy)
    }

    public func string(for account: String) throws -> String? {
        if let value = try primary.string(for: account) { return value }
        guard let migrated = try legacy.string(for: account) else { return nil }
        // The value is in hand, so the old copy can go first — and it MUST, for the reason `set`
        // gives: an ungrouped delete would take the migrated copy with it. If the shared namespace
        // then refuses to hold it, it goes straight back where it was; nothing is lost either way,
        // because the token being moved is the one already in this variable.
        try? legacy.remove(account)
        if (try? Self.write(migrated, for: account, to: primary)) == nil {
            try? Self.write(migrated, for: account, to: legacy)
        }
        return migrated
    }

    /// Writes and reads back. A namespace that accepts a value and then cannot return it has not
    /// stored it, whatever it said at the time.
    private static func write(
        _ value: String,
        for account: String,
        to store: any CredentialStore
    ) throws {
        try store.set(value, for: account)
        guard try store.string(for: account) == value else {
            throw CredentialStoreError.notReadableBack(account: account)
        }
    }

    /// Sign-out clears BOTH namespaces, whatever happens in either: the whole point of a wipe is
    /// that nothing is left, so a failure in one half must not skip the other.
    public func remove(_ account: String) throws {
        var failure: (any Error)?
        do { try primary.remove(account) } catch { failure = error }
        do { try legacy.remove(account) } catch { failure = failure ?? error }
        if let failure { throw failure }
    }
}
