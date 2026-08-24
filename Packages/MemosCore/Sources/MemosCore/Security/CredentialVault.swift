import Foundation

/// What a session needs from secure storage.
///
/// The seam exists so the session's own rules — validate before storing, and wipe on sign-out
/// only when the revoke actually settled the token's fate — are testable without a Keychain,
/// which behaves differently in a test runner than on a device and would make those tests about
/// entitlements instead.
///
/// Asynchronous because the only production implementation is an actor. Every operation on the
/// device credential — a sign-in's write, a sign-out's wipe, a migration lap, the outbox's read —
/// is serialized against every other one. That is not tidiness: a migration that read the old
/// namespace while a sign-out emptied every namespace would then write the value it was still
/// carrying back into the one the sign-out had just cleared, and the device would be holding a
/// credential nobody is signed in with.
public protocol CredentialStore: Sendable {
    func set(_ value: String, for account: String) async throws
    func string(for account: String) async throws -> String?
    func remove(_ account: String) async throws
}

/// Who, besides this app, can read what a namespace holds.
public enum CredentialReach: Equatable, Sendable {
    /// An access group named by this app's own entitlements and by nothing else's.
    case appOnly
    /// An app group. On iOS an app group identifier IS a keychain access group, so every
    /// extension entitled to that group's container can also read the group's keychain items —
    /// the share extension included, which needs the container for the outbox files and the
    /// identity JSON and must never have the token. The device token is not written here.
    case sharedWithExtensions
}

/// One namespace, and what reaching it means.
public struct CredentialNamespace: Sendable {
    public let store: any KeychainNamespaceStore
    public let reach: CredentialReach

    public init(_ store: any KeychainNamespaceStore, reach: CredentialReach) {
        self.store = store
        self.reach = reach
    }
}

/// Where the credential lives, and which namespaces are still being emptied into it.
///
/// The legacies are ordered NEWEST HOME FIRST, because that is the order a read walks them in and
/// the first value found is the one answered with.
public struct CredentialNamespaces: Sendable {
    public let primary: CredentialNamespace
    public let legacies: [CredentialNamespace]

    public init(primary: CredentialNamespace, legacies: [CredentialNamespace]) {
        // Composition is code, not input: a build that put the token where an extension can read
        // it is a defect to find at the first test that runs, not a condition to handle.
        precondition(
            primary.reach == .appOnly,
            "the device token's home must be a namespace no extension can read"
        )
        self.primary = primary
        self.legacies = legacies
    }
}

