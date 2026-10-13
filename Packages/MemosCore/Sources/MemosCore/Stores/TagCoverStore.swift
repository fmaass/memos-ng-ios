import Foundation
import MemosAPI

/// The cover of each tag card on the Collections root: the tag's newest picture.
@MainActor
@Observable
public final class TagCoverStore {
    /// What a tag's lookup answered.
    public enum Cover: Equatable, Sendable {
        case picture(MemoAttachment)
        /// The lookup failed, or the tag has no picture.
        case none
    }

    /// The answered tags.
    public private(set) var covers: [String: Cover] = [:]

    private let onUnauthorized: @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome
    private var session: (any SessionReporting)?

    public init(
        onUnauthorized: @escaping @MainActor @Sendable (CredentialRefusal) async -> RefusalOutcome =
            { _ in .superseded }
    ) {
        self.onUnauthorized = onUnauthorized
    }

    /// Names the session this store's transport failures belong to. Idempotent.
    public func reports(to session: any SessionReporting) { self.session = session }

    /// The picture a tag's card draws, or nil for the plain tile.
    public func cover(for tag: String) -> MemoAttachment? {
        if case .picture(let attachment) = covers[tag] { return attachment }
        return nil
    }

    /// Reads the cover of `tag`.
    public func load(tag: String, using handle: SessionHandle, baseURL: URL) async {}

    /// Forgets every cover: another account's pictures are not this one's.
    public func sessionIdentityChanged() {
        covers = [:]
    }

    /// Forgets every tag answered with no cover, so it is asked again.
    public func forgetMissing() {
        covers = covers.filter { $0.value != .none }
    }
}
