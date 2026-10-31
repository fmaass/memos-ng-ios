import Foundation

/// Who a capture made OUTSIDE the app has to be bound to.
///
/// The share extension stamps a job with the same server and owner the composer would, and it has
/// neither a session nor a credential to ask: the owner's subject is something the app learns from
/// the server, and an extension that could read the token would be a second place to leak it from.
/// So the app publishes the binding — a server address and a subject, never a token — beside
/// the queue in the app group, and the extension reads it there.
///
/// A missing file means "nobody is signed in as far as anything outside the app can tell", which
/// is the safe answer: an extension that cannot bind a capture refuses to take it rather than
/// queueing one that would be held for the wrong account later.
/// The licence as it is published: who a capture binds to, and WHICH grant of that licence this is.
///
/// The pair exists because the two answer different questions. A binding says whose memo this
/// would be; an issue says under which grant of permission it was admitted. Signing out and back
/// into the same account republishes the identical binding — the extension cannot tell that from
/// having never been signed out at all — so a capture admitted before the revocation would publish
/// under a session that has ended. The issue is what makes those two different, and it is the only
/// thing here that a sheet standing open for three seconds needs that the binding cannot give it.
///
/// Written FLAT, over the binding's own two keys plus one: a licence from a build that predates
/// issues decodes with none, and a build that predates this one reads the file it has always read
/// and ignores the extra key.
public struct PublishedLicence: Sendable, Equatable, Codable {
    public let binding: AccountBinding
    /// Nil only for a licence written before there were issues. It fences nothing, which is the
    /// honest answer about a file that never carried the fact.
    public let incarnation: UUID?

    public init(binding: AccountBinding, incarnation: UUID?) {
        self.binding = binding
        self.incarnation = incarnation
    }

    private enum CodingKeys: String, CodingKey {
        case serverBaseURL
        case ownerSubject
        case incarnation
        case kind
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        binding = AccountBinding(
            serverBaseURL: try fields.decode(URL.self, forKey: .serverBaseURL),
            ownerSubject: try fields.decode(String.self, forKey: .ownerSubject),
            kind: try fields.decodeIfPresent(CredentialKind.self, forKey: .kind)
        )
        incarnation = try fields.decodeIfPresent(UUID.self, forKey: .incarnation)
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(binding.serverBaseURL, forKey: .serverBaseURL)
        try fields.encode(binding.ownerSubject, forKey: .ownerSubject)
        try fields.encodeIfPresent(incarnation, forKey: .incarnation)
        try fields.encodeIfPresent(binding.kind, forKey: .kind)
    }
}

public protocol OutboxAccountPublishing: Sendable {
    /// What the licence currently says — read back rather than remembered, because the writer and
    /// the reader are different processes and the only shared truth is the file.
    func current() -> AccountBinding?
    /// The same read, with the grant it belongs to — what a caller has to hold on to when there is
    /// any time at all between admitting a capture and writing it.
    func currentLicence() -> PublishedLicence?
    /// Best effort by design: a binding that could not be written costs the share extension its
    /// next capture, and must never cost the app a sign-in. Failing CLOSED is the whole point —
    /// no licence means no enqueue.
    func publish(_ binding: AccountBinding)
    /// Throwing, unlike `publish`, and deliberately so: a licence that could not be revoked is a
    /// revoked identity that can still queue captures. That must be visible to the caller and
    /// retried, never swallowed.
    func clear() throws
}

extension OutboxAccountPublishing {
    /// For a publisher that models no grants at all — a test double, or a build that only ever had
    /// a binding. It fences nothing, and says so, rather than minting an issue nobody granted.
    public func currentLicence() -> PublishedLicence? {
        current().map { PublishedLicence(binding: $0, incarnation: nil) }
    }
}

public struct OutboxAccountStore: OutboxAccountPublishing, Sendable {
    private let url: URL

    /// - Parameter root: the outbox's own directory — the binding lives beside the jobs it
    ///   describes, so a container that has one has the other.
    public init(root: URL) {
        self.url = root.appending(path: "account.json")
    }

    /// The store in the app group, or nil when the container is not reachable — on a device that
    /// means the entitlement is missing, and an extension in that state cannot enqueue at all.
    public static func live(appGroup: String = OutboxDefaults.appGroup) -> OutboxAccountStore? {
        OutboxRepository.appGroupRoot(appGroup: appGroup).map(OutboxAccountStore.init(root:))
    }

    /// The guest licence: the same file, in the guest outbox's directory, so a share enqueues a
    /// guest capture only into the queue that drains as the guest.
    public static func guestLive(
        appGroup: String = OutboxDefaults.appGroup
    ) -> OutboxAccountStore? {
        OutboxRepository.guestAppGroupRoot(appGroup: appGroup).map(OutboxAccountStore.init(root:))
    }

    /// What the app last said about who is signed in, or nil when it has said nothing or has
    /// signed out. A file that cannot be decoded reads as nil: a binding nobody can parse is not
    /// one to stamp a capture with.
    public func current() -> AccountBinding? {
        currentLicence()?.binding
    }

    /// The whole licence: the pair, and the grant it was published under.
    public func currentLicence() -> PublishedLicence? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PublishedLicence.self, from: data)
    }

    /// The grant is minted HERE, and only where one is actually being granted: onto no licence at
    /// all, or onto another account's. A licence republished over itself keeps the issue it has —
    /// the app republishes the same pair every time it revalidates the session in the foreground,
    /// and a fresh issue there would refuse a share that is doing nothing but waiting its turn.
    public func publish(_ binding: AccountBinding) {
        let standing = currentLicence()
        let issue = standing?.binding == binding ? standing?.incarnation ?? UUID() : UUID()
        guard
            let data = try? JSONEncoder().encode(
                PublishedLicence(binding: binding, incarnation: issue)
            )
        else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// Signing out revokes the extension's licence to enqueue, before the token goes.
    ///
    /// Revoking a licence that is not there is success, not an error: the point of a revocation is
    /// that nothing is left, whatever state it started from.
    public func clear() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
