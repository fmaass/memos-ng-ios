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
    /// Stores several accounts in ONE call, so that nothing can happen between them.
    ///
    /// A sign-in is two items — the token and the server it belongs to — and between two separate
    /// calls a sign-out fits. If it lands there the device keeps a server address with no token
    /// beside it, which nothing else in the app produces and nothing in it repairs.
    ///
    /// Named apart from `set(_:for:)` deliberately. A sync method on the actor and an async
    /// default on this protocol would be a sync/async OVERLOAD PAIR, and Swift resolves such a
    /// pair to the async one in an async context — which is the looping default, one actor hop
    /// per item, exactly the gap this call exists to close. A test caught it; a different name
    /// means the question cannot be asked again.
    func setAll(_ values: [String: String]) async throws
    func string(for account: String) async throws -> String?
    func remove(_ account: String) async throws
    /// Clears several accounts in ONE call, the mirror image of the same reason: a sign-in that
    /// lands between two deletions leaves half of itself behind. Named apart from `remove(_:)`
    /// for the same reason `setAll` is.
    func removeAll(_ accounts: [String]) async throws
}

extension CredentialStore {
    /// The general case, for a store with no atomicity of its own to offer. `CredentialVault`
    /// overrides both, and that override IS the guarantee — this default is a convenience for
    /// stand-ins, not the behaviour the app relies on.
    public func setAll(_ values: [String: String]) async throws {
        for (account, value) in values { try await set(value, for: account) }
    }

