import Foundation
import MemosCore
import MemosOutbox

/// The switch for posting while files load and the pending memo card (MEMNG-951), in the phone's
/// Settings under Uploads. On by default.
public enum PendingCardFlag {
    public static let toggleKey = "compose.pending-card"

    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: toggleKey) as? Bool ?? true
    }
}

/// The files Post left loading, on their way into the capture it wrote (MEMNG-951).
///
/// A value the submission carries rather than a task the sheet owns: the sheet closes the moment
/// the capture is on disk, and closing it must not cancel the loads. Equal by identity — two
/// submissions carry the same arrivals only when they are the same Post.
@MainActor
final class ComposeArrivals: Equatable {
    /// How long a capture waits for its last file before it is sent without it. Long enough for
    /// a video coming down from iCloud; short enough that a load that never answers does not keep
    /// a memo off the server for the rest of the day.
    static let limit: Duration = .seconds(600)

    let imports: ComposeImports
    let ids: [UUID]

    /// Nil when nothing is loading: then there is nothing to follow.
    init?(_ imports: ComposeImports) {
        let ids = imports.stillLoading
        guard !ids.isEmpty else { return nil }
        self.imports = imports
        self.ids = ids
    }

    nonisolated static func == (lhs: ComposeArrivals, rhs: ComposeArrivals) -> Bool {
        lhs === rhs
    }

    /// Writes the capture, and — when files are still arriving — follows them into it on a task
    /// of its own, which nothing on the sheet holds and so nothing on the sheet cancels.
    ///
    /// Answers as soon as the capture is written: the sheet closes on that, never on the loads.
    /// Each file is appended as it lands; when the last has landed or failed, or `limit` passes,
    /// the capture is let go, so a load that never answers cannot hold the memo back for ever.
    ///
    /// `stage` is told how many items are still loading, so the capture can count what never
    /// comes: an item that fails, is refused, or is still loading at the limit is never appended,
    /// and the queue names what is left of that count on the card (`UploadJob.missingItems`). That
    /// count — not `append`'s answer here — is the record, written in the same step as each file.
    /// - Returns: whether the capture was written, and the follower when there is one.
    @discardableResult
    static func stageThenFollow(
        _ arrivals: ComposeArrivals?,
        within limit: Duration = ComposeArrivals.limit,
        stage: (_ stillLoading: Int) async -> UUID?,
        append: @escaping @MainActor (UUID, PickedMedia) async -> Bool,
        release: @escaping @MainActor (UUID) async -> Void
    ) async -> (written: Bool, follower: Task<ComposeHandOff, Never>?) {
        guard let jobID = await stage(arrivals?.ids.count ?? 0) else { return (false, nil) }
        guard let arrivals else { return (true, nil) }
        let follower = Task { @MainActor in
            let outcome = await arrivals.imports.handOff(arrivals.ids, within: limit) { media in
                _ = await append(jobID, media)
            }
            await release(jobID)
            return outcome
        }
        return (true, follower)
    }
}

/// What a pending card offers. Every action a memo card has is here, and each is either applied
/// to the queued capture or shown disabled with the reason — never silently ignored.
public enum PendingMemoAction: String, Sendable, CaseIterable {
    /// Back into the editor; the change is written to the capture's manifest by its re-submit.
    case edit
    /// Out of the queue, while nothing may have reached the server.
    case remove
    case visibility
    case pin
    case archive
    case favorite
    case addToCollection
    case share

    public var title: String {
        switch self {
        case .edit: "Edit"
        case .remove: "Remove"
        case .visibility: "Visibility"
        case .pin: "Pin"
        case .archive: "Archive"
        case .favorite: "Favorite"
        case .addToCollection: "Add to collection"
        case .share: "Share"
        }
    }
}

/// One action on a pending card, and why it cannot be taken when it cannot.
public struct PendingMemoOffer: Sendable, Equatable, Identifiable {
    public var action: PendingMemoAction
    /// Nil when the action is applied to the capture; otherwise the sentence the card shows.
    public var disabledReason: String?
    public var id: PendingMemoAction { action }
}

public enum PendingMemoActions {
    static let notYetAMemo = "Available once the memo has reached the server."
    static let visibilityInEdit = "Change who can see it in Edit until it has reached the server."
    static let stillArriving = "Files are still being added. Edit it once they are in."
    static let nothingToSend = "Nothing in it arrived. Remove it and write a new memo."
    static let editOnTheWire = "A change is being sent. Edit it again once it has arrived."
    static let mayBeOnServer =
        "It may already be on the server. Delete the memo once it appears."

    /// Every action, in the order the card lists them, with the reason for each one that is not
    /// applied to this capture.
    public static func offers(for job: UploadJob) -> [PendingMemoOffer] {
        PendingMemoAction.allCases.map { action in
            PendingMemoOffer(action: action, disabledReason: reason(action, job))
        }
    }

    private static func reason(_ action: PendingMemoAction, _ job: UploadJob) -> String? {
        switch action {
        case .edit:
            // Taken back while files are still arriving, the late ones would have nowhere to go.
            if job.stillArriving { return stillArriving }
            if job.hasNothingToSend { return nothingToSend }
            if job.editUnansweredSince != nil { return editOnTheWire }
            return nil
        case .remove:
            return job.createMayHaveBeenSent ? mayBeOnServer : nil
        case .visibility:
            return visibilityInEdit
        case .pin, .archive, .favorite, .addToCollection, .share:
            return notYetAMemo
        }
    }
}