/// The device credential's state machine, and the only thing allowed to run it.
///
/// An ACTOR, because the operations are multi-step and their steps must not interleave. Three
/// separate incidents live in that sentence:
///
/// 1. A migration lap racing a sign-out. The lap reads the old namespace, the sign-out empties
///    every namespace, and the lap writes what it is carrying into the namespace the sign-out has
///    just cleared. The person is looking at a sign-in screen and the device is holding a token.
/// 2. A writer deleting what it does not own. "I could not prove my write" is not "whatever is in
///    there is mine and may be deleted" — that reading is how a live credential vanished from a
///    signed-in device, and there is no delete on a failed write anywhere in here now.
/// 3. Two vaults. Serialization is a property of the OBJECT, so a second vault over the same
///    keychain would serialize nothing. There is one per process (`DeviceCredentials.shared`) and
///    the session's wipe and the outbox's read are two calls on it.
///
/// Every namespace call inside the isolation is SYNCHRONOUS, which is the other half of the
/// guarantee: an `await` in here would be a suspension point another task could enter through,
/// and actor reentrancy would hand back exactly the interleaving this type exists to prevent.
public actor CredentialVault: CredentialStore {
    private let resolve: @Sendable () -> CredentialNamespaces?
    /// Resolved on first use and remembered only on SUCCESS — the namespaces are named from a
    /// keychain probe, and a probe can fail for reasons that pass (see `AccessGroupResolver`).
    private var namespaces: CredentialNamespaces?

    public init(resolving resolve: @escaping @Sendable () -> CredentialNamespaces?) {
        self.resolve = resolve
    }

    /// A vault over namespaces that are already known — the fixed composition a test builds.
    public init(_ fixed: CredentialNamespaces) {
        self.init(resolving: { fixed })
    }

    /// The credential, wherever it still is, moved to where it belongs on the way past.
    ///
    /// The migration happens on READ rather than at launch on purpose: a launch-time sweep would
    /// have to run before anything else could touch the keychain, and it would run on every launch
    /// forever. This one costs a second lookup exactly until the first read finds nothing to move.
    public func string(for account: String) throws -> String? {
        let namespaces = try resolved()
        // A failure to read the credential's own home is RAISED, never converted into "nobody is
        // signed in": those are different facts and only one of them is a reason to show a
        // sign-in screen.
        if let value = try namespaces.primary.store.string(for: account) {
            // The leftover a crash between a write and its tidy-up leaves behind. Dropping it
            // HERE rather than insisting on it at write time is what lets the write happen first:
            // the cost of that crash is a stale copy the next read removes, not a device with no
            // credential and a forced sign-in.
            tidy(namespaces.legacies, for: account)
            return value
        }
        return migrate(into: namespaces, for: account)
    }

    /// A new credential goes to its home, and every older copy is dropped once the new one has
    /// PROVED it is there.
    public func set(_ value: String, for account: String) throws {
        let namespaces = try resolved()
        do {
            try Self.write(value, for: account, to: namespaces.primary.store)
            tidy(namespaces.legacies, for: account)
        } catch {
            let detail = String(describing: error)
            MemosLog.session.error(
                "the credential's own namespace would not hold it: \(detail, privacy: .public)"
            )
            try fallback(value, for: account, in: namespaces, after: error)
        }
    }

    /// Sign-out clears EVERY namespace, whatever happens in any of them: the whole point of a
    /// wipe is that nothing is left, so a failure in one must not skip the others — and it must
    /// not be swallowed either. A device that believes it is signed out while a credential is
    /// still on it is the state this reports.
    public func remove(_ account: String) throws {
        let namespaces = try resolved()
        var failure: (any Error)?
        do { try namespaces.primary.store.remove(account) } catch { failure = error }
        for legacy in namespaces.legacies {
            do { try legacy.store.remove(account) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    // MARK: - internals

    private func resolved() throws -> CredentialNamespaces {
        if let namespaces { return namespaces }
        guard let fresh = resolve() else { throw CredentialStoreError.namespaceUnavailable }
        namespaces = fresh
        return fresh
    }

    /// One lap per namespace still being emptied, newest first.
    private func migrate(into namespaces: CredentialNamespaces, for account: String) -> String? {
        for legacy in namespaces.legacies {
            let carried: String?
            do {
                carried = try legacy.store.string(for: account)
            } catch {
                // A namespace being emptied is not the credential's home. A read that fails here
                // is stepped over rather than raised — the next namespace may hold the token —
                // and it is said out loud rather than swallowed.
                let detail = String(describing: error)
                MemosLog.session.error(
                    "an older credential namespace would not read: \(detail, privacy: .public)"
                )
                continue
            }
            guard let carried else { continue }

            let filled: Bool
            do {
                filled = try namespaces.primary.store.add(carried, for: account)
            } catch {
                // The home namespace refuses to take it. The only copy stays exactly where it is:
                // nothing is deleted, and the value is still answered with.
                let detail = String(describing: error)
                MemosLog.session.error(
                    "a credential would not move to its own namespace: \(detail, privacy: .public)"
                )
                return carried
            }

            guard filled else {
                // `add` was refused as a duplicate, so something this lap's read could not see is
                // already home. Whatever that is, it is not older than the value in hand.
                guard let newer = ((try? namespaces.primary.store.string(for: account)) ?? nil)
                else { return carried }
                tidy(namespaces.legacies, for: account)
                return newer
            }

            guard let readBack = ((try? namespaces.primary.store.string(for: account)) ?? nil),
                readBack == carried
            else {
                // The add said yes and the namespace has nothing to show for it. NOTHING is
                // deleted: not the copy still in hand, and not whatever the add may have left.
                MemosLog.session.error("a migrated credential did not read back; nothing removed")
                return carried
            }
            tidy(namespaces.legacies, for: account)
            return carried
        }
        return nil
    }

    /// The home namespace would not hold the value. An app-only namespace is the fallback rather
    /// than the failure: a credential only this app can read is worth strictly more than none.
    ///
    /// Two rules make that safe. NOTHING is deleted on the way here — a writer that could not
    /// prove its own write knows nothing about what the namespace holds. And a fallback is only
    /// honest while the home namespace holds nothing: a value there that this write could not
    /// replace would be answered with on every read, and the app would run on one token while
    /// storing another.
    private func fallback(
        _ value: String,
        for account: String,
        in namespaces: CredentialNamespaces,
        after failure: any Error
    ) throws {
        if ((try? namespaces.primary.store.string(for: account)) ?? nil) != nil { throw failure }
        guard let index = namespaces.legacies.firstIndex(where: { $0.reach == .appOnly }) else {
            throw failure
        }
        try Self.write(value, for: account, to: namespaces.legacies[index].store)
        // Proven, so every other copy is now the stale one — and a read walks these in order, so
        // a stale value ahead of this one would be answered with first.
        tidy(
            namespaces.legacies.enumerated().filter { $0.offset != index }.map(\.element),
            for: account
        )
    }

    /// Writes and reads back. A namespace that accepts a value and then cannot return it has not
    /// stored it, whatever it said at the time.
    private static func write(
        _ value: String,
        for account: String,
        to store: any KeychainNamespaceStore
    ) throws {
        try store.set(value, for: account)
        guard try store.string(for: account) == value else {
            throw CredentialStoreError.notReadableBack(account: account)
        }
    }

    /// Drops copies already PROVEN stale. The only suppression left in this type, and it is one:
    /// what fails here is the deletion of a value nothing will ever answer with, so the cost is
    /// one more lap next time rather than a credential.
    private func tidy(_ namespaces: [CredentialNamespace], for account: String) {
        for namespace in namespaces {
            do {
                try namespace.store.remove(account)
            } catch {
                let detail = String(describing: error)
                MemosLog.session.error(
                    "a stale credential copy would not delete: \(detail, privacy: .public)"
                )
            }
        }
    }
}
