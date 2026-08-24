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
    ///
    /// The legacy namespace is addressed by NAME (`KeychainAccessGroup.appDefault`), never by
    /// omission. When that name cannot be resolved — or turns out to be the shared group, so there
    /// is no second namespace at all — the shared store is the whole story and there is nothing to
    /// migrate. An unnameable namespace is left alone; it is never addressed with a query that
    /// names no group, because such a query reaches into every group the app can see.
    public static func keychain() -> any CredentialStore {
        let shared = Keychain(service: service, accessGroup: accessGroup)
        guard let appDefault = KeychainAccessGroup.appDefault, appDefault != accessGroup else {
            return shared
        }
        return MigratingCredentialStore(
            primary: shared,
            legacy: Keychain(service: service, accessGroup: appDefault)
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
/// Three rules hold it together, and all three exist because of one shipped defect: the token was
/// written to the shared namespace and instantly deleted again by the very call meant to clear the
/// OLD one, leaving the device with no stored credential at all. The session did not notice —
/// it keeps its client in memory — but the outbox reads the keychain on every drain, so from that
/// moment it refused every capture and never even sent its reachability probe.
///
/// 1. The two namespaces are DISJOINT by construction. Both are `Keychain` instances with a named
///    access group, so no operation on one can match an item in the other. That is what makes the
///    rest of this safe rather than merely lucky.
/// 2. Because they are disjoint, the ordering is the SAFE one: write the new value, prove it reads
///    back, and only then clear the old namespace. A crash in between leaves BOTH copies — which
///    the next read tidies up — and never neither, so there is no window in which the device is
///    signed in with nothing stored.
/// 3. The migration FILLS the shared namespace, it never overwrites it. `add` refuses a duplicate
///    in one call, so a sign-in racing a migration cannot have its fresh token replaced by the
///    stale one the migration is carrying.
public struct MigratingCredentialStore: CredentialStore {
    private let primary: any CredentialStore
    private let legacy: any CredentialStore

    public init(primary: any CredentialStore, legacy: any CredentialStore) {
        self.primary = primary
        self.legacy = legacy
    }

    /// A new credential goes to the shared namespace, and the old copy is dropped once the new one
    /// has PROVED it is there.
    ///
    /// The read-back is not defensiveness. `SecItemAdd` answers `errSecSuccess` for an item that
    /// the very next `SecItemCopyMatching` cannot find when the access group it names is not one
    /// the build is entitled to — so a store that believed the status code would report a
    /// credential as saved while the keychain held nothing readable.
    public func set(_ value: String, for account: String) throws {
        if (try? Self.write(value, for: account, to: primary)) != nil {
            // Scoped to the legacy group, so it cannot reach what was just written.
            try? legacy.remove(account)
            return
        }
        // The shared namespace would not hold it. The app's own namespace is the fallback rather
        // than the failure: a credential only this app can read is worth strictly more than none,
        // and it is where a device signed in before the entitlements existed keeps its token
        // anyway. If neither namespace holds it, THAT is worth throwing — the sign-in says so.
        try? primary.remove(account)
        try Self.write(value, for: account, to: legacy)
    }

    /// Adding is offered on the shared namespace alone. A migration is the only caller, and it has
    /// no business filling the namespace it is migrating out of.
    public func add(_ value: String, for account: String) throws -> Bool {
        try primary.add(value, for: account)
    }

    public func string(for account: String) throws -> String? {
        if let value = try primary.string(for: account) {
            // The leftover a crash between `set`'s write and its delete leaves behind. Dropping it
            // HERE rather than insisting on it at write time is what lets the write happen first:
            // the cost of the crash is a stale copy that the next read removes, not a device with
            // no credential and a forced sign-in.
            try? legacy.remove(account)
            return value
        }
        guard let migrated = try legacy.string(for: account) else { return nil }
        // Between the read above and this line another thread may have signed in, and the value in
        // hand is by definition the older of the two. `add` settles that in ONE keychain call: it
        // fills an empty namespace and refuses a full one.
        let filled = (try? primary.add(migrated, for: account)) ?? false
        if filled, (try? primary.string(for: account)) == migrated {
            try? legacy.remove(account)
            return migrated
        }
        // Either something newer got there first — in which case the newer value wins and the
        // stale copy goes — or the shared namespace would not hold it, in which case the only copy
        // stays exactly where it is.
        if let newer = (try? primary.string(for: account)) ?? nil {
            try? legacy.remove(account)
            return newer
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
