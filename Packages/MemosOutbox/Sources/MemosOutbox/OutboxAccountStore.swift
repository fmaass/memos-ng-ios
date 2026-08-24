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
public protocol OutboxAccountPublishing: Sendable {
    /// Best effort by design: a binding that could not be written costs the share extension its
    /// next capture, and must never cost the app a sign-in.
    func publish(_ binding: AccountBinding)
    func clear()
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

    /// What the app last said about who is signed in, or nil when it has said nothing or has
    /// signed out. A file that cannot be decoded reads as nil: a binding nobody can parse is not
    /// one to stamp a capture with.
    public func current() -> AccountBinding? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AccountBinding.self, from: data)
    }

    public func publish(_ binding: AccountBinding) {
        guard let data = try? JSONEncoder().encode(binding) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    /// Signing out revokes the extension's licence to enqueue, in the same breath the token goes.
    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
