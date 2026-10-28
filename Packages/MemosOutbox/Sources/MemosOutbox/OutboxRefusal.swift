import Foundation

/// A refusal the server answered one of the outbox's own requests with, and which grant earned it.
///
/// The same shape, and the same reason, as the generated client's `CredentialRefusal`: a refusal is
/// judged where the answer arrives and acted on somewhere later, and between the two a renewal can
/// land. It is a second type rather than the same one because this package may not import
/// `MemosAPI` (`Packages/MemosOutbox/Package.swift`) and because the two lanes count on different
/// numbers — the outbox is granted an AUTHORITY epoch and can see nothing else.
///
/// What it deliberately does NOT carry is a verdict. The engine computes the answer's disposition
/// on its own actor and the write happens on `OutboxRepository`, a different one; a `Bool` decided
/// before that hop is a decision about an instant that has passed by the time the bytes go down.
/// So both candidate outcomes travel, and the choice is made where the write is.
public struct OutboxRefusal: Sendable, Equatable {
    public let statusCode: Int

    /// The authority epoch the refused request was sent under. `nil` for a task from before this
    /// record existed or one adopted across a relaunch — unknown, treated as current, exactly as
    /// `ChunkResult.epoch` is.
    public let issuedUnder: Int?

    /// What was refused, in the words the sentences below are built from — "chunk", "upload".
    public let what: String

    /// The answer's `Retry-After` in seconds, when it gave a usable one. Only a transient
    /// disposition reads it: it replaces the curve, exactly as it does on the whole lane.
    public let retryAfter: TimeInterval?

    public init(statusCode: Int, issuedUnder: Int?, what: String, retryAfter: TimeInterval? = nil) {
        self.statusCode = statusCode
        self.issuedUnder = issuedUnder
        self.what = what
        self.retryAfter = retryAfter
    }

    /// Whether the refusal is about the credential rather than the request — the one status an
    /// offset HEAD holds on; anything else it meets is spaced out like an unanswered one.
    public var concernsCredential: Bool { statusCode == 401 }

    /// Whether this refusal is decided by the body this edit is frozen on, and so says the same
    /// thing about every transmission of that key. A 401 or 403 is answered before the key is
    /// looked up, a 404 says the memo is gone rather than that this edit never applied, a 429 and
    /// a 5xx answer nothing.
    public var deterministicOnTheFrozenBody: Bool { statusCode == 422 }

    /// What the queue should do about it.
    ///
    /// Two cases rather than three: every status this lane meets resolves to one of them, and a
    /// third that nothing produces is a branch no test can reach.
    public enum Disposition: Sendable, Equatable {
        /// `RetryClass.hold`: the reason the row carries, so it can name its fix, and the sentence.
        case hold(HoldReason, String)
        /// `RetryClass.transient`: the sentence, and the server's own delay when it named one.
        case backOff(String, retryAfter: TimeInterval?)
    }

    /// The status-to-decision mapping, in the one place that owns it.
    ///
    /// - Parameter assumingCurrent: whether to answer as if the grant that earned this refusal is
    ///   still the device's. BOTH answers are computed by the caller and handed to the write, which
    ///   picks between them under the isolation that performs it — see `OutboxPersisting`.
    public func disposition(assumingCurrent: Bool) -> Disposition {
        switch statusCode {
        case 401 where !assumingCurrent:
            return .backOff(supersededMessage, retryAfter: nil)
        case 401:
            return .hold(.signInRequired, "Sign in again to send this memo.")
        case 413:
            return .hold(.tooLarge, "The server will not accept a file this large.")
        case 408, 429, 500...599:
            return .backOff("The server could not take the \(what).", retryAfter: retryAfter)
        default:
            return .hold(.serverRefused, "The server rejected the \(what) (\(statusCode)).")
        }
    }

    /// What a capture says while it waits for the successor. Never a hold: holding a capture on a
    /// refusal of a credential the device has already replaced strands it behind a "sign in again"
    /// its owner has already done.
    public var supersededMessage: String {
        "The credential that \(what) was sent under was replaced."
    }
}
