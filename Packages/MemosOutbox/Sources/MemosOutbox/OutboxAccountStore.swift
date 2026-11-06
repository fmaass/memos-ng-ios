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
    /// Writes the account's default visibility — its raw wire name, or nil for "not known" — into
    /// the licence file, but only while `binding` is the licence standing: a default is a fact
    /// about ONE account, and it is never written onto another one's licence or onto none at all.
    /// Best effort, like `publish`: the share sheet then names no default, which is the honest
    /// answer about a setting it was never told.
    func publishDefaultVisibility(_ wire: String?, for binding: AccountBinding)
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
    /// - Parameter grants: the capture grant's file in `root`; a test passes one whose removal it
    ///   can make fail.
    public init(root: URL, grants: CaptureGrantStore? = nil) {
        self.url = root.appending(path: "account.json")
        self.grants = grants ?? CaptureGrantStore(root: root)
    }

    /// The capture grant beside this licence — its lifecycle is the licence's (`CaptureGrantStore`).
    private let grants: CaptureGrantStore

    /// The store in the app group, or nil when the container is not reachable — on a device that
    /// means the entitlement is missing, and an extension in that state cannot enqueue at all.
    public static func live(appGroup: String = OutboxDefaults.appGroup) -> OutboxAccountStore? {
        OutboxRepository.appGroupRoot(appGroup: appGroup).map { OutboxAccountStore(root: $0) }
    }

    /// The guest licence: the same file, in the guest outbox's directory, so a share enqueues a
    /// guest capture only into the queue that drains as the guest.
    public static func guestLive(
        appGroup: String = OutboxDefaults.appGroup
    ) -> OutboxAccountStore? {
        OutboxRepository.guestAppGroupRoot(appGroup: appGroup).map { OutboxAccountStore(root: $0) }
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
        // A NEW issue is an account change as far as anything outside the app can tell, and the
        // capture grant beside the licence belongs to the issue it was minted under. It goes
        // first, before the new licence exists, so no instant pairs the new licence with it.
        if issue != standing?.incarnation { try? grants.clear() }
        // The default belongs to the issue it was published under, exactly as the grant does: a
        // republish over the same issue keeps it, a new issue starts without one.
        let kept = issue == standing?.incarnation ? readFile()?.defaultVisibility : nil
        write(
            AccountFile(
                licence: PublishedLicence(binding: binding, incarnation: issue),
                defaultVisibility: kept
            )
        )
    }

    /// The default rides in the licence's own file (MEMNG-972) so that the two are read in ONE
    /// read: the share sheet can never pair one account's licence with another one's default.
    /// Written over the standing licence unchanged — same binding, same issue — so publishing a
    /// default refuses no share that is waiting its turn.
    public func publishDefaultVisibility(_ wire: String?, for binding: AccountBinding) {
        guard let standing = readFile()?.licence, standing.binding == binding else { return }
        write(AccountFile(licence: standing, defaultVisibility: wire))
    }

    /// The account's default visibility as the app last published it, by its raw wire name — and
    /// only while `licence` is still the licence standing. Nil when it was never published, when
    /// the account or the issue has moved since the caller read its licence, or when the file
    /// cannot be read.
    public func defaultVisibility(under licence: PublishedLicence) -> String? {
        guard let file = readFile(), file.licence == licence else { return nil }
        return file.defaultVisibility
    }

    private func readFile() -> AccountFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AccountFile.self, from: data)
    }

    private func write(_ file: AccountFile) {
        guard let data = try? JSONEncoder().encode(file) else { return }
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
        // The capture grant first: it is the credential, and the licence is what admits a capture
        // to use one. A grant that would not delete still names this issue, which no later licence
        // carries, so it is never handed to a capture again — but it is said, by throwing.
        try grants.clear()
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}

/// The licence file as written: the licence's own flat keys, plus the account's default.
///
/// The extra key is outside `PublishedLicence` on purpose. A licence is compared — a capture is
/// admitted only under the licence it was composed under — and a default changed in Settings is not
/// a new grant of permission; folded into the licence it would refuse a share for nothing. A build
/// that predates the key decodes the licence and ignores it.
private struct AccountFile: Codable {
    let licence: PublishedLicence
    let defaultVisibility: String?

    init(licence: PublishedLicence, defaultVisibility: String?) {
        self.licence = licence
        self.defaultVisibility = defaultVisibility
    }

    private enum CodingKeys: String, CodingKey {
        case serverBaseURL
        case ownerSubject
        case incarnation
        case kind
        case defaultVisibility
    }

    init(from decoder: any Decoder) throws {
        licence = try PublishedLicence(from: decoder)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        defaultVisibility = try fields.decodeIfPresent(String.self, forKey: .defaultVisibility)
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(licence.binding.serverBaseURL, forKey: .serverBaseURL)
        try fields.encode(licence.binding.ownerSubject, forKey: .ownerSubject)
        try fields.encodeIfPresent(licence.incarnation, forKey: .incarnation)
        try fields.encodeIfPresent(licence.binding.kind, forKey: .kind)
        try fields.encodeIfPresent(defaultVisibility, forKey: .defaultVisibility)
    }
}
