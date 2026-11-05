import Foundation

/// Why a capture could not be written to the queue.
///
/// Nobody is signed in for it to be written under, the device would not keep it, or — for an edit
/// job (MEMNG-954) — an earlier edit of the same memo is still in the queue. Everything else about
/// an upload happens later, in the drain, where a failure is a pending row rather than an answer to
/// the person still looking at the sheet.
public enum OutboxEnqueueFailure: Sendable, Equatable {
    case notSignedIn
    case storage
    /// An edit job for this memo is still in the queue: a second one would freeze the memo's text
    /// and picture list beside the first, and whichever PATCH landed last would undo the other.
    case editPending
}
