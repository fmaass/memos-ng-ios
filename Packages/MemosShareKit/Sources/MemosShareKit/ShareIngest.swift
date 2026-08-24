import Foundation
import MemosOutbox

/// What became of a share.
public enum ShareOutcome: Sendable, Equatable {
    /// The capture is on disk in the app group, whole, under this job id. It uploads when the app
    /// next drains the queue — the extension never sends anything itself.
    case enqueued(UUID)
    /// Nobody is signed in as far as anything outside the app can tell, so nothing was written.
    case notSignedIn
    /// No files and no words: there is no memo here to keep.
    case nothingToPost
}

/// The share extension's whole job: persist the capture, bind it to the account, and stop.
///
/// It deliberately cannot upload. The single-attach rule means one process owns the background
/// session, and that process is the app: an extension that started its own would race the app for
/// the same chunks and lose its host mid-transfer. So this writes to the queue the app drains, and
/// the app's next launch or background refresh moves the bytes.
public enum ShareIngest {
    /// - Parameter binding: the account the app last published. Nil means nobody is signed in —
    ///   and then NOTHING is written, rather than a capture being stamped with a guess: a job
    ///   bound to the wrong account is one the engine holds forever, which looks exactly like a
    ///   memo that was lost.
    public static func commit(
        items: [SharedItem],
        note: String,
        visibility: ShareVisibility?,
        binding: AccountBinding?,
        capturedAt: Date = Date(),
        into repository: OutboxRepository
    ) async throws -> ShareOutcome {
        guard let binding else { return .notSignedIn }
        let content = ShareComposition.content(note: note, items: items)
        let sources = items.compactMap(\.file).map(\.stagedSource)
        guard !content.isEmpty || !sources.isEmpty else { return .nothingToPost }
        let job = try await repository.enqueue(
            content: content,
            visibility: visibility?.rawValue,
            capturedAt: capturedAt,
            binding: binding,
            sources: sources
        )
        return .enqueued(job.id)
    }
}
