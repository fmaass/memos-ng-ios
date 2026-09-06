import Foundation

/// Why a capture could not be written to the queue.
///
/// Two, because there are two: nobody is signed in for it to be written under, or the device would
/// not keep it. Everything else about an upload happens later, in the drain, where a failure is a
/// pending row rather than an answer to the person still looking at the sheet.
public enum OutboxEnqueueFailure: Sendable, Equatable {
    case notSignedIn
    case storage
}