    public func removeAll(_ accounts: [String]) async throws {
        var failure: (any Error)?
        for account in accounts {
            do { try await remove(account) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }
}

/// Who, besides this app, can read what a namespace holds.
enum CredentialReach: Equatable, Sendable {
    /// An access group named by this app's own entitlements and by nothing else's.
    case appOnly
    /// An app group. On iOS an app group identifier IS a keychain access group, so every
    /// extension entitled to that group's container can also read the group's keychain items —
    /// the share extension included, which needs the container for the outbox files and the
    /// identity JSON and must never have the token. The device token is not written here.
    case sharedWithExtensions
}

/// One namespace, and what reaching it means.
struct CredentialNamespace: Sendable {
    let store: any KeychainNamespaceStore
    let reach: CredentialReach

    init(_ store: any KeychainNamespaceStore, reach: CredentialReach) {
        self.store = store
        self.reach = reach
    }
}

/// Where the credential lives, and which namespaces are still being emptied into it.
///
/// The order IS the precedence: the primary first, then the legacies newest home first. Every
/// decision in the vault is taken by walking that order, and no namespace may be promoted over a
/// namespace above it — not when the one above is empty-looking, and above all not when it is
/// unreadable.
struct CredentialNamespaces: Sendable {
    let primary: CredentialNamespace
    let legacies: [CredentialNamespace]
    /// Whether the primary really is the group the entitlement names.
    ///
    /// When a probe cannot confirm that, the app can still READ its own credential and still
    /// clear it — but it may not WRITE a new one into a weaker home. An entitlement that did not
    /// arrive is a security-policy change, and quietly storing the token somewhere else is how
    /// such a change goes unnoticed.
    let homeIsDedicated: Bool

    init(
        primary: CredentialNamespace,
        legacies: [CredentialNamespace],
        homeIsDedicated: Bool = true
    ) {
        // Composition is code, not input: a build that put the token where an extension can read
        // it is a defect to find at the first test that runs, not a condition to handle.
        precondition(
            primary.reach == .appOnly,
            "the device token's home must be a namespace no extension can read"
        )
        self.primary = primary
        self.legacies = legacies
        self.homeIsDedicated = homeIsDedicated
    }

    /// The namespaces in precedence order, highest first.
    var ordered: [CredentialNamespace] { [primary] + legacies }
}

/// What one namespace answered when it was asked for an account.
///
/// The three cases are the whole point: "there is nothing here" and "I cannot tell you what is
/// here" are different answers, and only the first is evidence.
enum CredentialReadOutcome: Equatable, Sendable {
    case value(String)
    /// The keychain's item-not-found status, and nothing else. Proven empty.
    case absent
    /// A status, an item of the wrong type, bytes that are not a token, an entitlement this build
    /// no longer has. Proof of nothing.
    case unreadable

    init(_ value: String?) {
        self = value.map(CredentialReadOutcome.value) ?? .absent
    }
}

/// The one rule that decides which stored credential is authoritative.
///
/// **No lower-precedence credential may become authoritative unless every higher-precedence
/// namespace has been proven ABSENT** — and absent means the namespace answered "nothing here",
/// never that it failed to answer. Both halves are load-bearing:
///
/// - A newer namespace that will not read must STOP the walk. Stepping over it and promoting the
///   next one down is how an older token wins: the value that could not be read may well have
///   been the newest, and the one below it is by definition older.
/// - Deleting the lower copies is only safe once something above them is known to be
///   authoritative, because that is what makes them stale rather than merely lower.
///
/// It is a pure function over the answers so that it can be exhausted by test rather than
/// reasoned about per call site.
enum CredentialPrecedence {
    enum Decision: Equatable, Sendable {
        /// The namespace at this index holds the credential the app must use.
        case authoritative(index: Int, value: String)
        /// Every namespace answered, and every one of them was empty.
        case absent
        /// The namespace at this index would not answer, so nothing below it may be promoted and
        /// nothing may be deleted on the strength of a value that might not be the newest.
        case blocked(index: Int)
    }

    static func decide(_ outcomes: [CredentialReadOutcome]) -> Decision {
        for (index, outcome) in outcomes.enumerated() {
            switch outcome {
            case .unreadable: return .blocked(index: index)
            case .value(let value): return .authoritative(index: index, value: value)
            case .absent: continue
            }
        }
        return .absent
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
///    keychain would serialize nothing. There is one per process (`DeviceCredentials.shared`),
///    and the initialisers are internal so a second one cannot be built from outside this module.
///
/// Every namespace call inside the isolation is SYNCHRONOUS, which is the other half of the
/// guarantee: an `await` in here would be a suspension point another task could enter through,
/// and actor reentrancy would hand back exactly the interleaving this type exists to prevent.
///
/// What it cannot serialize is another PROCESS. An access group is a process boundary, not an
/// actor one, so a namespace an extension is entitled to is one the extension can change
/// underneath this type — which is the reason the token's home is a group no extension names.
actor CredentialVault: CredentialStore {
    private let resolve: @Sendable () -> CredentialNamespaces?
    /// Resolved on first use and remembered only on SUCCESS — the namespaces are named from a
    /// keychain probe, and a probe can fail for reasons that pass (see `AccessGroupResolver`).
    private var namespaces: CredentialNamespaces?

    init(resolving resolve: @escaping @Sendable () -> CredentialNamespaces?) {
        self.resolve = resolve
    }

    /// A vault over namespaces that are already known — the fixed composition a test builds.
    init(_ fixed: CredentialNamespaces) {
        self.init(resolving: { fixed })
    }

    /// The credential, wherever it still is, moved to where it belongs on the way past.
    ///
    /// The migration happens on READ rather than at launch on purpose: a launch-time sweep would
    /// have to run before anything else could touch the keychain, and it would run on every launch
    /// forever. This one costs a second lookup exactly until the first read finds nothing to move.
    func string(for account: String) throws -> String? {
        let namespaces = try resolved()
        var outcomes: [CredentialReadOutcome] = []
        var failures: [Int: any Error] = [:]
        for (index, namespace) in namespaces.ordered.enumerated() {
            do {
                let outcome = CredentialReadOutcome(try namespace.store.string(for: account))
                outcomes.append(outcome)
                // Precedence: nothing below a value matters, so nothing below it is read.
                if case .value = outcome { break }
            } catch {
                let detail = String(describing: error)
                MemosLog.session.error(
                    "a credential namespace would not read: \(detail, privacy: .public)"
                )
                failures[index] = error
                outcomes.append(.unreadable)
                break
            }
        }

        switch CredentialPrecedence.decide(outcomes) {
        case .blocked(let index):
            // Raised, never converted into "nobody is signed in": those are different facts and
            // only one of them is a reason to show a sign-in screen or to revoke the share
            // extension's licence.
            throw failures[index] ?? CredentialStoreError.namespaceUnavailable
        case .absent:
            return nil
        case .authoritative(let index, let value):
            guard index > 0 else {
                // The leftover a crash between a write and its tidy-up leaves behind. Dropping it
                // HERE rather than insisting on it at write time is what lets the write happen
                // first: the cost of that crash is a stale copy the next read removes, not a
                // device with no credential and a forced sign-in.
                tidy(namespaces.legacies, for: account)
                return value
            }
            return promote(value, in: namespaces, for: account)
        }
    }

    /// A new credential goes to its home, and every older copy is dropped once the new one has
    /// PROVED it is there.
    func set(_ value: String, for account: String) throws {
        try setAll([account: value])
    }

    /// Every account in one critical section. Nothing — no sign-out, no other sign-in, no
    /// migration lap — runs between the first write and the last.
    func setAll(_ values: [String: String]) throws {
        let namespaces = try resolved()
        guard namespaces.homeIsDedicated else {
            // The probe could not confirm that the token's home is the group the entitlement
            // names. Reading and clearing still work; storing does not. An entitlement that did
            // not arrive is a change of security policy, and writing the token into a weaker
            // namespace instead is exactly how such a change would go unnoticed.
            throw CredentialStoreError.storageDegraded
        }
        for (account, value) in values {
            try store(value, for: account, in: namespaces)
        }
    }

    /// Sign-out clears EVERY namespace, whatever happens in any of them: the whole point of a
    /// wipe is that nothing is left, so a failure in one must not skip the others — and it must
    /// not be swallowed either. A device that believes it is signed out while a credential is
    /// still on it is the state this reports.
    func remove(_ account: String) throws {
        try removeAll([account])
    }

    /// Every account, every namespace, one critical section — and a failure anywhere is carried
    /// to the end and then raised, because a wipe that stopped at the first would leave the rest
    /// of the credential on the device.
    func removeAll(_ accounts: [String]) throws {
        let namespaces = try resolved()
        var failure: (any Error)?
        for account in accounts {
            for namespace in namespaces.ordered {
                do { try namespace.store.remove(account) } catch { failure = failure ?? error }
            }
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

    private func store(
        _ value: String,
        for account: String,
        in namespaces: CredentialNamespaces
    ) throws {
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

    /// Moves a credential found in a namespace being emptied into the one it belongs in.
    ///
    /// Nothing here deletes anything until the primary is PROVEN to hold the value: the copy in
    /// hand may be the only one on the device.
    private func promote(
        _ carried: String,
        in namespaces: CredentialNamespaces,
        for account: String
    ) -> String? {
        do {
            // Between the read and this line another sign-in may have landed, and the value in
            // hand is by definition the older of the two. `add` settles that in ONE keychain
            // call: it fills an empty namespace and refuses a full one, so the older value can
            // never replace the newer one — which is why this is an add and not a write.
            _ = try namespaces.primary.store.add(carried, for: account)
        } catch {
            // The home namespace refuses to take it. The only copy stays exactly where it is:
            // nothing is deleted, and the value is still answered with — a sign-in that works is
            // worth more than a tidy keychain.
            let detail = String(describing: error)
            MemosLog.session.error(
                "a credential would not move to its own namespace: \(detail, privacy: .public)"
            )
            return carried
        }

        let home: String?
        do {
            home = try namespaces.primary.store.string(for: account)
        } catch {
            // The write may well have landed; what is certain is that it cannot be PROVEN, and
            // nothing is deleted on an unproven write.
            let detail = String(describing: error)
            MemosLog.session.error(
                "a migrated credential would not read back: \(detail, privacy: .public)"
            )
            return carried
        }

        guard let home else {
            // The namespace answered "nothing here" to a value it has just been given. Nothing
            // moved, so nothing is deleted — the copy in hand may be the only one on the device.
            MemosLog.session.error("a migrated credential did not read back; nothing removed")
            return carried
        }
        // Whatever is home now OUTRANKS the copy in hand — it sits at the top of the precedence
        // order — whether this lap put it there or a sign-in did while the lap was reading. It is
        // what the caller gets, and every copy below it is stale.
        tidy(namespaces.legacies, for: account)
        return home
    }

    /// The home namespace would not hold the value. An app-only namespace is the fallback rather
    /// than the failure: a credential only this app can read is worth strictly more than none.
    ///
    /// The precedence rule is what makes that safe. A fallback copy sits BELOW every namespace it
    /// is written under, so it may only be written when every one of those has been proven
    /// absent: a value above it would be answered with first, and the app would run on one token
    /// while storing another. Unreadable is not absent here either — the read propagates — and
    /// nothing is deleted to make room, because a writer that could not prove its own write knows
    /// nothing about what the namespaces hold.
    private func fallback(
        _ value: String,
        for account: String,
        in namespaces: CredentialNamespaces,
        after failure: any Error
    ) throws {
        guard let index = namespaces.legacies.firstIndex(where: { $0.reach == .appOnly }) else {
            throw failure
        }
        let higher = namespaces.ordered.prefix(index + 1)
        let outcomes = try higher.map { CredentialReadOutcome(try $0.store.string(for: account)) }
        guard CredentialPrecedence.decide(outcomes) == .absent else { throw failure }

        try Self.write(value, for: account, to: namespaces.legacies[index].store)
        // Only what is BELOW the fallback is stale, and only that is dropped.
        tidy(Array(namespaces.legacies.dropFirst(index + 1)), for: account)
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

    /// Drops copies already PROVEN stale — every one of these sits below a namespace known to
    /// hold the authoritative value. The only suppression in this type, and it is one: what fails
    /// here is the deletion of a value nothing will ever be answered with, so the cost is one
    /// more lap next time rather than a credential.
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
