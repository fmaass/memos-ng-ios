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
public struct MigratingCredentialStore: CredentialStore {
    private let primary: any CredentialStore
    private let legacy: any CredentialStore

    public init(primary: any CredentialStore, legacy: any CredentialStore) {
        self.primary = primary
        self.legacy = legacy
    }

    /// New credentials are written to the shared namespace only, and the old copy is dropped: a
    /// token left behind there is a second credential nobody is tracking.
    public func set(_ value: String, for account: String) throws {
        try primary.set(value, for: account)
        try? legacy.remove(account)
    }

    public func string(for account: String) throws -> String? {
        if let value = try primary.string(for: account) { return value }
        guard let migrated = try legacy.string(for: account) else { return nil }
        // The old copy is only dropped once the new namespace has accepted the value. If the
        // write fails — a missing entitlement is the realistic reason — the session still starts
        // from the value we found, because signing someone out over a storage detail is worse
        // than migrating again next launch.
        if (try? primary.set(migrated, for: account)) != nil {
            try? legacy.remove(account)
        }
        return migrated
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
